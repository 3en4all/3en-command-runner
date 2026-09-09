param(
  [string]$Root='C:\3EN-Agent',
  [int]$PollSeconds=15,
  [int]$PublishSeconds=60,
  [string]$WorkerLane=''
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$RepoRaw='https://raw.githubusercontent.com/3en4all/3en-command-runner/main'
$RepoApi='https://api.github.com/repos/3en4all/3en-command-runner'
$Runner=Join-Path $Root '3en-agent-runner-v4.0.3.ps1'
$Self=Join-Path $Root '3en-multiproject-supervisor-v1.3.ps1'
$StateDir=Join-Path $Root 'supervisor-state-v13'
$HealthFile=Join-Path $Root '3en-multiproject-supervisor-v13.health.json'
$CoordLog=Join-Path $Root '3en-multiproject-supervisor-v13.log'
$Lanes=@('network-privacy','security-monitor','openclaw')
$Token=$env:THREEEN_GH_TOKEN
New-Item -ItemType Directory -Force -Path $StateDir|Out-Null

function Write-Log([string]$path,[string]$m){$line='['+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+'] '+$m;Add-Content -LiteralPath $path -Value $line -Encoding UTF8}
function Lane-StatePath([string]$lane){Join-Path $StateDir ($lane+'.json')}
function Lane-HealthPath([string]$lane){Join-Path $StateDir ($lane+'.health.json')}
function Lane-LogPath([string]$lane){Join-Path $Root ('3en-multiproject-supervisor-v13-'+$lane+'.log')}
function Default-Lane([string]$lane){[pscustomobject][ordered]@{schemaVersion=2;lane=$lane;pointerRevision='';pointerProject='';processedRevision='';status='NEW';attempts=0;lastError='';nextRetryUtc='';lastStartedUtc='';lastTerminalUtc='';lastExitCode=$null;workerPid=$PID;runnerPid=$null;updatedUtc=(Get-Date).ToUniversalTime().ToString('o')}}
function Load-Lane([string]$lane){$f=Lane-StatePath $lane;if(Test-Path $f){try{return Get-Content $f -Raw|ConvertFrom-Json}catch{}};return Default-Lane $lane}
function Save-Lane($s){$s.workerPid=$PID;$s.updatedUtc=(Get-Date).ToUniversalTime().ToString('o');$s|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Lane-StatePath ([string]$s.lane)) -Encoding UTF8;$s|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Lane-HealthPath ([string]$s.lane)) -Encoding UTF8}
function Get-Pointer([string]$lane){$ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();Invoke-RestMethod -UseBasicParsing -Uri ($RepoRaw+'/inbox/lanes/'+$lane+'.json?ts='+$ts) -TimeoutSec 20}
function Sync-File([string]$repoPath){if([string]::IsNullOrWhiteSpace($repoPath)){throw 'SYNC_PATH_EMPTY'};$local=Join-Path $Root ($repoPath -replace '/','\');$dir=Split-Path -Parent $local;if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null};$ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();Invoke-WebRequest -UseBasicParsing -Uri ($RepoRaw+'/'+$repoPath.Replace('\','/')+'?ts='+$ts) -OutFile $local -TimeoutSec 30;if(-not(Test-Path $local)){throw ('SYNC_FILE_MISSING '+$repoPath)};return $local}
function Sync-Project([string]$projectPath){$projectLocal=Sync-File $projectPath;$project=Get-Content -LiteralPath $projectLocal -Raw|ConvertFrom-Json;foreach($chapter in @($project.chapters)){if($null -ne $chapter -and $chapter.path){[void](Sync-File ([string]$chapter.path))}};return $projectLocal}
function Retry-Delay([int]$attempts){$sec=[Math]::Min(300,[Math]::Max(15,[Math]::Pow(2,[Math]::Min($attempts,8))*15));return [int]$sec}
function Can-Retry($s){if([string]::IsNullOrWhiteSpace([string]$s.nextRetryUtc)){return $true};try{return ((Get-Date).ToUniversalTime() -ge [datetime]::Parse([string]$s.nextRetryUtc).ToUniversalTime())}catch{return $true}}
function Publish-RepoJson([string]$repoPath,[object]$obj){if([string]::IsNullOrWhiteSpace($Token)){return $false};try{$headers=@{Authorization=('Bearer '+$Token);Accept='application/vnd.github+json';'X-GitHub-Api-Version'='2022-11-28'};$uri=$RepoApi+'/contents/'+$repoPath;$sha=$null;try{$cur=Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -TimeoutSec 20;if($cur.sha){$sha=[string]$cur.sha}}catch{};$json=$obj|ConvertTo-Json -Depth 12;$b64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json));$body=[ordered]@{message=('Supervisor v1.3 evidence '+$repoPath);content=$b64;branch='main'};if($sha){$body.sha=$sha};Invoke-RestMethod -Method Put -Uri $uri -Headers $headers -ContentType 'application/json' -Body ($body|ConvertTo-Json -Depth 4) -TimeoutSec 30|Out-Null;return $true}catch{return $false}}
function Get-ProcByLane([string]$lane){$selfPat=[regex]::Escape('3en-multiproject-supervisor-v1.3.ps1');$lanePat=[regex]::Escape('-WorkerLane '+$lane);@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.Name -in @('powershell.exe','pwsh.exe') -and $_.CommandLine -and $_.CommandLine -match $selfPat -and $_.CommandLine -match $lanePat})}

function Run-Worker([string]$lane){
  if($Lanes -notcontains $lane){throw ('INVALID_WORKER_LANE '+$lane)}
  if(-not(Test-Path $Runner)){throw 'RUNNER_403_MISSING'}
  $log=Lane-LogPath $lane
  $mutex=New-Object Threading.Mutex($false,('Global\3EN-MultiProject-Supervisor-v13-'+$lane))
  if(-not $mutex.WaitOne(0)){exit 0}
  try{
    Write-Log $log ('WORKER_START lane='+$lane+' pid='+$PID)
    while($true){
      $s=Load-Lane $lane
      try{
        $ptr=Get-Pointer $lane;$rev=[string]$ptr.revision;$project=[string]$ptr.projectPath;$enabled=[bool]$ptr.enabled
        $previous=[string]$s.pointerRevision
        if($previous -ne $rev){$s.attempts=0;$s.lastError='';$s.nextRetryUtc='';$s.lastExitCode=$null;$s.status='NEW';$s.runnerPid=$null;Write-Log $log ('REVISION_RESET lane='+$lane+' old='+$previous+' new='+$rev)}
        $s.pointerRevision=$rev;$s.pointerProject=$project
        if(-not $enabled -or [string]::IsNullOrWhiteSpace($rev) -or [string]::IsNullOrWhiteSpace($project)){$s.status='IDLE';Save-Lane $s;Start-Sleep -Seconds $PollSeconds;continue}
        if([string]$s.processedRevision -eq $rev -and [string]$s.status -eq 'TERMINAL'){Save-Lane $s;Start-Sleep -Seconds $PollSeconds;continue}
        if(-not(Can-Retry $s)){Save-Lane $s;Start-Sleep -Seconds $PollSeconds;continue}
        $s.attempts=[int]$s.attempts+1;$s.lastStartedUtc=(Get-Date).ToUniversalTime().ToString('o');$s.lastError='';$s.status='SYNCING';Save-Lane $s;[void](Publish-RepoJson ('results/supervisor/v13-'+$lane+'.json') $s)
        Write-Log $log ('CLAIM revision='+$rev+' project='+$project+' attempt='+$s.attempts)
        [void](Sync-Project $project)
        $s.status='RUNNING';Save-Lane $s
        $p=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Runner,'-ProjectPath',$project) -WorkingDirectory $Root -PassThru -NoNewWindow
        $s.runnerPid=$p.Id;Save-Lane $s;[void](Publish-RepoJson ('results/supervisor/v13-'+$lane+'.json') $s)
        Write-Log $log ('RUNNER_START pid='+$p.Id+' project='+$project)
        $p.WaitForExit();$s.runnerPid=$null;$s.lastExitCode=$p.ExitCode;$s.lastTerminalUtc=(Get-Date).ToUniversalTime().ToString('o')
        if($p.ExitCode -eq 0){$s.status='TERMINAL';$s.processedRevision=$rev;$s.nextRetryUtc='';$s.lastError='';Write-Log $log ('TERMINAL revision='+$rev+' exit=0')}
        else{$delay=Retry-Delay ([int]$s.attempts);$s.status='RETRY_PENDING';$s.lastError=('RUNNER_EXIT_'+$p.ExitCode);$s.nextRetryUtc=(Get-Date).ToUniversalTime().AddSeconds($delay).ToString('o');Write-Log $log ('RETRY reason='+$s.lastError+' delay='+$delay)}
        Save-Lane $s;[void](Publish-RepoJson ('results/supervisor/v13-'+$lane+'.json') $s)
      }catch{$delay=Retry-Delay ([int]$s.attempts);$s.runnerPid=$null;$s.status='RETRY_PENDING';$s.lastError=$_.Exception.Message;$s.nextRetryUtc=(Get-Date).ToUniversalTime().AddSeconds($delay).ToString('o');Save-Lane $s;Write-Log $log ('WORKER_ERROR '+$s.lastError+' retry='+$delay);[void](Publish-RepoJson ('results/supervisor/v13-'+$lane+'.json') $s)}
      Start-Sleep -Seconds $PollSeconds
    }
  }finally{try{$mutex.ReleaseMutex()}catch{};$mutex.Dispose()}
}

function Build-Health{
  $rows=@();foreach($lane in $Lanes){$s=Load-Lane $lane;$proc=Get-ProcByLane $lane;$rows+=[pscustomobject]@{lane=$lane;workerRunning=($proc.Count -gt 0);workerPid=if($proc.Count -gt 0){$proc[0].ProcessId}else{$null};pointerRevision=[string]$s.pointerRevision;pointerProject=[string]$s.pointerProject;processedRevision=[string]$s.processedRevision;status=[string]$s.status;attempts=[int]$s.attempts;lastError=[string]$s.lastError;nextRetryUtc=[string]$s.nextRetryUtc;runnerPid=$s.runnerPid;lastExitCode=$s.lastExitCode;updatedUtc=[string]$s.updatedUtc}}
  [pscustomobject][ordered]@{schemaVersion=4;version='1.3';architecture='independent-lane-workers';status=if(@($rows|Where-Object{-not $_.workerRunning}).Count -eq 0){'HEALTHY'}else{'DEGRADED'};coordinatorPid=$PID;runner=$Runner;pollSeconds=$PollSeconds;publishSeconds=$PublishSeconds;tokenAvailable=(-not [string]::IsNullOrWhiteSpace($Token));lanes=$rows;updatedUtc=(Get-Date).ToUniversalTime().ToString('o')}
}
function Start-Worker([string]$lane){Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$Self,'-Root',$Root,'-PollSeconds',$PollSeconds,'-PublishSeconds',$PublishSeconds,'-WorkerLane',$lane) -WorkingDirectory $Root|Out-Null}
function Run-Coordinator{
  if(-not(Test-Path $Runner)){throw 'RUNNER_403_MISSING'}
  $mutex=New-Object Threading.Mutex($false,'Global\3EN-MultiProject-Supervisor-v13-Coordinator')
  if(-not $mutex.WaitOne(0)){exit 0}
  try{
    Write-Log $CoordLog ('COORDINATOR_START pid='+$PID)
    $lastPublish=[datetime]::MinValue
    while($true){
      foreach($lane in $Lanes){if((Get-ProcByLane $lane).Count -eq 0){Write-Log $CoordLog ('WORKER_RESTART lane='+$lane);Start-Worker $lane;Start-Sleep -Milliseconds 500}}
      $h=Build-Health;$h|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $HealthFile -Encoding UTF8
      if(((Get-Date)-$lastPublish).TotalSeconds -ge $PublishSeconds){[void](Publish-RepoJson 'results/supervisor/v13-health.json' $h);$lastPublish=Get-Date}
      Start-Sleep -Seconds $PollSeconds
    }
  }finally{try{$mutex.ReleaseMutex()}catch{};$mutex.Dispose()}
}

if([string]::IsNullOrWhiteSpace($WorkerLane)){Run-Coordinator}else{Run-Worker $WorkerLane}
