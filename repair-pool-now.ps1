$ErrorActionPreference = 'Stop'
$key = Join-Path $env:USERPROFILE '.ssh\ethii_vps'
$peer87 = 'enode://b096bfae7d5e9a7cc985e68726280b75b0a0ef80ce419db5ed5152e9bee7bf83d35ae8b13b34879a0bf36d73a9a674bb61b02f3777745ed770e3150a39c7de5b@91.99.231.217:30303'
$peer91 = 'enode://05f7f1c669368d16829699b6e1ddffbd8a3fee08a1301cac33922ad05f56fd53aadbca02f326d6b1c863c560c9adf30a75b44d45e7448ebb41d9c47235204fdf@87.99.142.128:30303'

function B64($obj){ [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($obj|ConvertTo-Json -Compress))) }
$add87 = B64 @{jsonrpc='2.0';id=1;method='admin_addTrustedPeer';params=@($peer87)}
$add91 = B64 @{jsonrpc='2.0';id=1;method='admin_addTrustedPeer';params=@($peer91)}
$pc    = B64 @{jsonrpc='2.0';id=2;method='net_peerCount';params=@()}

$cmd87 = "echo $add87 | base64 -d | curl -sS -H 'Content-Type: application/json' --data @- http://127.0.0.1:8545; echo; " +
         "echo $pc | base64 -d | curl -sS -H 'Content-Type: application/json' --data @- http://127.0.0.1:8545; echo; " +
         "systemctl start ethii-stratum; systemctl is-active ethii-stratum"
$cmd91 = "echo $add91 | base64 -d | curl -sS -H 'Content-Type: application/json' --data @- http://127.0.0.1:8545; echo; " +
         "echo $pc | base64 -d | curl -sS -H 'Content-Type: application/json' --data @- http://127.0.0.1:8545; echo"

ssh -i $key root@87.99.142.128 $cmd87
ssh -i $key root@91.99.231.217 $cmd91
