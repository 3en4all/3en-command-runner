param(
  [string]$Root='C:\3EN-Agent',
  [int]$PollSeconds=15
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$Repo='https://raw.githubusercontent.com/3en4all/3en-command-runner/main'
$Runner=Join-Path $Root '3en-agent-runner-v4.0.3.ps1'
$StateDir=Join-Path $Root 'supervisor-state'
$LogFile=Join-Path $Root '3en-multiproject-supervisor.log'
$HealthFile=Join-Path $Root '3en-multiproject-supervisor.health.json'
$Lanes=@('network-privacy','security-monitor','openclaw')
New-Item -ItemType Directory -Force -Path $StateDir|Out-Null
function Log([string]$m){$line='['+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+'] '+$m;Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8}
function Lane-State([string]$lane){Join-Path $StateDir ($lane+'.json')}
function Load-Lane([string]$lane){$f=Lane-State $lane;if(Test-Path $f){try{return Get-Content $f -Raw|ConvertFrom-Json}catch{}};return [pscustomobject]@{revision='';status='NEW';projectPath='';exitCode=$null;updatedAt=$null}}
function Save-Lane([string]$lane,[string]$rev,[string]$status,[string]$project,[object]$code){[pscustomobject]@{lane=$lane;revision=$rev;status=$status;projectPath=$project;exitCode=$code;updatedAt=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath (Lane-State $lane) -Encoding UTF8}
function Save-Health([string]$status,[string]$activeLane,[string]$activeProject){$states=@();foreach($l in $Lanes){$s=Load-Lane $l;$states+=[pscustomobject]@{lane=$l;revision=[string]$s.revision;status=[string]$s.status;projectPath=[string]$s.projectPath;exitCode=$s.exitCode}};[pscustomobject]@{schemaVersion=2;version='1.1';status=$status;activeLane=$activeLane;activeProject=$activeProject;pid=$PID;runner=$Runner;pollSeconds=$PollSeconds;lanes=$states;updatedAt=(Get-Date).ToString('o')}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $HealthFile -Encoding UTF8}
function Get-Pointer([string]$lane){$ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();Invoke-RestMethod -UseBasicParsing -Uri ($Repo+'/inbox/lanes/'+$lane+'.json?ts='+$ts) -TimeoutSec 20}
function Sync-File([string]$repoPath){if([string]::IsNullOrWhiteSpace($repoPath)){throw 'SYNC_PATH_EMPTY'};$local=Join-Path $Root ($repoPath -replace '/','\');$dir=Split-Path -Parent $local;if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null};$ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();Invoke-WebRequest -UseBasicParsing -Uri ($Repo+'/'+$repoPath.Replace('\','/')+'?ts='+$ts) -OutFile $local -TimeoutSec 30;if(-not(Test-Path $local)){throw ('SYNC_FILE_MISSING '+$repoPath)};return $local}
function Sync-Project([string]$projectPath){$projectLocal=Sync-File $projectPath;$project=Get-Content -LiteralPath $projectLocal -Raw|ConvertFrom-Json;foreach($chapter in @($project.chapters)){if($null -ne $chapter -and $chapter.path){[void](Sync-File ([string]$chapter.path))}};return $projectLocal}
if(-not(Test-Path $Runner)){throw 'RUNNER_403_MISSING'}
$mutex=New-Object Threading.Mutex($false,'Global\3EN-MultiProject-Supervisor-v11')
if(-not $mutex.WaitOne(0)){exit 0}
try{
 Log '3EN MULTIPROJECT SUPERVISOR V1.1 START'
 Save-Health 'IDLE' '' ''
 $cursor=0
 while($true){
  try{
   $claimed=$false
   for($i=0;$i -lt $Lanes.Count;$i++){
    $idx=($cursor+$i)%$Lanes.Count;$lane=$Lanes[$idx]
    try{$ptr=Get-Pointer $lane}catch{Log ('POINTER_ERROR lane='+$lane+' '+$_.Exception.Message);continue}
    $rev=[string]$ptr.revision;$project=[string]$ptr.projectPath;$enabled=[bool]$ptr.enabled
    if(-not $enabled -or [string]::IsNullOrWhiteSpace($rev) -or [string]::IsNullOrWhiteSpace($project)){continue}
    $s=Load-Lane $lane
    if([string]$s.revision -eq $rev){continue}
    $claimed=$true;$cursor=($idx+1)%$Lanes.Count
    Log ('CLAIM lane='+$lane+' revision='+$rev+' project='+$project)
    Save-Lane $lane $rev 'SYNCING' $project $null
    Save-Health 'SYNCING' $lane $project
    $projectLocal=Sync-Project $project
    Log ('SYNC_OK lane='+$lane+' project='+$project+' local='+$projectLocal)
    Save-Lane $lane $rev 'RUNNING' $project $null
    Save-Health 'RUNNING' $lane $project
    $p=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Runner,'-ProjectPath',$projectLocal) -WorkingDirectory $Root -Wait -PassThru -NoNewWindow
    Save-Lane $lane $rev 'TERMINAL' $project $p.ExitCode
    Log ('TERMINAL lane='+$lane+' revision='+$rev+' exit='+$p.ExitCode)
    Save-Health 'IDLE' '' ''
    break
   }
   if(-not $claimed){Save-Health 'IDLE' '' ''}
  }catch{Log ('SUPERVISOR_ERROR '+$_.Exception.Message);Save-Health 'ERROR' '' ''}
  Start-Sleep -Seconds $PollSeconds
 }
}finally{try{$mutex.ReleaseMutex()}catch{};$mutex.Dispose()}
