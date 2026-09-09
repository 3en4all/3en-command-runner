param(
  [string]$Root='C:\3EN-Agent',
  [string]$PointerUrl='https://raw.githubusercontent.com/3en4all/3en-command-runner/main/inbox/openclaw-project.json',
  [string]$RepoRawBase='https://raw.githubusercontent.com/3en4all/3en-command-runner/main',
  [int]$PollSeconds=15
)
$ErrorActionPreference='Stop'
$stateFile=Join-Path $Root '3en-openclaw-inbox.state.json'
$logFile=Join-Path $Root '3en-openclaw-inbox.log'
$runner=Join-Path $Root '3en-agent-runner-v4.0.3-openclaw.ps1'
New-Item -ItemType Directory -Force -Path $Root|Out-Null
function Log([string]$m){Add-Content -LiteralPath $logFile -Value ('['+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+'] '+$m) -Encoding UTF8}
function Load-State{if(Test-Path $stateFile){try{return Get-Content $stateFile -Raw|ConvertFrom-Json}catch{}};return [pscustomobject]@{revision='';status='NEW';projectPath='';exitCode=$null}}
function Save-State([string]$rev,[string]$status,[string]$project,[object]$code){[pscustomobject]@{revision=$rev;status=$status;projectPath=$project;exitCode=$code;updatedAt=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath $stateFile -Encoding UTF8}
function Sync-File([string]$repoPath){
  if([string]::IsNullOrWhiteSpace($repoPath)){throw 'SYNC_PATH_EMPTY'}
  $local=Join-Path $Root ($repoPath -replace '/','\')
  $dir=Split-Path -Parent $local
  if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
  $ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $uri=$RepoRawBase.TrimEnd('/')+'/'+$repoPath.Replace('\','/')+'?ts='+$ts
  Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $local -TimeoutSec 30
  if(-not(Test-Path $local)){throw ('SYNC_FILE_MISSING '+$repoPath)}
  return $local
}
function Sync-Project([string]$projectPath){
  $projectLocal=Sync-File $projectPath
  $project=Get-Content -LiteralPath $projectLocal -Raw|ConvertFrom-Json
  foreach($chapter in @($project.chapters)){
    if($null -ne $chapter -and $chapter.path){[void](Sync-File ([string]$chapter.path))}
  }
  return $projectLocal
}
$mutex=New-Object Threading.Mutex($false,'Global\3EN-OpenClaw-Inbox-v1')
if(-not $mutex.WaitOne(0)){exit 0}
try{
 Log '3EN OPENCLAW INBOX START'
 while($true){
  try{
   if(-not(Test-Path $runner)){throw 'OPENCLAW_RUNNER_403_MISSING'}
   $ptr=Invoke-RestMethod -UseBasicParsing -Uri ($PointerUrl+'?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -TimeoutSec 20
   $rev=[string]$ptr.revision;$project=[string]$ptr.projectPath;$enabled=[bool]$ptr.enabled
   if($enabled -and $rev -and $project){
    $s=Load-State
    if([string]$s.revision -ne $rev){
      Log ('CLAIM revision='+$rev+' project='+$project)
      $projectLocal=Sync-Project $project
      Log ('SYNC OK project='+$project+' local='+$projectLocal)
      Save-State $rev 'RUNNING' $project $null
      $p=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,'-ProjectPath',$projectLocal) -WorkingDirectory $Root -Wait -PassThru -NoNewWindow
      Save-State $rev 'TERMINAL' $project $p.ExitCode
      Log ('TERMINAL revision='+$rev+' exit='+$p.ExitCode)
    }
   }
  }catch{Log ('ERROR '+$_.Exception.Message)}
  Start-Sleep -Seconds $PollSeconds
 }
}finally{try{$mutex.ReleaseMutex()}catch{};$mutex.Dispose()}
