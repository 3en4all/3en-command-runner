param([string]$Root='C:\3EN-Agent')
$ErrorActionPreference='Stop'
$src=Join-Path $Root '3en-agent-runner-v4.0.3.ps1'
$dst=Join-Path $Root '3en-agent-runner-v4.0.3-openclaw.ps1'
$poller=Join-Path $Root '3en-openclaw-inbox.ps1'
$state=Join-Path $Root '3en-openclaw-inbox.state.json'
$log=Join-Path $Root '3en-openclaw-selfheal.log'
function Log([string]$m){Add-Content -LiteralPath $log -Value ('['+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+'] '+$m) -Encoding UTF8}
if(-not(Test-Path $src)){throw 'RUNNER403_SOURCE_MISSING'}
$bk=Join-Path $Root ('backups\openclaw-selfheal\'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $bk|Out-Null
foreach($f in @($dst,$poller,$state,$log)){if(Test-Path $f){Copy-Item $f $bk -Force}}
Log ('BACKUP='+$bk)
$raw=Get-Content -LiteralPath $src -Raw
if($raw -notmatch [regex]::Escape('Global\3EN-Agent-Project-v403')){throw 'SOURCE_MUTEX_MARKER_MISSING'}
$patched=$raw.Replace('Global\3EN-Agent-Project-v403','Global\3EN-Agent-OpenClaw-v403')
Set-Content -LiteralPath $dst -Value $patched -Encoding UTF8
$t=$null;$e=$null;[System.Management.Automation.Language.Parser]::ParseFile($dst,[ref]$t,[ref]$e)|Out-Null
if(@($e).Count -gt 0){throw ('OPENCLAW_RUNNER_SYNTAX_ERRORS='+@($e).Count)}
$ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
Invoke-WebRequest -UseBasicParsing -Uri ('https://raw.githubusercontent.com/3en4all/3en-command-runner/main/automation/3en-openclaw-inbox.ps1?ts='+$ts) -OutFile $poller -TimeoutSec 30
$t=$null;$e=$null;[System.Management.Automation.Language.Parser]::ParseFile($poller,[ref]$t,[ref]$e)|Out-Null
if(@($e).Count -gt 0){throw ('OPENCLAW_INBOX_SYNTAX_ERRORS='+@($e).Count)}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine -match '3en-openclaw-inbox\\.ps1'}|ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}
if(Test-Path $state){Remove-Item $state -Force}
Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$poller) -WorkingDirectory $Root|Out-Null
Start-Sleep 5
$p=Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine -match '3en-openclaw-inbox\\.ps1'}
if(-not $p){throw 'OPENCLAW_INBOX_NOT_RUNNING'}
Log 'OPENCLAW_SELFHEAL=PASS'
Write-Host 'OPENCLAW_SELFHEAL=PASS'
