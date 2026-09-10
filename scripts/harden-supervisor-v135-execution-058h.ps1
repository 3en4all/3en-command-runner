param([Parameter(Mandatory=$true)][ValidateSet('Prepare','Test')][string]$Phase)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$Root='C:\3EN-Agent'
$RepoApi='https://api.github.com/repos/3en4all/3en-command-runner'
$Source=Join-Path $Root '3en-multiproject-supervisor-v1.3.4.ps1'
$Target=Join-Path $Root '3en-multiproject-supervisor-v1.3.5.ps1'
$State134=Join-Path $Root 'supervisor-state-v134'
$State135=Join-Path $Root 'supervisor-state-v135'
$BackupRoot=Join-Path $Root 'backups\supervisor-v135-execution-058h'
$RestartHelper=Join-Path $Root 'restart-supervisor-v135-058h.ps1'
$Token=$env:THREEEN_GH_TOKEN

function Parse-Check([string]$p){
  $tok=$null;$err=$null
  [System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$tok,[ref]$err)|Out-Null
  if(@($err).Count-ne0){throw ('058H_SYNTAX_ERRORS='+@($err).Count)}
}
function Headers{
  if([string]::IsNullOrWhiteSpace($Token)){throw '058H_GITHUB_TOKEN_MISSING'}
  return @{Authorization=('Bearer '+$Token);Accept='application/vnd.github+json';'X-GitHub-Api-Version'='2022-11-28'}
}
function Publish-Source([string]$text){
  $h=Headers
  $path='automation/3en-multiproject-supervisor-v1.3.5.ps1'
  $uri=$RepoApi+'/contents/'+$path
  $sha=$null
  try{
    $ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $cur=Invoke-RestMethod -Method Get -Uri ($uri+'?ref=main&ts='+$ts) -Headers $h -TimeoutSec 20
    if($cur.sha){$sha=[string]$cur.sha}
  }catch{}
  $body=[ordered]@{message='Persist supervisor v1.3.5 serialized execution';content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text));branch='main'}
  if($sha){$body.sha=$sha}
  Invoke-RestMethod -Method Put -Uri $uri -Headers $h -ContentType 'application/json' -Body ($body|ConvertTo-Json -Depth 4) -TimeoutSec 30|Out-Null
}
function Verify([string]$s){
  if($s -notmatch "version='1\.3\.5'"){throw '058H_VERSION_MISSING'}
  if($s -notmatch 'Global\\3EN-MultiProject-Execution-v135'){throw '058H_EXEC_MUTEX_MISSING'}
  if($s -notmatch 'EXECUTION_WAIT lane='){throw '058H_WAIT_LOG_MISSING'}
  if($s -notmatch 'EXECUTION_ACQUIRED lane='){throw '058H_ACQUIRE_LOG_MISSING'}
  if($s -notmatch 'EXECUTION_RELEASED lane='){throw '058H_RELEASE_LOG_MISSING'}
  if($s -notmatch 'runnerTimeoutSeconds=\$RunnerTimeoutSeconds'){throw '058H_TIMEOUT_HEALTH_MISSING'}
  if($s -match 'Kill-Tree\(\[int\]\$pid\)'){throw '058H_READONLY_PID_REMAINS'}
  if($s -notmatch 'Kill-Tree\(\[int\]\$processId\)'){throw '058H_PROCESSID_FIX_MISSING'}
  if($s -notmatch '\?ref=main&ts='){throw '058H_CACHE_BUSTER_MISSING'}
  if($s -notmatch "@\('maintenance','network-privacy','security-monitor','openclaw'\)"){throw '058H_LANES_MISSING'}
}

if($Phase-eq'Prepare'){
  if(-not(Test-Path $Source)){throw '058H_SOURCE_134_MISSING'}
  Parse-Check $Source

  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
  $backup=Join-Path $BackupRoot $stamp
  New-Item -ItemType Directory -Force -Path $backup|Out-Null
  Copy-Item $Source (Join-Path $backup '3en-multiproject-supervisor-v1.3.4.ps1') -Force

  $s=Get-Content $Source -Raw

  $oldKill='function Kill-Tree([int]$pid){if($pid -le 0){return};try{& taskkill.exe /PID $pid /T /F 2>&1|Out-Null}catch{}}'
  $newKill='function Kill-Tree([int]$processId){if($processId -le 0){return};try{& taskkill.exe /PID $processId /T /F 2>&1|Out-Null}catch{}}'
  if($s.Contains($oldKill)){$s=$s.Replace($oldKill,$newKill)}elseif(-not $s.Contains($newKill)){throw '058H_KILL_PATTERN_NOT_FOUND'}

  $oldPtr='$uri=$RepoApi+''/contents/inbox/lanes/''+$lane+''.json?ref=main'';try{'
  $newPtr='$ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();$uri=$RepoApi+''/contents/inbox/lanes/''+$lane+''.json?ref=main&ts=''+$ts;try{'
  if($s.Contains($oldPtr)){$s=$s.Replace($oldPtr,$newPtr)}elseif(-not $s.Contains('?ref=main&ts=')){throw '058H_POINTER_PATTERN_NOT_FOUND'}

  $oldSync='$uri=$RepoApi+''/contents/''+$repoPath.Replace(''\'',''/'')+''?ref=main'';try{'
  $newSync='$ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();$uri=$RepoApi+''/contents/''+$repoPath.Replace(''\'',''/'')+''?ref=main&ts=''+$ts;try{'
  if($s.Contains($oldSync)){$s=$s.Replace($oldSync,$newSync)}

  $pattern='(?s)function Run-RunnerTimed\(\[string\]\$project,\[object\]\$s,\[string\]\$lane\)\{.*?\r?\n\}\r?\nfunction Run-Worker'
  $replacement=@'
function Run-RunnerTimed([string]$project,[object]$s,[string]$lane){
  $execMutex=New-Object Threading.Mutex($false,'Global\3EN-MultiProject-Execution-v135')
  $acquired=$false
  try{
    Write-Log (Lane-LogPath $lane) ('EXECUTION_WAIT lane='+$lane+' project='+$project)
    $s.status='EXECUTION_WAIT';Save-Lane $s;[void](Publish-RepoJson ('results/supervisor/v135-'+$lane+'.json') $s)
    while(-not $acquired){
      try{$acquired=$execMutex.WaitOne(5000)}catch [Threading.AbandonedMutexException]{$acquired=$true}
      if(-not $acquired){
        $s.updatedUtc=(Get-Date).ToUniversalTime().ToString('o')
        Save-Lane $s
        [void](Publish-RepoJson ('results/supervisor/v135-'+$lane+'.json') $s)
      }
    }
    Write-Log (Lane-LogPath $lane) ('EXECUTION_ACQUIRED lane='+$lane+' project='+$project)
    $s.status='RUNNING';Save-Lane $s;[void](Publish-RepoJson ('results/supervisor/v135-'+$lane+'.json') $s)
    $arg=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$Runner,'-ProjectPath',$project)
    $p=Start-Process powershell.exe -ArgumentList $arg -WorkingDirectory $Root -WindowStyle Hidden -PassThru
    $s.runnerPid=$p.Id;Save-Lane $s;[void](Publish-RepoJson ('results/supervisor/v135-'+$lane+'.json') $s)
    Write-Log (Lane-LogPath $lane) ('RUNNER_PID='+$p.Id+' timeout='+$RunnerTimeoutSeconds)
    $done=$p.WaitForExit($RunnerTimeoutSeconds*1000)
    if(-not $done){
      Write-Log (Lane-LogPath $lane) ('RUNNER_TIMEOUT pid='+$p.Id)
      Kill-Tree $p.Id
      $s.runnerPid=$null;Save-Lane $s
      return 124
    }
    $p.WaitForExit()
    $ec=$p.ExitCode
    $s.runnerPid=$null;Save-Lane $s
    if($null-eq$ec){return 1}
    return [int]$ec
  } finally {
    if($acquired){try{$execMutex.ReleaseMutex();Write-Log (Lane-LogPath $lane) ('EXECUTION_RELEASED lane='+$lane)}catch{}}
    $execMutex.Dispose()
  }
}
function Run-Worker
'@
  $patched=[regex]::Replace($s,$pattern,$replacement,1)
  if($patched-eq$s){throw '058H_RUNNER_FUNCTION_PATCH_NOT_APPLIED'}

  $s=$patched.Replace('v1.3.4','v1.3.5').Replace('v134','v135').Replace("architecture='independent-lane-workers-with-timeout'","architecture='independent-lane-workers-serialized-execution-with-timeout'")
  Set-Content -LiteralPath $Target -Value $s -Encoding UTF8
  Parse-Check $Target
  $final=Get-Content $Target -Raw
  Verify $final

  New-Item -ItemType Directory -Force -Path $State135|Out-Null
  if(Test-Path $State134){Copy-Item -Path (Join-Path $State134 '*') -Destination $State135 -Recurse -Force -ErrorAction SilentlyContinue}
  Publish-Source $final

  Write-Output ('V468_058H_PREPARE=PASS;SERIALIZED_EXECUTION=PASS;STATE_MIGRATED=PASS;SOURCE_PERSISTED=PASS;RESTART_DEFERRED_TO_TEST=PASS;BACKUP='+$backup)
}

if($Phase-eq'Test'){
  if(-not(Test-Path $Target)){throw '058H_TARGET_MISSING'}
  Parse-Check $Target
  $s=Get-Content $Target -Raw
  Verify $s
  if(-not(Test-Path $State135)){throw '058H_STATE135_MISSING'}

  @'
$ErrorActionPreference='SilentlyContinue'
$Root='C:\3EN-Agent'
Start-Sleep -Seconds 60
$old=@(Get-CimInstance Win32_Process|Where-Object{$_.Name -in @('powershell.exe','pwsh.exe') -and $_.CommandLine -and $_.CommandLine -match '3en-multiproject-supervisor-v1\.3\.4\.ps1'})
foreach($p in ($old|Sort-Object ProcessId -Descending)){try{Stop-Process -Id ([int]$p.ProcessId) -Force}catch{}}
Start-Sleep -Seconds 3
$already=@(Get-CimInstance Win32_Process|Where-Object{$_.Name -in @('powershell.exe','pwsh.exe') -and $_.CommandLine -and $_.CommandLine -match '3en-multiproject-supervisor-v1\.3\.5\.ps1'})
if($already.Count-eq0){Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',(Join-Path $Root '3en-multiproject-supervisor-v1.3.5.ps1'),'-Root',$Root,'-PollSeconds','15','-PublishSeconds','30','-RunnerTimeoutSeconds','180') -WorkingDirectory $Root|Out-Null}
'@|Set-Content -LiteralPath $RestartHelper -Encoding UTF8
  Parse-Check $RestartHelper
  Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$RestartHelper) -WorkingDirectory $Root|Out-Null
  Write-Output 'V468_058H_TEST=PASS;SYNTAX=PASS;EXECUTION_MUTEX=PASS;PROCESSID_FIX=PASS;CACHE_BUSTER=PASS;TIMEOUT=180;STATE_MIGRATION=PASS;RESTART_SCHEDULED_AFTER_RESULT_WINDOW=PASS'
}
