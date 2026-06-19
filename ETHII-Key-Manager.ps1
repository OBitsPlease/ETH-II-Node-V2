# ETHII Key Manager - manage gated download keys on the EU VPS
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$VpsHost = '91.99.231.217'
$SshKey  = Join-Path $env:USERPROFILE '.ssh\ethii_vps'

function Invoke-Vps([string]$Cmd) {
    $out = ssh -i $SshKey -o ConnectTimeout=10 "root@$VpsHost" $Cmd 2>&1
    if ($LASTEXITCODE -ne 0) { throw "SSH failed: $out" }
    return ($out -join "`n")
}

$form = New-Object Windows.Forms.Form
$form.Text = 'ETHII Key Manager'
$form.Size = New-Object Drawing.Size(900, 560)
$form.StartPosition = 'CenterScreen'

$list = New-Object Windows.Forms.ListView
$list.View = 'Details'
$list.FullRowSelect = $true
$list.Location = New-Object Drawing.Point(10, 10)
$list.Size = New-Object Drawing.Size(865, 330)
$list.Anchor = 'Top,Left,Right,Bottom'
[void]$list.Columns.Add('Key', 280)
[void]$list.Columns.Add('Label', 180)
[void]$list.Columns.Add('Created (UTC)', 140)
[void]$list.Columns.Add('Revoked', 70)
[void]$list.Columns.Add('Downloads', 80)
$form.Controls.Add($list)

$status = New-Object Windows.Forms.Label
$status.Location = New-Object Drawing.Point(10, 495)
$status.Size = New-Object Drawing.Size(865, 20)
$status.Anchor = 'Bottom,Left,Right'
$form.Controls.Add($status)

$logBox = New-Object Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ScrollBars = 'Vertical'
$logBox.ReadOnly = $true
$logBox.Font = New-Object Drawing.Font('Consolas', 9)
$logBox.Location = New-Object Drawing.Point(10, 385)
$logBox.Size = New-Object Drawing.Size(865, 105)
$logBox.Anchor = 'Bottom,Left,Right'
$form.Controls.Add($logBox)

function Refresh-Keys {
    $status.Text = 'Loading...'
    $form.Refresh()
    try {
        $raw = Invoke-Vps 'cat /opt/ethii-downloads/keys.json; echo __SPLIT__; cat /opt/ethii-downloads/download.log 2>/dev/null'
        $parts = $raw -split '__SPLIT__'
        $keys = ($parts[0] | ConvertFrom-Json).keys
        $script:LogLines = if ($parts.Count -gt 1) { $parts[1].Trim() -split "`n" } else { @() }
        $counts = @{}
        foreach ($line in $script:LogLines) {
            $f = $line -split '\|' | ForEach-Object { $_.Trim() }
            if ($f.Count -ge 3 -and $f[1] -eq 'download') { $counts[$f[2]] = 1 + [int]$counts[$f[2]] }
        }
        $list.Items.Clear()
        foreach ($p in $keys.PSObject.Properties) {
            $it = New-Object Windows.Forms.ListViewItem($p.Name)
            [void]$it.SubItems.Add([string]$p.Value.label)
            [void]$it.SubItems.Add([string]$p.Value.created)
            [void]$it.SubItems.Add($(if ($p.Value.revoked) { 'YES' } else { 'no' }))
            [void]$it.SubItems.Add([string][int]$counts[$p.Name])
            if ($p.Value.revoked) { $it.ForeColor = [Drawing.Color]::Gray }
            [void]$list.Items.Add($it)
        }
        $status.Text = "$($list.Items.Count) keys loaded - $(Get-Date -Format 'HH:mm:ss')"
    } catch { $status.Text = "ERROR: $_" }
}

function Get-SelectedKey {
    if ($list.SelectedItems.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show('Select a key first.', 'ETHII Key Manager') | Out-Null
        return $null
    }
    return $list.SelectedItems[0].Text
}

$btnY = 350
$buttons = @(
    @{ Text = 'New Key'; X = 10; Click = {
        $label = [Microsoft.VisualBasic.Interaction]::InputBox('Label for the new key (who is it for?):', 'New Key')
        if ($label) {
            try {
                $key = (Invoke-Vps "ethii-keys add '$($label -replace "'", '')'").Trim()
                [Windows.Forms.Clipboard]::SetText($key)
                [Windows.Forms.MessageBox]::Show("New key (copied to clipboard):`n`n$key", 'Key Created') | Out-Null
                Refresh-Keys
            } catch { $status.Text = "ERROR: $_" }
        }
    } }
    @{ Text = 'Revoke'; X = 110; Click = {
        $k = Get-SelectedKey; if ($k) {
            if ([Windows.Forms.MessageBox]::Show("Revoke $k`?", 'Confirm', 'YesNo') -eq 'Yes') {
                try { Invoke-Vps "ethii-keys revoke $k" | Out-Null; Refresh-Keys } catch { $status.Text = "ERROR: $_" }
            }
        }
    } }
    @{ Text = 'Unrevoke'; X = 210; Click = {
        $k = Get-SelectedKey; if ($k) {
            try { Invoke-Vps "ethii-keys unrevoke $k" | Out-Null; Refresh-Keys } catch { $status.Text = "ERROR: $_" }
        }
    } }
    @{ Text = 'Copy Key'; X = 310; Click = {
        $k = Get-SelectedKey; if ($k) { [Windows.Forms.Clipboard]::SetText($k); $status.Text = "Copied $k" }
    } }
    @{ Text = 'Key Log'; X = 410; Click = {
        $k = Get-SelectedKey; if ($k) {
            $logBox.Lines = @($script:LogLines | Where-Object { $_ -match [regex]::Escape($k) } | Select-Object -Last 200)
            if (-not $logBox.Lines) { $logBox.Text = '(no activity for this key)' }
        }
    } }
    @{ Text = 'Full Log'; X = 510; Click = { $logBox.Lines = @($script:LogLines | Select-Object -Last 200) } }
    @{ Text = 'Refresh'; X = 610; Click = { Refresh-Keys } }
)
Add-Type -AssemblyName Microsoft.VisualBasic
foreach ($b in $buttons) {
    $btn = New-Object Windows.Forms.Button
    $btn.Text = $b.Text
    $btn.Location = New-Object Drawing.Point($b.X, $btnY)
    $btn.Size = New-Object Drawing.Size(90, 28)
    $btn.Anchor = 'Bottom,Left'
    $btn.Add_Click($b.Click)
    $form.Controls.Add($btn)
}

$form.Add_Shown({ Refresh-Keys })
[void]$form.ShowDialog()
