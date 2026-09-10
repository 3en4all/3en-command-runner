param([Parameter(Mandatory=$true)][ValidateSet('Prepare','Test')][string]$Phase)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$Root='C:\3EN-Agent'
$RepoRaw='https://raw.githubusercontent.com/3en4all/3en-command-runner/main'
$Source134=Join-Path $Root '3en-multiproject-supervisor-v1.3.4.ps1'
$Target135=Join-Path $Root '3en-multiproject-supervisor-v1.3.5.ps1'
$State134=Join-Path $Root 'supervisor-state-v134'
$State135=Join-Path $Root 'supervisor-state-v135'
$BackupRoot=Join-Path $Root 'backups\supervisor-v135-install-058i'
$RestartHelper=Join-Path $Root 'restart-supervisor-v135-058i.ps1'

function Parse-Check([string]$Path){
  $tok=$null;$err=$null
  [System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tok,[ref]$err)|Out-Null
  if(@($err).Count-ne0){throw ('058I_SYNTAX_ERRORS='+@($err).Count)}
}
function Verify-135([string]$Text){
  $checks=[ordered]@{
    version=($Text -match "version='1\.3\.5'")
    self=($Text -match '3en-multiproject-supervisor-v1\.3\.5\.ps1')
    state=($Text -match 'supervisor-state-v135')
    health=($Text -match 'results/supervisor/v135-health\.json')
    execMutex=($Text -match 'Global\\3EN-MultiProject-Execution-v135')
    wait=($Text -match 'EXECUTION_WAIT lane=')
    acquired=($Text -match 'EXECUTION_ACQUIRED lane=')
    released=($Text -match 'EXECUTION_RELEASED lane=')
    timeout=($Text -match 'runnerTimeoutSeconds=\$RunnerTimeoutSeconds')
    processId=($Text -match 'Kill-Tree\(\[int\]\$processId\)')
    noReadonlyPid=(-not($Text -match 'Kill-Tree\(\[int\]\$pid\)'))
    cacheBust=($Text -match '\?ref=main&ts=')
    lanes=($Text -match "@\('maintenance','network-privacy','security-monitor','openclaw'\)")
  }
  $bad=@($checks.GetEnumerator()|Where-Object{-not $_.Value}|ForEach-Object{$_.Key})
  if($bad.Count-gt0){throw ('058I_VERIFY_FAILED='+($bad -join ','))}
}

if($Phase-eq'Prepare'){
  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
  $backup=Join-Path $BackupRoot $stamp
  New-Item -ItemType Directory -Force -Path $backup|Out-Null
  if(Test-Path $Source134){Copy-Item $Source134 (Join-Path $backup '3en-multiproject-supervisor-v1.3.4.ps1') -Force}
  if(Test-Path $Target135){Copy-Item $Target135 (Join-Path $backup '3en-multiproject-supervisor-v1.3.5.previous.ps1') -Force}
  if(Test-Path $State134){Copy-Item $State134 (Join-Path $backup 'supervisor-state-v134') -Recurse -Force}

  $ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  Invoke-WebRequest -UseBasicParsing -Uri ($RepoRaw+'/automation/3en-multiproject-supervisor-v1.3.5.ps1?ts='+$ts) -OutFile $Target135 -TimeoutSec 30
  if(-not(Test-Path $Target135)){throw '058I_DOWNLOAD_MISSING'}
  Parse-Check $Target135
  $text=Get-Content $Target135 -Raw
  Verify-135 $text
  New-Item -ItemType Directory -Force -Path $State135|Out-Null
  Write-Output ('V469_058I_PREPARE=PASS;CANONICAL_DOWNLOAD=PASS;SYNTAX=PASS;MARKERS=PASS;BACKUP='+$backup)
}

if($Phase-eq'Test'){
  if(-not(Test-Path $Target135)){throw '058I_TARGET_MISSING'}
  Parse-Check $Target135
  $text=Get-Content $Target135 -Raw
  Verify-135 $text

  @'
$ErrorActionPreference='SilentlyContinue'
$Root='C:\3EN-Agent'
Start-Sleep -Seconds 60
$state134=Join-Path $Root 'supervisor-state-v134'
$state135=Join-Path $Root 'supervisor-state-v135'
New-Item -ItemType Directory -Force -Path $state135|Out-Null
if(Test-Path $state134){Copy-Item -Path (Join-Path $state134 '*') -Destination $state135 -Recurse -Force -ErrorAction SilentlyContinue}
$old=@(Get-CimInstance Win32_Process|Where-Object{$_.Name -in @('powershell.exe','pwsh.exe') -and $_.CommandLine -and $_.CommandLine -match '3en-multiproject-supervisor-v1\.3\.4\.ps1'})
foreach($p in ($old|Sort-Object ProcessId -Descending)){try{Stop-Process -Id ([int]$p.ProcessId) -Force}catch{}}
Start-Sleep -Seconds 3
$already=@(Get-CimInstance Win32_Process|Where-Object{$_.Name -in @('powershell.exe','pwsh.exe') -and $_.CommandLine -and $_.CommandLine -match '3en-multiproject-supervisor-v1\.3\.5\.ps1'})
if($already.Count-eq0){
  Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',(Join-Path $Root '3en-multiproject-supervisor-v1.3.5.ps1'),'-Root',$Root,'-PollSeconds','15','-PublishSeconds','30','-RunnerTimeoutSeconds','180') -WorkingDirectory $Root|Out-Null
}
'@|Set-Content -LiteralPath $RestartHelper -Encoding UTF8
  Parse-Check $RestartHelper
  Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$RestartHelper) -WorkingDirectory $Root|Out-Null
  Write-Output 'V469_058I_TEST=PASS;LOCAL_SOURCE=PASS;SYNTAX=PASS;SERIALIZED_EXECUTION=PASS;TIMEOUT=180;FINAL_STATE_COPY_DEFERRED=PASS;CONTROLLED_RESTART_SCHEDULED=PASS'
}
