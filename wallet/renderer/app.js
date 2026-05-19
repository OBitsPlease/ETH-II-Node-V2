// ETHII Wallet — renderer app logic

// Public RPC endpoint — update this when VPS is deployed
// Leave empty to show localhost only
const PUBLIC_RPC_URL = 'http://91.99.231.217:8545';

let currentAddress = null;
let currentPrivateKey = null;

// Update MetaMask RPC chip: show public RPC if available, otherwise localhost
(function initMetaMaskRpc() {
  const el = document.getElementById('metamask-rpc-url');
  const note = document.getElementById('metamask-rpc-note');
  if (!el) return;
  if (PUBLIC_RPC_URL) {
    el.textContent = PUBLIC_RPC_URL;
    if (note) note.innerHTML = '<strong>Public RPC:</strong> Use the URL above to connect MetaMask from any device. You do not need to run a local node.';
  }
  // If empty, localhost default stays with the "coming soon" note
})();

// Populate version badge from main process
window.ethii.getVersion().then(v => {
  const tag = 'v' + v;
  const tb = document.getElementById('app-version');
  const sb = document.getElementById('sidebar-version');
  if (tb) tb.textContent = tag;
  if (sb) sb.textContent = tag;
}).catch(() => {});


// ---- Utility ----
function showToast(msg, duration = 2500) {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.classList.remove('hidden');
  t.classList.add('show');
  setTimeout(() => { t.classList.remove('show'); t.classList.add('hidden'); }, duration);
}

function copyToClipboard(text) {
  navigator.clipboard.writeText(text).then(() => showToast('Copied to clipboard!'));
}

function showError(elId, msg) {
  const el = document.getElementById(elId);
  el.textContent = msg;
  el.classList.remove('hidden');
}

function hideError(elId) {
  document.getElementById(elId).classList.add('hidden');
}

function showStatus(elId, msg, type) {
  const el = document.getElementById(elId);
  el.textContent = msg;
  el.className = `status-msg ${type}`;
  el.classList.remove('hidden');
}

// ---- Screen navigation ----
function showScreen(id) {
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  const target = document.getElementById(id);
  target.classList.add('active');
}

// ---- Dashboard view switching ----
function showView(id) {
  document.querySelectorAll('.dash-view').forEach(v => v.classList.remove('active'));
  document.getElementById(id).classList.add('active');
  document.querySelectorAll('.nav-item').forEach(n => {
    n.classList.toggle('active', n.dataset.view === id);
  });
}

// ---- Window controls ----
document.getElementById('btn-min').addEventListener('click', () => window.ethii.minimize());
document.getElementById('btn-max').addEventListener('click', () => window.ethii.maximize());
document.getElementById('btn-close').addEventListener('click', () => window.ethii.close());

// ---- Determine initial screen ----
async function initApp() {
  const exists = await window.ethii.walletExists();
  if (exists) {
    // Show unlock if wallet file found
    document.getElementById('card-unlock').querySelector('button').style.boxShadow = '0 0 12px rgba(139,92,246,0.5)';
  }
  showScreen('screen-setup');
}

// ---- Setup card buttons ----
document.getElementById('card-new').querySelector('button').addEventListener('click', () => showScreen('screen-new-wallet'));
document.getElementById('card-unlock').querySelector('button').addEventListener('click', async () => {
  const exists = await window.ethii.walletExists();
  if (!exists) { showToast('No wallet found. Create one first.'); return; }
  showScreen('screen-unlock');
});
document.getElementById('card-import').querySelector('button').addEventListener('click', () => showScreen('screen-import'));

// ---- Back buttons ----
document.getElementById('back-from-new').addEventListener('click', () => showScreen('screen-setup'));
document.getElementById('back-from-unlock').addEventListener('click', () => showScreen('screen-setup'));
document.getElementById('back-from-import').addEventListener('click', () => showScreen('screen-setup'));

// ---- Create new wallet ----
document.getElementById('btn-generate').addEventListener('click', async () => {
  const pw = document.getElementById('new-password').value;
  const pw2 = document.getElementById('new-password-confirm').value;
  if (pw.length < 8) { showToast('Password must be at least 8 characters.'); return; }
  if (pw !== pw2)    { showToast('Passwords do not match.'); return; }

  document.getElementById('btn-generate').textContent = 'Generating...';
  const wallet = await window.ethii.createWallet();
  const saved  = await window.ethii.saveWallet({ privateKey: wallet.privateKey, password: pw });
  document.getElementById('btn-generate').textContent = 'Generate Wallet';

  if (!saved.success) { showToast('Error saving wallet: ' + saved.error); return; }

  document.getElementById('new-address-display').value = wallet.address;
  document.getElementById('new-privkey-display').value = wallet.privateKey;
  document.getElementById('new-mnemonic-display').textContent = wallet.mnemonic || '(no mnemonic — imported key)';

  currentAddress   = wallet.address;
  currentPrivateKey = wallet.privateKey;

  document.getElementById('new-wallet-step1').classList.add('hidden');
  document.getElementById('new-wallet-step2').classList.remove('hidden');
});

document.getElementById('btn-go-dashboard').addEventListener('click', () => openDashboard());

// ---- Unlock wallet ----
document.getElementById('btn-unlock').addEventListener('click', async () => {
  const pw = document.getElementById('unlock-password').value;
  hideError('unlock-error');
  document.getElementById('btn-unlock').textContent = 'Unlocking...';
  const result = await window.ethii.unlockWallet({ password: pw });
  document.getElementById('btn-unlock').textContent = 'Unlock →';
  if (!result.success) { showError('unlock-error', result.error); return; }
  currentAddress    = result.address;
  currentPrivateKey = result.privateKey;
  openDashboard();
});

// ---- Import wallet ----
document.getElementById('btn-import').addEventListener('click', async () => {
  const pk = document.getElementById('import-privkey').value.trim();
  const pw = document.getElementById('import-password').value;
  hideError('import-error');
  if (!pk) { showError('import-error', 'Please enter a private key.'); return; }
  if (pw.length < 8) { showError('import-error', 'Password must be at least 8 characters.'); return; }
  document.getElementById('btn-import').textContent = 'Importing...';
  const result = await window.ethii.importWallet({ privateKey: pk, password: pw });
  document.getElementById('btn-import').textContent = 'Import Wallet';
  if (!result.success) { showError('import-error', result.error); return; }
  currentAddress    = result.address;
  // Unlock immediately to get privateKey in memory
  const unlocked = await window.ethii.unlockWallet({ password: pw });
  currentPrivateKey = unlocked.privateKey;
  openDashboard();
});

// ---- Open Dashboard ----
function openDashboard() {
  if (!currentAddress) return;
  document.getElementById('dash-address').textContent = truncateAddress(currentAddress);
  document.getElementById('receive-address').textContent = currentAddress;
  document.getElementById('receive-address-input').value = currentAddress;
  // Update node command with real address
  document.querySelector('.code-block').textContent =
    `ethii.exe --datadir ".\\data" --networkid 2048 --http --http.port 8545 --http.api "eth,net,web3,miner,ethash,txpool" --http.corsdomain "*" --miner.pending.feeRecipient ${currentAddress}`;
  showScreen('screen-dashboard');
  showView('view-wallet');
  refreshBalance();
  refreshNodeStatus();
  // Update stratum URL with current address
  const stratumEl = document.getElementById('stratum-url');
  if (stratumEl) stratumEl.textContent = `stratum+tcp://${currentAddress}.rig1@localhost:8546`;
}

function truncateAddress(addr) {
  return addr.slice(0, 8) + '…' + addr.slice(-6);
}

// ---- Balance ----
async function refreshBalance() {
  console.log('[UI] refreshBalance() called for', currentAddress);
  document.getElementById('balance-value').textContent = '…';
  const result = await window.ethii.getBalance({ address: currentAddress });
  console.log('[UI] getBalance result:', result);
  if (result.success) {
    const formattedBalance = parseFloat(result.balance).toFixed(4);
    console.log('[UI] Setting balance to:', formattedBalance);
    document.getElementById('balance-value').textContent = formattedBalance;
  } else {
    console.log('[UI] Balance error:', result.error);
    document.getElementById('balance-value').textContent = '—';
    showToast(result.error);
  }
}

document.getElementById('btn-refresh-balance').addEventListener('click', refreshBalance);

// ---- Send transaction ----
document.getElementById('btn-send').addEventListener('click', async () => {
  const to       = document.getElementById('send-to').value.trim();
  const amount   = document.getElementById('send-amount').value.trim();
  const gasPrice = document.getElementById('send-gasprice').value.trim();
  const password = document.getElementById('send-password').value;

  if (!to || !amount) { showStatus('send-status', 'Please fill in all fields.', 'error'); return; }

  // Unlock private key using password
  showStatus('send-status', 'Signing transaction…', 'loading');
  document.getElementById('btn-send').textContent = 'Sending…';

  let pk = currentPrivateKey;
  if (!pk) {
    const unlocked = await window.ethii.unlockWallet({ password });
    if (!unlocked.success) {
      showStatus('send-status', 'Wrong password.', 'error');
      document.getElementById('btn-send').textContent = 'Send Transaction →';
      return;
    }
    pk = unlocked.privateKey;
  }

  const result = await window.ethii.sendTx({ privateKey: pk, to, amount, gasPrice: gasPrice || '0.5' });
  document.getElementById('btn-send').textContent = 'Send Transaction →';
  if (result.success) {
    showStatus('send-status', `✔ Sent! TX: ${result.hash}`, 'success');
    document.getElementById('send-to').value = '';
    document.getElementById('send-amount').value = '';
    setTimeout(refreshBalance, 2000);
  } else {
    showStatus('send-status', result.error, 'error');
  }
});

// ---- Node status ----
async function refreshNodeStatus() {
  console.log('[UI] refreshNodeStatus() called');
  const indicator = document.getElementById('node-indicator');
  const statusText = document.getElementById('node-status-text');
  const result = await window.ethii.getNodeStatus();
  console.log('[UI] getNodeStatus result:', result);
  if (result.success) {
    indicator.className = 'node-indicator online';
    statusText.textContent = `Connected — Block #${result.blockNumber}`;
    document.getElementById('node-block').textContent = result.blockNumber;
    console.log('[UI] Node online, block:', result.blockNumber);
    // Auto-mine: if enabled and not already mining, start
    const autoMine = document.getElementById('auto-mine-toggle');
    if (autoMine && autoMine.checked) {
      const status = await window.ethii.minerStatus();
      if (status.success && !status.mining) {
        const threads = parseInt(document.getElementById('cpu-thread-count').value) || 1;
        await window.ethii.minerStart(threads);
        pollMiningStatus();
      }
    }
  } else {
    console.log('[UI] Node offline, error:', result.error);
    indicator.className = 'node-indicator offline';
    statusText.textContent = 'Node offline — start ethii.exe to connect';
    document.getElementById('node-block').textContent = '—';
  }
}

document.getElementById('btn-refresh-node').addEventListener('click', refreshNodeStatus);

// Auto-refresh node status every 10s
setInterval(refreshNodeStatus, 10000);

// ---- Nav items ----
document.querySelectorAll('.nav-item').forEach(item => {
  item.addEventListener('click', () => showView(item.dataset.view));
});

document.querySelectorAll('[data-view]').forEach(btn => {
  if (!btn.classList.contains('nav-item')) {
    btn.addEventListener('click', () => showView(btn.dataset.view));
  }
});

// ---- Copy buttons ----
document.querySelectorAll('.btn-copy').forEach(btn => {
  btn.addEventListener('click', () => {
    const target = document.getElementById(btn.dataset.target);
    if (target) copyToClipboard(target.value);
  });
});

document.getElementById('copy-address').addEventListener('click', () => {
  if (currentAddress) copyToClipboard(currentAddress);
});

// ---- Reveal private key ----
document.querySelectorAll('.btn-reveal').forEach(btn => {
  btn.addEventListener('click', () => {
    const input = document.getElementById(btn.dataset.target);
    if (!input) return;
    input.type = input.type === 'password' ? 'text' : 'password';
    btn.textContent = input.type === 'password' ? '👁' : '🙈';
  });
});

// ---- Lock wallet ----
document.getElementById('btn-lock').addEventListener('click', () => {
  currentAddress    = null;
  currentPrivateKey = null;
  document.getElementById('unlock-password').value = '';
  showScreen('screen-setup');
  showToast('Wallet locked.');
});

// ---- Export keystore ----
document.getElementById('btn-export').addEventListener('click', async () => {
  const result = await window.ethii.exportKeystore();
  if (result.success) showToast('Keystore exported!');
  else showToast('Export failed: ' + result.error);
});

// ---- Enter key support ----
document.getElementById('unlock-password').addEventListener('keydown', e => {
  if (e.key === 'Enter') document.getElementById('btn-unlock').click();
});
document.getElementById('new-password-confirm').addEventListener('keydown', e => {
  if (e.key === 'Enter') document.getElementById('btn-generate').click();
});

// ---- Auto-refresh balance every 30s when on dashboard ----
setInterval(() => {
  const dashboard = document.getElementById('screen-dashboard');
  if (dashboard.classList.contains('active') && currentAddress) {
    refreshBalance();
  }
}, 30000);

// ---- Init ----
initApp();

// ---- Mining ----
let miningPollInterval = null;

function updateMiningStatus(mining, hashrate) {
  const indicator = document.getElementById('mining-indicator');
  const statusText = document.getElementById('mining-status-text');
  const statusChip = document.getElementById('mining-status-chip');
  const hashrateEl = document.getElementById('mining-hashrate-display');
  const btnStart = document.getElementById('btn-start-mining');
  const btnStop = document.getElementById('btn-stop-mining');

  const hr = Number(hashrate) || 0;
  const isActive = mining || hr > 0;

  if (isActive) {
    indicator.className = 'node-indicator online';
    statusText.textContent = 'Mining active';
    statusChip.textContent = 'Mining';
    btnStart.classList.add('hidden');
    btnStop.classList.remove('hidden');
  } else {
    indicator.className = 'node-indicator offline';
    statusText.textContent = 'Not mining';
    statusChip.textContent = 'Stopped';
    btnStart.classList.remove('hidden');
    btnStop.classList.add('hidden');
  }

  hashrateEl.textContent = hr > 1e6
    ? (hr / 1e6).toFixed(2) + ' MH/s'
    : hr > 1e3
      ? (hr / 1e3).toFixed(2) + ' KH/s'
      : hr.toFixed(0) + ' H/s';
}

async function pollMiningStatus() {
  const result = await window.ethii.minerStatus();
  if (result.success) {
    updateMiningStatus(result.mining, result.hashrate);
  }
}

// CPU toggle shows/hides thread settings
document.getElementById('cpu-mine-toggle').addEventListener('change', function () {
  const settings = document.getElementById('cpu-mine-settings');
  if (this.checked) {
    settings.classList.remove('hidden');
  } else {
    settings.classList.add('hidden');
  }
});

// Sync thread slider ↔ number input
document.getElementById('cpu-thread-slider').addEventListener('input', function () {
  document.getElementById('cpu-thread-count').value = this.value;
});
document.getElementById('cpu-thread-count').addEventListener('input', function () {
  const val = Math.max(1, Math.min(parseInt(this.value) || 1, 64));
  this.value = val;
  document.getElementById('cpu-thread-slider').value = val;
});

// Start mining button
document.getElementById('btn-start-mining').addEventListener('click', async () => {
  const cpuEnabled = document.getElementById('cpu-mine-toggle').checked;
  if (!cpuEnabled) {
    showToast('Enable CPU mining first.');
    return;
  }
  const threads = parseInt(document.getElementById('cpu-thread-count').value) || 1;
  const result = await window.ethii.minerStart(threads);
  if (result.success) {
    showToast('Mining started!');
    pollMiningStatus();
  } else {
    showToast('Failed to start mining: ' + (result.error || 'unknown error'));
  }
});

// Stop mining button
document.getElementById('btn-stop-mining').addEventListener('click', async () => {
  const result = await window.ethii.minerStop();
  if (result.success) {
    showToast('Mining stopped.');
    pollMiningStatus();
  } else {
    showToast('Failed to stop mining: ' + (result.error || 'unknown error'));
  }
});

// Auto-mine toggle persistence
const autoMineToggle = document.getElementById('auto-mine-toggle');
if (autoMineToggle) {
  autoMineToggle.checked = localStorage.getItem('autoMine') === 'true';
  autoMineToggle.addEventListener('change', function () {
    localStorage.setItem('autoMine', this.checked);
  });
}

// Poll mining status every 5s when on dashboard
setInterval(() => {
  const dashboard = document.getElementById('screen-dashboard');
  if (dashboard && dashboard.classList.contains('active') && currentAddress) {
    pollMiningStatus();
  }
}, 5000);

