$ErrorActionPreference='Stop'
$p='C:\3EN-Agent\security-monitor-integration\3en-security-monitor-bridge-v1.py'
if(-not(Test-Path $p)){throw 'NP010_BRIDGE_SOURCE_MISSING'}
$l=Get-Content -LiteralPath $p
Write-Host '=== NP010_STATUS_SOURCE_START ==='
for($i=49;$i-le [Math]::Min(127,$l.Count-1);$i++){Write-Host (($i+1).ToString()+': '+$l[$i])}
Write-Host '=== NP010_STATUS_SOURCE_END ==='
