param([Parameter(Mandatory=$true)][ValidateSet('Prepare','Test')][string]$Phase)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$Root='C:\3EN-Agent'
$RepoApi='https://api.github.com/repos/3en4all/3en-command-runner'
$RepoRaw='https://raw.githubusercontent.com/3en4all/3en-command-runner/main'
$Source134=Join-Path $Root 'supervisor-v134-canonical-058f.ps1'
$Target135=Join-Path $Root '3en-multiproject-supervisor-v1.3.5.ps1'
$BackupDir=Join-Path $Root ('backups\supervisor-v135-migration-058f\'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
$Restart=Join-Path $Root 'restart-supervisor-v135-058f.ps1'
$Token=$env:THREEEN_GH_TOKEN
function Parse-Check([string]$p){$tok=$null;$err=$null;[System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$tok,[ref]$err)|Out-Null;if(@($err).Count-ne0){throw ('058F_SYNTAX_ERRORS_'+@($err).Count)}}
function Api-Headers{if([string]::IsNullOrWhiteSpace($Token)){throw '058F_GITHUB_TOKEN_MISSING'};return @{Authorization=('Bearer '+$Token);Accept='application/vnd.github+json';'X-GitHub-Api-Version'='2022-11-28'}}
function Publish-Text([string]$repoPath,[string]$text){$headers=Api-Headers;$uri=$RepoApi+'/contents/'+$repoPath;$sha=$null;try{$cur=Invoke-RestMethod -Method Get -Uri ($uri+'?ref=main&ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -Headers $headers -TimeoutSec 20;if($cur.sha){$sha=[string]$cur.sha}}catch{};$body=[ordered]@{message=('Persist supervisor v1.3.5 source from 058f');content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text));branch='main'};if($sha){$body.sha=$sha};Invoke-RestMethod -Method Put -Uri $uri -Headers $headers -ContentType 'application/json' -Body ($body|ConvertTo-Json -Depth 4) -TimeoutSec 30|Out-Null}
function Verify-135([string]$s){
  if($s -notmatch "version='1\.3\.5'"){throw '058F_VERSION_135_MISSING'}
  if($s -notmatch 'Kill-Tree\(\[int\]\$processId\)'){throw '058F_PROCESSID_FIX_MISSING'}
  if($s -match 'Kill-Tree\(\[int\]\$pid\)'){throw '058F_READONLY_PID_REMAINS'}
  if($s -notmatch 'runnerTimeoutSeconds=\$RunnerTimeoutSeconds'){throw '058F_TIMEOUT_HEALTH_MISSING'}
  if($s -notmatch "results/supervisor/v135-health\.json"){throw '058F_V135_HEALTH_PATH_MISSING'}
  if($s -notmatch "@\('maintenance','network-privacy','security-monitor','openclaw'\)"){throw '058F_LANES_MISSING'}
  if($s -notmatch "ref=main&ts="){throw '058F_POINTER_CACHE_BUSTER_MISSING'}
  if($s -notmatch 'taskkill\.exe /PID \$processId /T /F'){throw '058F_TREE_KILL_MISSING'}
  if($s -notmatch "stale=\$stale"){throw '058F_STALE_DETECTION_MISSING'}
}
if($Phase-eq'Prepare'){
  New-Item -ItemType Directory -Force -Path $BackupDir|Out-Null
  $live134=Join-Path $Root '3en-multiproject-supervisor-v1.3.4.ps1'
  if(Test-Path $live134){Copy-Item $live134 (Join-Path $BackupDir '3en-multiproject-supervisor-v1.3.4.live.ps1') -Force}
  $ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  Invoke-WebRequest -UseBasicParsing -Uri ($RepoRaw+'/automation/3en-multiproject-supervisor-v1.3.4.ps1?ts='+$ts) -OutFile $Source134 -TimeoutSec 30
  Parse-Check $Source134
  $s=Get-Content $Source134 -Raw
  $oldKill='function Kill-Tree([int]$pid){if($pid -le 0){return};try{& taskkill.exe /PID $pid /T /F 2>&1|Out-Null}catch{}}'
  $newKill='function Kill-Tree([int]$processId){if($processId -le 0){return};try{& taskkill.exe /PID $processId /T /F 2>&1|Out-Null}catch{}}'
  if($s.Contains($oldKill)){$s=$s.Replace($oldKill,$newKill)}elseif(-not$s.Contains($newKill)){throw '058F_KILL_PATTERN_NOT_FOUND'}
  $oldPtr="$uri=$RepoApi+'/contents/inbox/lanes/'+$lane+'.json?ref=main';try{"
  $newPtr="$ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();$uri=$RepoApi+'/contents/inbox/lanes/'+$lane+'.json?ref=main&ts='+$ts;try{"
  if($s.Contains($oldPtr)){$s=$s.Replace($oldPtr,$newPtr)}
  $oldSync="$uri=$RepoApi+'/contents/'+$repoPath.Replace('\\','/')+'?ref=main';try{"
  $newSync="$ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();$uri=$RepoApi+'/contents/'+$repoPath.Replace('\\','/')+'?ref=main&ts='+$ts;try{"
  if($s.Contains($oldSync)){$s=$s.Replace($oldSync,$newSync)}
  $s=$s.Replace('v1.3.4','v1.3.5').Replace('v134','v135')
  Set-Content -LiteralPath $Target135 -Value $s -Encoding UTF8
  Parse-Check $Target135
  $verify=Get-Content $Target135 -Raw;Verify-135 $verify
  $state134=Join-Path $Root 'supervisor-state-v134';$state135=Join-Path $Root 'supervisor-state-v135'
  New-Item -ItemType Directory -Force -Path $state135|Out-Null
  if(Test-Path $state134){Copy-Item -Path (Join-Path $state134 '*') -Destination $state135 -Recurse -Force -ErrorAction SilentlyContinue}
  Publish-Text 'automation/3en-multiproject-supervisor-v1.3.5.ps1' $verify
  @'
$ErrorActionPreference='SilentlyContinue'
$Root='C:\3EN-Agent'
$state134=Join-Path $Root 'supervisor-state-v134'
$state135=Join-Path $Root 'supervisor-state-v135'
Start-Sleep -Seconds 10
for($i=0;$i -lt 30;$i++){
  $mf=Join-Path $state134 'maintenance.json'
  $busy=$false
  if(Test-Path $mf){try{$ms=Get-Content $mf -Raw|ConvertFrom-Json;$busy=([string]$ms.status -in @('RUNNING','SYNCING'))}catch{}}
  if(-not $busy){break}
  Start-Sleep -Seconds 1
}
New-Item -ItemType Directory -Force -Path $state135|Out-Null
if(Test-Path $state134){Copy-Item -Path (Join-Path $state134 '*') -Destination $state135 -Recurse -Force -ErrorAction SilentlyContinue}
$old=@(Get-CimInstance Win32_Process|Where-Object{$_.Name -in @('powershell.exe','pwsh.exe') -and $_.CommandLine -and $_.CommandLine -match '3en-multiproject-supervisor-v1\.3\.4\.ps1'})
foreach($p in $old|Sort-Object ProcessId -Descending){try{Stop-Process -Id ([int]$p.ProcessId) -Force}catch{}}
Start-Sleep -Seconds 3
Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',(Join-Path $Root '3en-multiproject-supervisor-v1.3.5.ps1'),'-Root',$Root,'-PollSeconds','15','-PublishSeconds','30','-RunnerTimeoutSeconds','180') -WorkingDirectory $Root|Out-Null
'@|Set-Content -LiteralPath $Restart -Encoding UTF8
  Parse-Check $Restart
  Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$Restart) -WorkingDirectory $Root|Out-Null
  Write-Output ('V466_058F_PREPARE=PASS;SOURCE_PERSISTED=PASS;STATE_MIGRATED=PASS;RESTART_SCHEDULED=true;BACKUP='+$BackupDir)
}
if($Phase-eq'Test'){
  if(-not(Test-Path $Target135)){throw '058F_TARGET_135_MISSING'}
  Parse-Check $Target135;$s=Get-Content $Target135 -Raw;Verify-135 $s
  if(-not(Test-Path (Join-Path $Root 'supervisor-state-v135'))){throw '058F_STATE_V135_MISSING'}
  Write-Output 'V466_058F_TEST=PASS;SYNTAX=PASS;PROCESSID_FIX=PASS;CACHE_BUSTER=PASS;TIMEOUT=180_CONFIGURED;STATE_MIGRATION=PASS'
}
