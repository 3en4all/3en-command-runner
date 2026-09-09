param([ValidateSet('Install','Test','Rollback')][string]$Phase='Install')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent'
$Repo='https://raw.githubusercontent.com/3en4all/3en-command-runner/main'
$Sup131=Join-Path $Root '3en-multiproject-supervisor-v1.3.1.ps1'
$Sup12=Join-Path $Root '3en-multiproject-supervisor-v1.2.ps1'
$BackupRoot=Join-Path $Root 'backups\multiproject-supervisor-v131'
$Marker=Join-Path $Root 'multiproject-supervisor-v131-install.json'
$StartupDir=Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$Startup131=Join-Path $StartupDir '3EN-MultiProject-Supervisor-v131.cmd'
$Startup12=Join-Path $StartupDir '3EN-MultiProject-Supervisor-v12.cmd'
$Health131=Join-Path $Root '3en-multiproject-supervisor-v131.health.json'
$Lanes=@('network-privacy','security-monitor','openclaw')
function Get-ProcByScript([string]$name){$pat=[regex]::Escape($name);$items=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.Name -in @('powershell.exe','pwsh.exe') -and $_.CommandLine -and $_.CommandLine -match $pat});return ,$items}
function Stop-ByScript([string]$name){@(Get-ProcByScript $name)|ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}}
function Wait-For([scriptblock]$Condition,[int]$Seconds,[string]$Error){$end=(Get-Date).AddSeconds($Seconds);do{if(& $Condition){return};Start-Sleep -Milliseconds 500}while((Get-Date)-lt $end);throw $Error}
function Backup-State{$stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$bak=Join-Path $BackupRoot $stamp;New-Item -ItemType Directory -Force -Path $bak|Out-Null;foreach($p in @($Sup12,(Join-Path $Root '3en-multiproject-supervisor-v12.health.json'),(Join-Path $Root '3en-multiproject-supervisor-v12.log'),(Join-Path $Root 'supervisor-state-v12'),$Startup12,$Sup131,(Join-Path $Root 'supervisor-state-v131'),$Startup131)){if(Test-Path $p){Copy-Item $p $bak -Recurse -Force}};return $bak}
function Install{
 if(-not(Test-Path (Join-Path $Root '3en-agent-runner-v4.0.3.ps1'))){throw 'RUNNER_403_MISSING'}
 $bak=Backup-State
 try{
  foreach($n in @('3en-multiproject-supervisor-v1.2.ps1','3en-multiproject-supervisor-v1.3.ps1','3en-multiproject-supervisor-v1.3.1.ps1','3en-agent-runner-v4.0.3.ps1')){Stop-ByScript $n}
  Wait-For { @(Get-ProcByScript '3en-multiproject-supervisor-v1.2.ps1').Count -eq 0 } 10 'SUPERVISOR_V12_STILL_RUNNING'
  $ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();Invoke-WebRequest -UseBasicParsing -Uri ($Repo+'/automation/3en-multiproject-supervisor-v1.3.1.ps1?ts='+$ts) -OutFile $Sup131 -TimeoutSec 30
  $tok=$null;$err=$null;[System.Management.Automation.Language.Parser]::ParseFile($Sup131,[ref]$tok,[ref]$err)|Out-Null;if(@($err).Count -gt 0){throw ('SUPERVISOR_V131_SYNTAX_ERRORS='+@($err).Count)}
  New-Item -ItemType Directory -Force -Path $StartupDir|Out-Null
  foreach($f in @($Startup12,(Join-Path $StartupDir '3EN-MultiProject-Supervisor-v13.cmd'))){if(Test-Path $f){Remove-Item $f -Force}}
  $line='@echo off'+[Environment]::NewLine+'start "3EN MultiProject Supervisor v1.3.1" /min powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$Sup131+'"'
  Set-Content -LiteralPath $Startup131 -Value $line -Encoding ASCII
  Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$Sup131) -WorkingDirectory $Root|Out-Null
  Wait-For { @(Get-ProcByScript '3en-multiproject-supervisor-v1.3.1.ps1').Count -ge 4 } 20 'SUPERVISOR_V131_WORKERS_NOT_STARTED'
  Wait-For { Test-Path $Health131 } 15 'SUPERVISOR_V131_HEALTH_MISSING'
  Start-Sleep -Seconds 3
  $h=Get-Content $Health131 -Raw|ConvertFrom-Json
  if([string]$h.version -ne '1.3.1'){throw 'SUPERVISOR_V131_VERSION_INVALID'}
  if([string]$h.architecture -ne 'independent-lane-workers'){throw 'SUPERVISOR_V131_ARCH_INVALID'}
  $rows=@($h.lanes);if($rows.Count -ne 3){throw 'SUPERVISOR_V131_LANES_INVALID'}
  foreach($lane in $Lanes){$r=@($rows|Where-Object{$_.lane -eq $lane});if($r.Count -ne 1 -or -not [bool]$r[0].workerRunning){throw ('SUPERVISOR_V131_WORKER_NOT_RUNNING_'+$lane)}}
  $open=@($rows|Where-Object{$_.lane -eq 'openclaw'})[0]
  [pscustomobject]@{installedAt=(Get-Date).ToString('o');backup=$bak;startup=$Startup131;health=$Health131;version='1.3.1';architecture='independent-lane-workers'}|ConvertTo-Json -Depth 5|Set-Content $Marker -Encoding UTF8
  Write-Host ('MULTIPROJECT_SUPERVISOR_V131_INSTALL=PASS;BACKUP='+$bak+';WORKERS=3;OPENCLAW_STATUS='+[string]$open.status+';OPENCLAW_PROJECT='+[string]$open.pointerProject)
 }catch{Write-Host ('MULTIPROJECT_SUPERVISOR_V131_INSTALL=FAIL;ERROR='+$_.Exception.Message);try{Rollback}catch{Write-Host ('AUTO_ROLLBACK_ERROR='+$_.Exception.Message)};throw}
}
function Test{
 if(-not(Test-Path $Health131)){throw 'SUPERVISOR_V131_HEALTH_MISSING'}
 $h=Get-Content $Health131 -Raw|ConvertFrom-Json
 if([string]$h.version -ne '1.3.1' -or [string]$h.architecture -ne 'independent-lane-workers'){throw 'SUPERVISOR_V131_HEALTH_INVALID'}
 $rows=@($h.lanes);foreach($lane in $Lanes){$r=@($rows|Where-Object{$_.lane -eq $lane});if($r.Count -ne 1){throw ('LANE_MISSING_'+$lane)};if(-not [bool]$r[0].workerRunning){throw ('WORKER_DOWN_'+$lane)}}
 $open=@($rows|Where-Object{$_.lane -eq 'openclaw'})[0]
 if([string]$open.pointerProject -ne 'project-v444b.json'){throw ('OPENCLAW_POINTER_NOT_V444B actual='+[string]$open.pointerProject)}
 Write-Host ('MULTIPROJECT_SUPERVISOR_V131_TEST=PASS;ARCH=INDEPENDENT_LANE_WORKERS;WORKERS=3;OPENCLAW_PROJECT='+[string]$open.pointerProject+';OPENCLAW_STATUS='+[string]$open.status+';OPENCLAW_RUNNER_PID='+[string]$open.runnerPid)
}
function Rollback{
 foreach($n in @('3en-multiproject-supervisor-v1.3.1.ps1','3en-agent-runner-v4.0.3.ps1')){Stop-ByScript $n}
 if(Test-Path $Startup131){Remove-Item $Startup131 -Force}
 if(Test-Path $Sup12){$line='@echo off'+[Environment]::NewLine+'start "3EN MultiProject Supervisor v1.2" /min powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$Sup12+'"';Set-Content -LiteralPath $Startup12 -Value $line -Encoding ASCII;Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$Sup12) -WorkingDirectory $Root|Out-Null;Wait-For { @(Get-ProcByScript '3en-multiproject-supervisor-v1.2.ps1').Count -ge 1 } 15 'SUPERVISOR_V12_ROLLBACK_START_FAILED'}
 Write-Host 'MULTIPROJECT_SUPERVISOR_V131_ROLLBACK=PASS'
}
switch($Phase){Install{Install};Test{Test};Rollback{Rollback}}
