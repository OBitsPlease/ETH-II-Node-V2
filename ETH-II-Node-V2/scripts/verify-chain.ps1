param(
  [string]$RpcUrl = 'http://127.0.0.1:8545'
)

$ExpectedNet = '20482'
$ExpectedChain = '0x5002'
$ExpectedGenesis = '0xce9eec5ec053f791d5f833e7d385a1fd214daa85928ecbaba04381fd1b16b1f2'

function Invoke-Rpc([string]$Method) {
  $body = @{ jsonrpc='2.0'; method=$Method; params=@(); id=1 } | ConvertTo-Json -Compress
  Invoke-RestMethod -Uri $RpcUrl -Method Post -ContentType 'application/json' -Body $body
}

$net = (Invoke-Rpc -Method 'net_version').result
$chain = (Invoke-Rpc -Method 'eth_chainId').result
$nodeInfo = (Invoke-Rpc -Method 'admin_nodeInfo').result
$genesis = $nodeInfo.protocols.eth.genesis

Write-Host "net_version=$net"
Write-Host "eth_chainId=$chain"
Write-Host "genesis=$genesis"

if ($net -ne $ExpectedNet) { throw 'FAIL net_version' }
if ($chain -ne $ExpectedChain) { throw 'FAIL eth_chainId' }
if ($genesis -ne $ExpectedGenesis) { throw 'FAIL genesis' }

Write-Host 'PASS canonical ETH-II chain identity' -ForegroundColor Green
