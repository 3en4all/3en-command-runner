param(
  [string]$Root='C:\3EN-Agent',
  [int]$PollSeconds=15,
  [int]$PublishSeconds=60
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$RepoRaw='https://raw.githubusercontent.com/3en4all/3en-command-runner/main'
$RepoApi='https://api.github.com/repos/3en4all/3en-command-runner'
$Runner=Join-Path $Root '3en-agent-runner-v4.0.3.ps1'
$StateDir=Join-Path $Root 'supervisor-state-v12'
$LogFile=Join-Path $Root '3en-multiproject-supervisor-v12.log'
$HealthFile=Join-Path $Root '3en-multiproject-supervisor-v12.health.json'
$Lanes=@('network-privacy','security-monitor','openclaw')
$Token=$env:THREEEN_GH_TOKEN
New-Item -ItemType Directory -Force -Path $StateDir|Out-Null

function Log([string]$m){$line='['+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+'] '+$m;Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8}
function Lane-StatePath([string]$lane){Join-Path $StateDir ($lane+'.json')}
function Default-Lane([string]$lane){[pscustomobject][ordered]@{schemaVersion=1;lane=$lane;pointerRevision='';pointerProject='';processedRevision='';status='NEW';attempts=0;lastError='';nextRetryUtc='';lastStartedUtc='';lastTerminalUtc='';lastExitCode=$null;updatedUtc=(Get-Date).ToUniversalTime().ToString('o')}}
function Load-Lane([string]$lane){$f=Lane-StatePath $lane;if(Test-Path $f){try{return Get-Content $f -Raw|ConvertFrom-Json}catch{}};return Default-Lane $lane}
function Save-Lane($s){$s.updatedUtc=(Get-Date).ToUniversalTime().ToString('o');$s|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Lane-StatePath ([string]$s.lane)) -Encoding UTF8}
function Get-Pointer([string]$lane){$ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();Invoke-RestMethod -UseBasicParsing -Uri ($RepoRaw+'/inbox/lanes/'+$lane+'.json?ts='+$ts) -TimeoutSec 20}
function Sync-File([string]$repoPath){if([string]::IsNullOrWhiteSpace($repoPath)){throw 'SYNC_PATH_EMPTY'};$local=Join-Path $Root ($repoPath -replace '/','\');$dir=Split-Path -Parent $local;if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null};$ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();Invoke-WebRequest -UseBasicParsing -Uri ($RepoRaw+'/'+$repoPath.Replace('\','/')+'?ts='+$ts) -OutFile $local -TimeoutSec 30;if(-not(Test-Path $local)){throw ('SYNC_FILE_MISSING '+$repoPath)};return $local}
function Sync-Project([string]$projectPath){$projectLocal=Sync-File $projectPath;$project=Get-Content -LiteralPath $projectLocal -Raw|ConvertFrom-Json;foreach($chapter in @($project.chapters)){if($null -ne $chapter -and $chapter.path){[void](Sync-File ([string]$chapter.path))}};return $projectLocal}
function Retry-Delay([int]$attempts){$sec=[Math]::Min(300,[Math]::Max(15,[Math]::Pow(2,[Math]::Min($attempts,8))*15));return [int]$sec}
function Can-Retry($s){if([string]::IsNullOrWhiteSpace([string]$s.nextRetryUtc)){return $true};try{return ((Get-Date).ToUniversalTime() -ge [datetime]::Parse([string]$s.nextRetryUtc).ToUniversalTime())}catch{return $true}}

function Publish-RepoJson([string]$repoPath,[object]$obj){
  if([string]::IsNullOrWhiteSpace($Token)){return $false}
  try{
    $headers=@{Authorization=('Bearer '+$Token);Accept='application/vnd.github+json';'X-GitHub-Api-Version'='2022-11-28'}
    $uri=$RepoApi+'/contents/'+$repoPath
    $sha=$null
    try{$cur=Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -TimeoutSec 20;if($cur.sha){$sha=[string]$cur.sha}}catch{}
    $json=$obj|ConvertTo-Json -Depth 12
    $bytes=[Text.Encoding]::UTF8.GetBytes($json)
    $b64=[Convert]::ToBase64String($bytes)
    $body=[ordered]@{message=('Supervisor v1.2 evidence '+$repoPath);content=$b64;branch='main'}
    if($sha){$body.sha=$sha}
    Invoke-RestMethod -Method Put -Uri $uri -Headers $headers -ContentType 'application/json' -Body ($body|ConvertTo-Json -Depth 4) -TimeoutSec 30|Out-Null
    return $true
  }catch{Log ('PUBLISH_ERROR path='+$repoPath+' '+$_.Exception.Message);return $false}
}

function Build-Health([string]$status,[string]$activeLane,[string]$activeProject){
  $ls=@();foreach($lane in $Lanes){$s=Load-Lane $lane;$ls+=[pscustomobject]@{lane=$lane;pointerRevision=[string]$s.pointerRevision;pointerProject=[string]$s.pointerProject;processedRevision=[string]$s.processedRevision;status=[string]$s.status;attempts=[int]$s.attempts;lastError=[string]$s.lastError;nextRetryUtc=[string]$s.nextRetryUtc;lastExitCode=$s.lastExitCode;updatedUtc=[string]$s.updatedUtc}}
  return [pscustomobject][ordered]@{schemaVersion=3;version='1.2';status=$status;activeLane=$activeLane;activeProject=$activeProject;pid=$PID;runner=$Runner;pollSeconds=$PollSeconds;publishSeconds=$PublishSeconds;tokenAvailable=(-not [string]::IsNullOrWhiteSpace($Token));lanes=$ls;updatedUtc=(Get-Date).ToUniversalTime().ToString('o')}
}
function Save-Health([string]$status,[string]$activeLane,[string]$activeProject,[switch]$Publish){$h=Build-Health $status $activeLane $activeProject;$h|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $HealthFile -Encoding UTF8;if($Publish){[void](Publish-RepoJson 'results/supervisor/v12-health.json' $h);foreach($x in $h.lanes){[void](Publish-RepoJson ('results/supervisor/v12-'+$x.lane+'.json') $x)}}}

if(-not(Test-Path $Runner)){throw 'RUNNER_403_MISSING'}
$mutex=New-Object Threading.Mutex($false,'Global\3EN-MultiProject-Supervisor-v12')
if(-not $mutex.WaitOne(0)){exit 0}
try{
  Log '3EN MULTIPROJECT SUPERVISOR V1.2 START'
  $lastPublish=[datetime]::MinValue
  Save-Health 'IDLE' '' '' -Publish
  $cursor=0
  while($true){
    $didWork=$false
    try{
      for($i=0;$i -lt $Lanes.Count;$i++){
        $idx=($cursor+$i)%$Lanes.Count;$lane=$Lanes[$idx];$s=Load-Lane $lane
        try{
          $ptr=Get-Pointer $lane
          $rev=[string]$ptr.revision;$project=[string]$ptr.projectPath;$enabled=[bool]$ptr.enabled
          $s.pointerRevision=$rev;$s.pointerProject=$project
          if(-not $enabled -or [string]::IsNullOrWhiteSpace($rev) -or [string]::IsNullOrWhiteSpace($project)){$s.status='IDLE';Save-Lane $s;continue}
          if([string]$s.processedRevision -eq $rev -and [string]$s.status -eq 'TERMINAL'){continue}
          if(-not(Can-Retry $s)){continue}
          $didWork=$true;$cursor=($idx+1)%$Lanes.Count
          $s.attempts=[int]$s.attempts+1;$s.lastStartedUtc=(Get-Date).ToUniversalTime().ToString('o');$s.lastError='';$s.status='SYNCING';Save-Lane $s
          Save-Health 'SYNCING' $lane $project -Publish
          Log ('CLAIM lane='+$lane+' revision='+$rev+' project='+$project+' attempt='+$s.attempts)
          $local=Sync-Project $project
          $s.status='RUNNING';Save-Lane $s;Save-Health 'RUNNING' $lane $project -Publish
          Log ('SYNC_OK lane='+$lane+' local='+$local)
          $p=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Runner,'-ProjectPath',$local) -WorkingDirectory $Root -Wait -PassThru -NoNewWindow
          $s.lastExitCode=$p.ExitCode;$s.lastTerminalUtc=(Get-Date).ToUniversalTime().ToString('o')
          if($p.ExitCode -eq 0){$s.status='TERMINAL';$s.processedRevision=$rev;$s.nextRetryUtc='';$s.lastError='';Log ('TERMINAL lane='+$lane+' revision='+$rev+' exit=0')}
          else{$delay=Retry-Delay ([int]$s.attempts);$s.status='RETRY_PENDING';$s.lastError=('RUNNER_EXIT_'+$p.ExitCode);$s.nextRetryUtc=(Get-Date).ToUniversalTime().AddSeconds($delay).ToString('o');Log ('RETRY lane='+$lane+' reason='+$s.lastError+' delay='+$delay)}
          Save-Lane $s;Save-Health 'IDLE' '' '' -Publish
          break
        }catch{
          $delay=Retry-Delay ([int]$s.attempts)
          $s.status='RETRY_PENDING';$s.lastError=$_.Exception.Message;$s.nextRetryUtc=(Get-Date).ToUniversalTime().AddSeconds($delay).ToString('o');Save-Lane $s
          Log ('LANE_ERROR lane='+$lane+' '+$s.lastError+' retry='+$delay)
          Save-Health 'ERROR' $lane ([string]$s.pointerProject) -Publish
        }
      }
      if(-not $didWork){Save-Health 'IDLE' '' ''}
    }catch{Log ('SUPERVISOR_ERROR '+$_.Exception.Message);Save-Health 'ERROR' '' '' -Publish}
    if(((Get-Date)-$lastPublish).TotalSeconds -ge $PublishSeconds){Save-Health 'IDLE' '' '' -Publish;$lastPublish=Get-Date}
    Start-Sleep -Seconds $PollSeconds
  }
}finally{try{$mutex.ReleaseMutex()}catch{};$mutex.Dispose()}
