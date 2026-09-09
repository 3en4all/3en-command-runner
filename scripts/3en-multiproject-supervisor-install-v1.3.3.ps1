param([ValidateSet('Install','Test','Rollback')][string]$Phase='Install')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent'
$Repo='https://raw.githubusercontent.com/3en4all/3en-command-runner/main'
$Sup133=Join-Path $Root '3en-multiproject-supervisor-v1.3.3.ps1'
$Sup132=Join-Path $Root '3en-multiproject-supervisor-v1.3.2.ps1'
$BackupRoot=Join-Path $Root 'backups\multiproject-supervisor-v133'
$Marker=Join-Path $Root 'multiproject-supervisor-v133-install.json'
$StartupDir=Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$Startup133=Join-Path $StartupDir '3EN-MultiProject-Supervisor-v133.cmd'
$Startup132=Join-Path $StartupDir '3EN-MultiProject-Supervisor-v132.cmd'
$Health133=Join-Path $Root '3en-multiproject-supervisor-v133.health.json'
$Lanes=@('network-privacy','security-monitor','openclaw')
function Find-Script([string]$name){$pat=[regex]::Escape($name);Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.Name -in @('powershell.exe','pwsh.exe') -and $_.CommandLine -and $_.CommandLine -match $pat}}
function Stop-Script([string]$name){foreach($p in @(Find-Script $name)){if($p.PSObject.Properties.Name -contains 'ProcessId'){Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue}}}
function Wait-For([scriptblock]$Condition,[int]$Seconds,[string]$ErrorText){$end=(Get-Date).AddSeconds($Seconds);do{if(& $Condition){return};Start-Sleep -Milliseconds 500}while((Get-Date)-lt $end);throw $ErrorText}
function Backup-State{$stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$bak=Join-Path $BackupRoot $stamp;New-Item -ItemType Directory -Force -Path $bak|Out-Null;foreach($p in @($Sup132,(Join-Path $Root '3en-multiproject-supervisor-v132.health.json'),(Join-Path $Root 'supervisor-state-v132'),$Startup132,$Sup133,(Join-Path $Root 'supervisor-state-v133'),$Startup133)){if(Test-Path $p){Copy-Item $p $bak -Recurse -Force}};return $bak}
function Install{
 $bak=Backup-State
 try{
  if(-not(Test-Path (Join-Path $Root '3en-agent-runner-v4.0.3.ps1'))){throw 'RUNNER_403_MISSING'}
  Stop-Script '3en-multiproject-supervisor-v1.3.2.ps1';Stop-Script '3en-multiproject-supervisor-v1.3.3.ps1';Stop-Script '3en-agent-runner-v4.0.3.ps1'
  Wait-For { @(Find-Script '3en-multiproject-supervisor-v1.3.2.ps1').Count -eq 0 } 10 'SUPERVISOR_V132_STILL_RUNNING'
  $ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();Invoke-WebRequest -UseBasicParsing -Uri ($Repo+'/automation/3en-multiproject-supervisor-v1.3.3.ps1?ts='+$ts) -OutFile $Sup133 -TimeoutSec 30
  $tok=$null;$err=$null;[System.Management.Automation.Language.Parser]::ParseFile($Sup133,[ref]$tok,[ref]$err)|Out-Null;if(@($err).Count -gt 0){throw ('SUPERVISOR_V133_SYNTAX_ERRORS='+@($err).Count)}
  New-Item -ItemType Directory -Force -Path $StartupDir|Out-Null;if(Test-Path $Startup132){Remove-Item $Startup132 -Force}
  $line='@echo off'+[Environment]::NewLine+'start "3EN MultiProject Supervisor v1.3.3" /min powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$Sup133+'"';Set-Content -LiteralPath $Startup133 -Value $line -Encoding ASCII
  Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$Sup133) -WorkingDirectory $Root|Out-Null
  Wait-For { @(Find-Script '3en-multiproject-supervisor-v1.3.3.ps1').Count -ge 4 } 20 'SUPERVISOR_V133_WORKERS_NOT_STARTED'
  Wait-For { Test-Path $Health133 } 15 'SUPERVISOR_V133_HEALTH_MISSING';Start-Sleep -Seconds 3
  $h=Get-Content $Health133 -Raw|ConvertFrom-Json;if([string]$h.version -ne '1.3.3'){throw 'SUPERVISOR_V133_VERSION_INVALID'};if([string]$h.pointerTransport -ne 'github-contents-api'){throw 'SUPERVISOR_V133_POINTER_TRANSPORT_INVALID'};if([string]$h.runnerTransport -ne 'synchronous-last-exit-code'){throw 'SUPERVISOR_V133_RUNNER_TRANSPORT_INVALID'}
  $rows=@($h.lanes);if($rows.Count -ne 3){throw 'SUPERVISOR_V133_LANES_INVALID'};foreach($lane in $Lanes){$r=@($rows|Where-Object{$_.lane -eq $lane});if($r.Count -ne 1 -or -not [bool]$r[0].workerRunning){throw ('SUPERVISOR_V133_WORKER_NOT_RUNNING_'+$lane)}}
  [pscustomobject]@{installedAt=(Get-Date).ToString('o');backup=$bak;version='1.3.3';pointerTransport='github-contents-api';runnerTransport='synchronous-last-exit-code'}|ConvertTo-Json|Set-Content $Marker -Encoding UTF8
  $open=@($rows|Where-Object{$_.lane -eq 'openclaw'})[0];Write-Host ('MULTIPROJECT_SUPERVISOR_V133_INSTALL=PASS;BACKUP='+$bak+';WORKERS=3;OPENCLAW_PROJECT='+[string]$open.pointerProject+';OPENCLAW_STATUS='+[string]$open.status)
 }catch{Write-Host ('MULTIPROJECT_SUPERVISOR_V133_INSTALL=FAIL;ERROR='+$_.Exception.Message);try{Rollback}catch{Write-Host ('AUTO_ROLLBACK_ERROR='+$_.Exception.Message)};throw}
}
function Test{
 if(-not(Test-Path $Health133)){throw 'SUPERVISOR_V133_HEALTH_MISSING'};$h=Get-Content $Health133 -Raw|ConvertFrom-Json
 if([string]$h.version -ne '1.3.3'){throw 'SUPERVISOR_V133_VERSION_INVALID'};if([string]$h.pointerTransport -ne 'github-contents-api'){throw 'POINTER_TRANSPORT_INVALID'};if([string]$h.runnerTransport -ne 'synchronous-last-exit-code'){throw 'RUNNER_TRANSPORT_INVALID'}
 $rows=@($h.lanes);foreach($lane in $Lanes){$r=@($rows|Where-Object{$_.lane -eq $lane});if($r.Count -ne 1 -or -not [bool]$r[0].workerRunning){throw ('WORKER_DOWN_'+$lane)}};$open=@($rows|Where-Object{$_.lane -eq 'openclaw'})[0]
 if([string]$open.pointerProject -ne 'project-v444c.json'){throw ('OPENCLAW_POINTER_NOT_V444C actual='+[string]$open.pointerProject)}
 Write-Host ('MULTIPROJECT_SUPERVISOR_V133_TEST=PASS;WORKERS=3;POINTER=GITHUB_CONTENTS_API;RUNNER=LASTEXITCODE;OPENCLAW_PROJECT='+[string]$open.pointerProject+';OPENCLAW_STATUS='+[string]$open.status)
}
function Rollback{Stop-Script '3en-multiproject-supervisor-v1.3.3.ps1';Stop-Script '3en-agent-runner-v4.0.3.ps1';if(Test-Path $Startup133){Remove-Item $Startup133 -Force};if(Test-Path $Sup132){$line='@echo off'+[Environment]::NewLine+'start "3EN MultiProject Supervisor v1.3.2" /min powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$Sup132+'"';Set-Content -LiteralPath $Startup132 -Value $line -Encoding ASCII;Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$Sup132) -WorkingDirectory $Root|Out-Null;Wait-For { @(Find-Script '3en-multiproject-supervisor-v1.3.2.ps1').Count -ge 1 } 15 'SUPERVISOR_V132_ROLLBACK_START_FAILED'};Write-Host 'MULTIPROJECT_SUPERVISOR_V133_ROLLBACK=PASS'}
switch($Phase){Install{Install};Test{Test};Rollback{Rollback}}
