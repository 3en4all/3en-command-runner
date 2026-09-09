param([ValidateSet('Install','Test','Rollback')][string]$Phase)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent'
$Repo='https://raw.githubusercontent.com/3en4all/3en-command-runner/main'
$Sup=Join-Path $Root '3en-multiproject-supervisor-v1.ps1'
$Old=Join-Path $Root '3en-project-inbox.ps1'
$BackupRoot=Join-Path $Root 'backups\multiproject-supervisor'
$Marker=Join-Path $Root 'multiproject-supervisor-install.json'
$StartupDir=Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$StartupNew=Join-Path $StartupDir '3EN-MultiProject-Supervisor.cmd'
$StartupOld=Join-Path $StartupDir '3EN-Project-Inbox.cmd'
function Get-SupProc{Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine -and $_.CommandLine -match '3en-multiproject-supervisor-v1\.ps1'}}
function Install{
  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$bak=Join-Path $BackupRoot $stamp;New-Item -ItemType Directory -Force -Path $bak|Out-Null
  foreach($p in @($Old,(Join-Path $Root '3en-project-inbox.state.json'),(Join-Path $Root '3en-project-inbox.log'),$StartupOld)){if(Test-Path $p){Copy-Item $p $bak -Force}}
  Invoke-WebRequest -UseBasicParsing -Uri ($Repo+'/automation/3en-multiproject-supervisor-v1.ps1?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -OutFile $Sup
  $tok=$null;$err=$null;[System.Management.Automation.Language.Parser]::ParseFile($Sup,[ref]$tok,[ref]$err)|Out-Null;if(@($err).Count -gt 0){throw ('SUPERVISOR_SYNTAX_ERRORS='+@($err).Count)}
  New-Item -ItemType Directory -Force -Path $StartupDir|Out-Null
  $line='@echo off'+[Environment]::NewLine+'start "3EN MultiProject Supervisor" /min powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$Sup+'"'
  Set-Content -LiteralPath $StartupNew -Value $line -Encoding ASCII
  Get-SupProc|ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}
  Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$Sup) -WorkingDirectory $Root|Out-Null
  Start-Sleep -Seconds 5
  if(-not(Get-SupProc)){throw 'SUPERVISOR_PROCESS_NOT_RUNNING'}
  $health=Join-Path $Root '3en-multiproject-supervisor.health.json';if(-not(Test-Path $health)){throw 'SUPERVISOR_HEALTH_MISSING'}
  $h=Get-Content $health -Raw|ConvertFrom-Json;if(@($h.lanes).Count -ne 3){throw 'SUPERVISOR_LANE_COUNT_INVALID'}
  if(Test-Path $StartupOld){Remove-Item $StartupOld -Force}
  [pscustomobject]@{installedAt=(Get-Date).ToString('o');backup=$bak;startup=$StartupNew;health=$health}|ConvertTo-Json|Set-Content $Marker -Encoding UTF8
  Write-Host ('MULTIPROJECT_SUPERVISOR_INSTALL=PASS;BACKUP='+$bak+';LANES='+@($h.lanes).Count)
}
function Test{
  if(-not(Get-SupProc)){throw 'SUPERVISOR_PROCESS_NOT_RUNNING'}
  $health=Join-Path $Root '3en-multiproject-supervisor.health.json';$h=Get-Content $health -Raw|ConvertFrom-Json
  $names=@($h.lanes|ForEach-Object{$_.lane});foreach($n in @('network-privacy','security-monitor','openclaw')){if($names -notcontains $n){throw ('LANE_MISSING='+$n)}}
  if(Test-Path $StartupOld){throw 'LEGACY_STARTUP_STILL_PRESENT'}
  if(-not(Test-Path $StartupNew)){throw 'SUPERVISOR_STARTUP_MISSING'}
  Write-Host ('MULTIPROJECT_SUPERVISOR_TEST=PASS;STATUS='+$h.status+';LANES='+$names.Count)
}
function Rollback{
  if(-not(Test-Path $Marker)){Write-Host 'ROLLBACK_NO_MARKER';return};$m=Get-Content $Marker -Raw|ConvertFrom-Json
  Get-SupProc|ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}
  if(Test-Path (Join-Path $m.backup '3EN-Project-Inbox.cmd')){Copy-Item (Join-Path $m.backup '3EN-Project-Inbox.cmd') $StartupOld -Force}
  if(Test-Path $StartupNew){Remove-Item $StartupNew -Force}
  if(Test-Path $StartupOld){Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$Old) -WorkingDirectory $Root|Out-Null}
  Write-Host 'MULTIPROJECT_SUPERVISOR_ROLLBACK=PASS'
}
switch($Phase){Install{Install};Test{Test};Rollback{Rollback}}
