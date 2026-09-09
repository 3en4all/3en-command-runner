param([string]$Root='C:\3EN-Agent')
$ErrorActionPreference='Stop'
$src=Join-Path $Root '3en-agent-runner-v4.0.3.ps1'
$dst=Join-Path $Root '3en-agent-runner-v4.0.3-openclaw.ps1'
$poller=Join-Path $Root '3en-openclaw-inbox.ps1'
$state=Join-Path $Root '3en-openclaw-inbox.state.json'
$log=Join-Path $Root '3en-openclaw-selfheal.log'
$out=Join-Path $Root '3en-openclaw-inbox.stdout.log'
$err=Join-Path $Root '3en-openclaw-inbox.stderr.log'
$procPattern=[regex]::Escape('3en-openclaw-inbox.ps1')
function Log([string]$m){Add-Content -LiteralPath $log -Value ('['+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+'] '+$m) -Encoding UTF8}
if(-not(Test-Path $src)){throw 'RUNNER403_SOURCE_MISSING'}
$bk=Join-Path $Root ('backups\openclaw-selfheal\'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $bk|Out-Null
foreach($f in @($dst,$poller,$state,$log,$out,$err)){if(Test-Path $f){Copy-Item $f $bk -Force}}
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
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.Name -in @('powershell.exe','pwsh.exe') -and $_.CommandLine -match $procPattern}|ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}
if(Test-Path $state){Remove-Item $state -Force}
Remove-Item $out,$err -Force -ErrorAction SilentlyContinue
$p=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$poller) -WorkingDirectory $Root -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
Start-Sleep 5
if($p.HasExited){$stderr='';$stdout='';if(Test-Path $err){$stderr=(Get-Content $err -Raw -ErrorAction SilentlyContinue)};if(Test-Path $out){$stdout=(Get-Content $out -Raw -ErrorAction SilentlyContinue)};Log ('OPENCLAW_INBOX_EXITED code='+$p.ExitCode);if($stdout){Log ('STDOUT='+($stdout -replace '[\r\n]+',' '))};if($stderr){Log ('STDERR='+($stderr -replace '[\r\n]+',' '))};Write-Host ('OPENCLAW_INBOX_EXIT_CODE='+$p.ExitCode);if($stdout){Write-Host ('OPENCLAW_INBOX_STDOUT='+($stdout -replace '[\r\n]+',' '))};if($stderr){Write-Host ('OPENCLAW_INBOX_STDERR='+($stderr -replace '[\r\n]+',' '))};throw 'OPENCLAW_INBOX_START_FAILED'}
$found=Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.ProcessId -eq $p.Id}
if(-not $found){throw 'OPENCLAW_INBOX_PROCESS_DISAPPEARED'}
Log ('OPENCLAW_INBOX_PID='+$p.Id)
Log 'OPENCLAW_SELFHEAL=PASS'
Write-Host ('OPENCLAW_INBOX_PID='+$p.Id)
Write-Host 'OPENCLAW_SELFHEAL=PASS'
