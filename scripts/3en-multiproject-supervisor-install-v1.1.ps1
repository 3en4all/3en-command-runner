param([ValidateSet('Install','Test','Rollback')][string]$Phase)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent'
$Repo='https://raw.githubusercontent.com/3en4all/3en-command-runner/main'
$Sup=Join-Path $Root '3en-multiproject-supervisor-v1.1.ps1'
$LegacyGeneric=Join-Path $Root '3en-project-inbox.ps1'
$LegacyOpenClaw=Join-Path $Root '3en-openclaw-inbox.ps1'
$BackupRoot=Join-Path $Root 'backups\multiproject-supervisor-v11'
$Marker=Join-Path $Root 'multiproject-supervisor-v11-install.json'
$StartupDir=Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$StartupNew=Join-Path $StartupDir '3EN-MultiProject-Supervisor-v11.cmd'
$StartupOld=Join-Path $StartupDir '3EN-Project-Inbox.cmd'
function Get-ProcByScript([string]$name){$pat=[regex]::Escape($name);Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.Name -in @('powershell.exe','pwsh.exe') -and $_.CommandLine -and $_.CommandLine -match $pat}}
function Get-SupProc{Get-ProcByScript '3en-multiproject-supervisor-v1.1.ps1'}
function Stop-Legacy{foreach($n in @('3en-project-inbox.ps1','3en-openclaw-inbox.ps1','3en-multiproject-supervisor-v1.ps1')){Get-ProcByScript $n|ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}}}
function Install{
 $stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$bak=Join-Path $BackupRoot $stamp;New-Item -ItemType Directory -Force -Path $bak|Out-Null
 foreach($p in @($LegacyGeneric,$LegacyOpenClaw,(Join-Path $Root '3en-project-inbox.state.json'),(Join-Path $Root '3en-openclaw-inbox.state.json'),(Join-Path $Root '3en-project-inbox.log'),(Join-Path $Root '3en-openclaw-inbox.log'),$StartupOld,$StartupNew)){if(Test-Path $p){Copy-Item $p $bak -Force}}
 Invoke-WebRequest -UseBasicParsing -Uri ($Repo+'/automation/3en-multiproject-supervisor-v1.1.ps1?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -OutFile $Sup -TimeoutSec 30
 $tok=$null;$err=$null;[System.Management.Automation.Language.Parser]::ParseFile($Sup,[ref]$tok,[ref]$err)|Out-Null;if(@($err).Count -gt 0){throw ('SUPERVISOR_V11_SYNTAX_ERRORS='+@($err).Count)}
 Stop-Legacy
 New-Item -ItemType Directory -Force -Path $StartupDir|Out-Null
 $line='@echo off'+[Environment]::NewLine+'start "3EN MultiProject Supervisor v1.1" /min powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$Sup+'"'
 Set-Content -LiteralPath $StartupNew -Value $line -Encoding ASCII
 if(Test-Path $StartupOld){Remove-Item $StartupOld -Force}
 Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$Sup) -WorkingDirectory $Root|Out-Null
 Start-Sleep -Seconds 5
 if(-not(Get-SupProc)){throw 'SUPERVISOR_V11_PROCESS_NOT_RUNNING'}
 $health=Join-Path $Root '3en-multiproject-supervisor.health.json';if(-not(Test-Path $health)){throw 'SUPERVISOR_V11_HEALTH_MISSING'}
 $h=Get-Content $health -Raw|ConvertFrom-Json;if(@($h.lanes).Count -ne 3){throw 'SUPERVISOR_V11_LANE_COUNT_INVALID'}
 [pscustomobject]@{installedAt=(Get-Date).ToString('o');backup=$bak;startup=$StartupNew;health=$health;version='1.1'}|ConvertTo-Json|Set-Content $Marker -Encoding UTF8
 Write-Host ('MULTIPROJECT_SUPERVISOR_V11_INSTALL=PASS;BACKUP='+$bak+';LANES='+@($h.lanes).Count)
}
function Test{
 if(-not(Get-SupProc)){throw 'SUPERVISOR_V11_PROCESS_NOT_RUNNING'}
 $health=Join-Path $Root '3en-multiproject-supervisor.health.json';if(-not(Test-Path $health)){throw 'SUPERVISOR_V11_HEALTH_MISSING'};$h=Get-Content $health -Raw|ConvertFrom-Json
 $names=@($h.lanes|ForEach-Object{$_.lane});foreach($n in @('network-privacy','security-monitor','openclaw')){if($names -notcontains $n){throw ('LANE_MISSING='+$n)}}
 foreach($legacy in @('3en-project-inbox.ps1','3en-openclaw-inbox.ps1','3en-multiproject-supervisor-v1.ps1')){if(Get-ProcByScript $legacy){throw ('LEGACY_PROCESS_STILL_RUNNING='+$legacy)}}
 if(-not(Test-Path $StartupNew)){throw 'SUPERVISOR_V11_STARTUP_MISSING'}
 Write-Host ('MULTIPROJECT_SUPERVISOR_V11_TEST=PASS;STATUS='+$h.status+';LANES='+$names.Count)
}
function Rollback{
 if(-not(Test-Path $Marker)){Write-Host 'ROLLBACK_NO_MARKER';return};$m=Get-Content $Marker -Raw|ConvertFrom-Json
 Get-SupProc|ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}
 if(Test-Path $StartupNew){Remove-Item $StartupNew -Force}
 if(Test-Path (Join-Path $m.backup '3EN-Project-Inbox.cmd')){Copy-Item (Join-Path $m.backup '3EN-Project-Inbox.cmd') $StartupOld -Force}
 if(Test-Path $LegacyGeneric){Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$LegacyGeneric) -WorkingDirectory $Root|Out-Null}
 if(Test-Path $LegacyOpenClaw){Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$LegacyOpenClaw) -WorkingDirectory $Root|Out-Null}
 Write-Host 'MULTIPROJECT_SUPERVISOR_V11_ROLLBACK=PASS'
}
switch($Phase){Install{Install};Test{Test};Rollback{Rollback}}
