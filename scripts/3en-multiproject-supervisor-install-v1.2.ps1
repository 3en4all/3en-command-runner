param([ValidateSet('Install','Test','Rollback')][string]$Phase)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent'
$Repo='https://raw.githubusercontent.com/3en4all/3en-command-runner/main'
$Sup=Join-Path $Root '3en-multiproject-supervisor-v1.2.ps1'
$BackupRoot=Join-Path $Root 'backups\multiproject-supervisor-v12'
$Marker=Join-Path $Root 'multiproject-supervisor-v12-install.json'
$StartupDir=Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$StartupNew=Join-Path $StartupDir '3EN-MultiProject-Supervisor-v12.cmd'
function Get-ProcByScript([string]$name){$pat=[regex]::Escape($name);Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.Name -in @('powershell.exe','pwsh.exe') -and $_.CommandLine -and $_.CommandLine -match $pat}}
function Stop-Old{foreach($n in @('3en-multiproject-supervisor-v1.ps1','3en-multiproject-supervisor-v1.1.ps1','3en-multiproject-supervisor-v1.2.ps1')){Get-ProcByScript $n|ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}}}
function Install{
 $stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$bak=Join-Path $BackupRoot $stamp;New-Item -ItemType Directory -Force -Path $bak|Out-Null
 foreach($p in @((Join-Path $Root '3en-multiproject-supervisor-v1.1.ps1'),(Join-Path $Root '3en-multiproject-supervisor-v1.2.ps1'),(Join-Path $Root '3en-multiproject-supervisor.health.json'),(Join-Path $Root '3en-multiproject-supervisor-v12.health.json'),(Join-Path $Root '3en-multiproject-supervisor.log'),(Join-Path $Root '3en-multiproject-supervisor-v12.log'),(Join-Path $Root 'supervisor-state'),(Join-Path $Root 'supervisor-state-v12'),$StartupNew,(Join-Path $StartupDir '3EN-MultiProject-Supervisor-v11.cmd'))){if(Test-Path $p){Copy-Item $p $bak -Recurse -Force}}
 Stop-Old
 Invoke-WebRequest -UseBasicParsing -Uri ($Repo+'/automation/3en-multiproject-supervisor-v1.2.ps1?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -OutFile $Sup -TimeoutSec 30
 $raw=Get-Content $Sup -Raw
 $old="'-ProjectPath',`$local"
 $new="'-ProjectPath',`$project"
 if($raw -notmatch [regex]::Escape($old)){throw 'SUPERVISOR_V12_HANDOFF_MARKER_MISSING'}
 $raw=$raw.Replace($old,$new)
 $revOld='          $rev=[string]$ptr.revision;$project=[string]$ptr.projectPath;$enabled=[bool]$ptr.enabled`n          $s.pointerRevision=$rev;$s.pointerProject=$project'
 $revNew='          $rev=[string]$ptr.revision;$project=[string]$ptr.projectPath;$enabled=[bool]$ptr.enabled`n          $previousPointerRevision=[string]$s.pointerRevision`n          if($previousPointerRevision -ne $rev){$s.attempts=0;$s.lastError='''' ;$s.nextRetryUtc='''' ;$s.lastExitCode=$null;$s.status=''NEW'';Log (''REVISION_RESET lane=''+$lane+'' old=''+$previousPointerRevision+'' new=''+$rev)}`n          $s.pointerRevision=$rev;$s.pointerProject=$project'
 $revOld=$revOld.Replace('`n',[Environment]::NewLine);$revNew=$revNew.Replace('`n',[Environment]::NewLine)
 if($raw -notmatch [regex]::Escape($revOld)){throw 'SUPERVISOR_V12_REVISION_MARKER_MISSING'}
 $raw=$raw.Replace($revOld,$revNew)
 Set-Content -LiteralPath $Sup -Value $raw -Encoding UTF8
 $tok=$null;$err=$null;[System.Management.Automation.Language.Parser]::ParseFile($Sup,[ref]$tok,[ref]$err)|Out-Null;if(@($err).Count -gt 0){throw ('SUPERVISOR_V12_SYNTAX_ERRORS='+@($err).Count)}
 $patched=Get-Content $Sup -Raw
 if($patched -notmatch [regex]::Escape($new)){throw 'SUPERVISOR_V12_HANDOFF_PATCH_FAILED'}
 if($patched -notmatch 'REVISION_RESET lane='){throw 'SUPERVISOR_V12_REVISION_RESET_PATCH_FAILED'}
 New-Item -ItemType Directory -Force -Path $StartupDir|Out-Null
 foreach($oldStartup in @('3EN-MultiProject-Supervisor-v11.cmd','3EN-MultiProject-Supervisor.cmd')){$op=Join-Path $StartupDir $oldStartup;if(Test-Path $op){Remove-Item $op -Force}}
 $line='@echo off'+[Environment]::NewLine+'start "3EN MultiProject Supervisor v1.2" /min powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$Sup+'"'
 Set-Content -LiteralPath $StartupNew -Value $line -Encoding ASCII
 Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$Sup) -WorkingDirectory $Root|Out-Null
 Start-Sleep -Seconds 5
 if(-not(Get-ProcByScript '3en-multiproject-supervisor-v1.2.ps1')){throw 'SUPERVISOR_V12_PROCESS_NOT_RUNNING'}
 $health=Join-Path $Root '3en-multiproject-supervisor-v12.health.json';if(-not(Test-Path $health)){throw 'SUPERVISOR_V12_HEALTH_MISSING'}
 $h=Get-Content $health -Raw|ConvertFrom-Json;if([string]$h.version -ne '1.2'){throw 'SUPERVISOR_V12_VERSION_INVALID'};if(@($h.lanes).Count -ne 3){throw 'SUPERVISOR_V12_LANES_INVALID'}
 [pscustomobject]@{installedAt=(Get-Date).ToString('o');backup=$bak;startup=$StartupNew;health=$health;version='1.2';handoff='repo-relative';revisionReset=$true}|ConvertTo-Json|Set-Content $Marker -Encoding UTF8
 Write-Host ('MULTIPROJECT_SUPERVISOR_V12_INSTALL=PASS;BACKUP='+$bak+';LANES='+@($h.lanes).Count+';TOKEN='+$h.tokenAvailable+';HANDOFF=REPO_RELATIVE;REVISION_RESET=TRUE')
}
function Test{
 if(-not(Get-ProcByScript '3en-multiproject-supervisor-v1.2.ps1')){throw 'SUPERVISOR_V12_PROCESS_NOT_RUNNING'}
 $health=Join-Path $Root '3en-multiproject-supervisor-v12.health.json';if(-not(Test-Path $health)){throw 'SUPERVISOR_V12_HEALTH_MISSING'};$h=Get-Content $health -Raw|ConvertFrom-Json
 if([string]$h.version -ne '1.2'){throw 'SUPERVISOR_V12_VERSION_INVALID'}
 $names=@($h.lanes|ForEach-Object{$_.lane});foreach($n in @('network-privacy','security-monitor','openclaw')){if($names -notcontains $n){throw ('LANE_MISSING='+$n)}}
 if(-not(Test-Path $StartupNew)){throw 'SUPERVISOR_V12_STARTUP_MISSING'}
 $raw=Get-Content $Sup -Raw;if($raw -notmatch [regex]::Escape("'-ProjectPath',`$project")){throw 'SUPERVISOR_V12_REPO_RELATIVE_HANDOFF_MISSING'}
 if($raw -notmatch 'REVISION_RESET lane='){throw 'SUPERVISOR_V12_REVISION_RESET_MISSING'}
 Write-Host ('MULTIPROJECT_SUPERVISOR_V12_TEST=PASS;STATUS='+$h.status+';LANES='+$names.Count+';TOKEN='+$h.tokenAvailable+';HANDOFF=REPO_RELATIVE;REVISION_RESET=TRUE')
}
function Rollback{
 if(-not(Test-Path $Marker)){Write-Host 'ROLLBACK_NO_MARKER';return};$m=Get-Content $Marker -Raw|ConvertFrom-Json
 Get-ProcByScript '3en-multiproject-supervisor-v1.2.ps1'|ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}
 if(Test-Path $StartupNew){Remove-Item $StartupNew -Force}
 $old=Join-Path $Root '3en-multiproject-supervisor-v1.1.ps1';if(Test-Path $old){Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$old) -WorkingDirectory $Root|Out-Null}
 Write-Host 'MULTIPROJECT_SUPERVISOR_V12_ROLLBACK=PASS'
}
switch($Phase){Install{Install};Test{Test};Rollback{Rollback}}
