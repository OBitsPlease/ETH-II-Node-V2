const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const path = require('path');
const fs = require('fs');
const net = require('net');
const { ethers } = require('ethers');

// Crash/close log — defined first so all handlers can use it
const LOG_FILE = path.join(require('os').tmpdir(), 'ethii-wallet-crash.log');
process.on('uncaughtException', (err) => {
  fs.appendFileSync(LOG_FILE, `[${new Date().toISOString()}] uncaughtException: ${err.stack}\n`);
});
process.on('unhandledRejection', (reason) => {
  fs.appendFileSync(LOG_FILE, `[${new Date().toISOString()}] unhandledRejection: ${reason}\n`);
});

// Prevent duplicate wallet windows — if another instance is already running,
// focus it and exit this new one immediately.
const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  fs.appendFileSync(LOG_FILE, `[${new Date().toISOString()}] QUIT: requestSingleInstanceLock returned false — another instance is running\n`);
  app.quit();
}

let WALLET_FILE; // initialized after app is ready
let RPC_PORT = 8545; // default, may be updated by port scan
let RPC_URL = 'http://127.0.0.1:8545';
const PUBLIC_RPC_URL = 'http://91.99.231.217:8545'; // VPS public node fallback
const CHAIN_ID = 2048;

let mainWindow;
let provider;

// Check if a port is in use
function isPortInUse(port) {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.once('error', () => resolve(true));
    server.once('listening', () => { server.close(); resolve(false); });
    server.listen(port, '127.0.0.1');
  });
}

// Find the port where the ETHII node is listening.
// Reads rpc-port.txt written by launch-node.ps1 (which knows the exact port).
// Falls back to scanning if the file isn't present (e.g. node started manually).
async function findNodePort(base = 8545) {
  const portFile = path.join(__dirname, 'rpc-port.txt');
  if (fs.existsSync(portFile)) {
    const p = parseInt(fs.readFileSync(portFile, 'utf8').trim(), 10);
    if (!isNaN(p) && p > 0) return p;
  }
  // Fallback: scan for the first port in use
  for (let p = base; p < base + 20; p++) {
    if (await isPortInUse(p)) return p;
  }
  return base;
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1000,
    height: 720,
    minWidth: 800,
    minHeight: 600,
    backgroundColor: '#000000',
    titleBarStyle: 'hidden',
    frame: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
    icon: fs.existsSync(path.join(__dirname, 'assets', 'icon.png')) ? path.join(__dirname, 'assets', 'icon.png') : undefined,
  });
  mainWindow.loadFile('renderer/index.html');
  // Log renderer crashes
  mainWindow.webContents.on('render-process-gone', (event, details) => {
    fs.appendFileSync(LOG_FILE, `[${new Date().toISOString()}] renderer-crash: ${JSON.stringify(details)}\n`);
  });
  mainWindow.webContents.on('console-message', (event, level, message, line, sourceId) => {
    if (level >= 3) { // errors only
      fs.appendFileSync(LOG_FILE, `[${new Date().toISOString()}] renderer-console[${level}]: ${message} (${sourceId}:${line})\n`);
    }
  });
  mainWindow.on('close', () => {
    fs.appendFileSync(LOG_FILE, `[${new Date().toISOString()}] mainWindow close event fired\n`);
  });
}

app.on('second-instance', () => {
  // User tried to open a second wallet — focus the existing window instead.
  if (mainWindow) {
    if (mainWindow.isMinimized()) mainWindow.restore();
    mainWindow.focus();
  }
});

app.whenReady().then(async () => {
  WALLET_FILE = path.join(app.getPath('userData'), 'ethii-wallet.json');
  // Find the port where the ETHII node RPC is listening (default 8545)
  RPC_PORT = await findNodePort(8545);
  RPC_URL = `http://127.0.0.1:${RPC_PORT}`;
  createWindow();
  tryConnectProvider();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('will-quit', () => {
  fs.appendFileSync(LOG_FILE, `[${new Date().toISOString()}] will-quit event fired\n`);
});

app.on('window-all-closed', () => {
  fs.appendFileSync(LOG_FILE, `[${new Date().toISOString()}] window-all-closed event fired\n`);
  if (process.platform !== 'darwin') app.quit();
});

// Try to connect to the local ETHII node
function tryConnectProvider() {
  try {
    const network = ethers.Network.from({ chainId: CHAIN_ID, name: 'ethii' });
    provider = new ethers.JsonRpcProvider(RPC_URL, network, { staticNetwork: network });
  } catch (e) {
    provider = null;
  }
}

// Window controls
ipcMain.on('window-minimize', () => mainWindow.minimize());
ipcMain.on('window-maximize', () => {
  if (mainWindow.isMaximized()) mainWindow.unmaximize();
  else mainWindow.maximize();
});
ipcMain.on('window-close', () => {
  fs.appendFileSync(LOG_FILE, `[${new Date().toISOString()}] window-close IPC received\n`);
  mainWindow.close();
});

// Create new wallet
ipcMain.handle('wallet-create', async () => {
  const wallet = ethers.Wallet.createRandom();
  return { address: wallet.address, privateKey: wallet.privateKey, mnemonic: wallet.mnemonic?.phrase };
});

// Save encrypted wallet to disk
ipcMain.handle('wallet-save', async (_, { privateKey, password }) => {
  try {
    const wallet = new ethers.Wallet(privateKey);
    const encrypted = await wallet.encrypt(password);
    fs.writeFileSync(WALLET_FILE, encrypted, 'utf8');
    return { success: true };
  } catch (e) {
    return { success: false, error: e.message };
  }
});

// Load wallet file exists check
ipcMain.handle('wallet-exists', async () => {
  return fs.existsSync(WALLET_FILE);
});

// Unlock saved wallet
ipcMain.handle('wallet-unlock', async (_, { password }) => {
  try {
    const json = fs.readFileSync(WALLET_FILE, 'utf8');
    const wallet = await ethers.Wallet.fromEncryptedJson(json, password);
    return { success: true, address: wallet.address, privateKey: wallet.privateKey };
  } catch (e) {
    return { success: false, error: 'Invalid password or corrupted wallet file.' };
  }
});

// Import wallet from private key
ipcMain.handle('wallet-import', async (_, { privateKey, password }) => {
  try {
    const wallet = new ethers.Wallet(privateKey);
    const encrypted = await wallet.encrypt(password);
    fs.writeFileSync(WALLET_FILE, encrypted, 'utf8');
    return { success: true, address: wallet.address };
  } catch (e) {
    return { success: false, error: e.message };
  }
});

// Get balance — uses direct RPC fetch for reliability (ethers.js provider may be warming up)
ipcMain.handle('get-balance', async (_, { address }) => {
  try {
    const result = await rpcCall('eth_getBalance', [address, 'latest']);
    const balanceBN = BigInt(result);
    const balanceEth = Number(balanceBN) / 1e18;
    return { success: true, balance: balanceEth.toFixed(4) };
  } catch (e) {
    return { success: false, error: 'Node offline. Start ethii.exe to connect.' };
  }
});

// Send transaction
ipcMain.handle('send-tx', async (_, { privateKey, to, amount, gasPrice }) => {
  try {
    if (!provider) tryConnectProvider();
    const wallet = new ethers.Wallet(privateKey, provider);
    const tx = await wallet.sendTransaction({
      to,
      value: ethers.parseEther(amount),
      gasPrice: ethers.parseUnits(gasPrice || '0.5', 'gwei'),
      chainId: CHAIN_ID,
    });
    await tx.wait(1);
    return { success: true, hash: tx.hash };
  } catch (e) {
    return { success: false, error: e.message };
  }
});

// Get transaction history (last 10 blocks)
ipcMain.handle('get-tx-history', async (_, { address }) => {
  try {
    if (!provider) tryConnectProvider();
    const blockNum = await provider.getBlockNumber();
    const from = Math.max(0, blockNum - 1000);
    const logs = await provider.getLogs({ fromBlock: from, toBlock: blockNum });
    return { success: true, logs: logs.slice(0, 20) };
  } catch (e) {
    return { success: false, error: e.message };
  }
});

// Get node status — uses direct RPC fetch for reliability
ipcMain.handle('get-node-status', async () => {
  try {
    const blockHex = await rpcCall('eth_blockNumber', []);
    const blockNum = parseInt(blockHex, 16);
    const block = await rpcCall('eth_getBlockByNumber', ['latest', false]);
    // Reconnect ethers provider now that we know the node is up
    if (!provider) tryConnectProvider();
    return {
      success: true,
      blockNumber: blockNum,
      timestamp: block ? parseInt(block.timestamp, 16) : null,
      gasLimit: block ? parseInt(block.gasLimit, 16).toString() : null,
      rpcPort: RPC_PORT,
    };
  } catch (e) {
    return { success: false, error: 'Node offline', rpcPort: RPC_PORT };
  }
});


// Mining RPC helpers  tries local node first, falls back to VPS public node
async function rpcCall(method, params = []) {
  const urls = (RPC_URL !== PUBLIC_RPC_URL) ? [RPC_URL, PUBLIC_RPC_URL] : [PUBLIC_RPC_URL];
  let lastErr;
  for (const url of urls) {
    try {
      const resp = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
      });
      let json;
      try { json = await resp.json(); }
      catch (parseErr) {
        const raw = await resp.text().catch(() => '(unreadable)');
        throw new Error(`Invalid JSON from node (${method}): ${raw.slice(0, 120)}`);
      }
      if (json.error) throw new Error(json.error.message);
      return json.result;
    } catch (e) { lastErr = e; }
  }
  throw lastErr;
}
ipcMain.handle('mining-start', async (_, { threads }) => {
  try {
    await rpcCall('miner_start', [threads]);
    return { success: true };
  } catch (e) {
    return { success: false, error: e.message };
  }
});

ipcMain.handle('mining-stop', async () => {
  try {
    await rpcCall('miner_stop', []);
    return { success: true };
  } catch (e) {
    return { success: false, error: e.message };
  }
});

ipcMain.handle('mining-status', async () => {
  try {
    const mining = await rpcCall('miner_mining', []);
    const hashrate = await rpcCall('miner_hashrate', []);
    return { success: true, mining, hashrate };
  } catch (e) {
    return { success: false, mining: false, hashrate: 0 };
  }
});


// Return wallet app version
ipcMain.handle('get-version', () => app.getVersion());

// Export keystore dialog
ipcMain.handle('export-keystore', async () => {
  if (!fs.existsSync(WALLET_FILE)) return { success: false, error: 'No wallet found.' };
  const { filePath } = await dialog.showSaveDialog(mainWindow, {
    defaultPath: 'ethii-keystore.json',
    filters: [{ name: 'JSON', extensions: ['json'] }],
  });
  if (filePath) {
    fs.copyFileSync(WALLET_FILE, filePath);
    return { success: true };
  }
  return { success: false, error: 'Cancelled.' };
});


