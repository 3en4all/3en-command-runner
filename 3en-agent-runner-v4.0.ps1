# 3EN Agent Runner v4.0 - Autonomous Core
# Windows PowerShell 5.1
param(
    [string]$ProjectPath='project-v4.0-acceptance.json',
    [string]$Root='C:\3EN-Agent',
    [string]$Repo='3en4all/3en-command-runner',
    [string]$Branch='main'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$RunsDir=Join-Path $Root 'runs'
$LogFile=Join-Path $Root '3en-agent.log'
$ProjectStateFile=Join-Path $Root '3en-project.state.json'
$AgentStateFile=Join-Path $Root '3en-agent.state.json'
New-Item -ItemType Directory -Force -Path $Root,$RunsDir | Out-Null

function Log([string]$m,[string]$l='INFO'){$x='[{0}][{1}] {2}'-f(Get-Date -Format'yyyy-MM-dd HH:mm:ss'),$l,$m;Write-Host $x;Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value $x}
function Admin{$i=[Security.Principal.WindowsIdentity]::GetCurrent();$p=New-Object Security.Principal.WindowsPrincipal($i);$p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}
function Prop($o,[string]$n,$d=$null){if($null-eq$o){return$d};$p=$o.PSObject.Properties[$n];if($null-eq$p){return$d};return$p.Value}
function Headers{$t=$env:THREEEN_GH_TOKEN;if([string]::IsNullOrWhiteSpace($t)){$t=[Environment]::GetEnvironmentVariable('THREEEN_GH_TOKEN','User')};if([string]::IsNullOrWhiteSpace($t)){throw'THREEEN_GH_TOKEN missing'};@{Authorization='Bearer '+$t;Accept='application/vnd.github+json';'X-GitHub-Api-Version'='2022-11-28';'User-Agent'='3EN-Agent-v4.0'}}
function RepoText([string]$p,$h){$u='https://api.github.com/repos/'+$Repo+'/contents/'+$p+'?ref='+$Branch+'&ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();$r=Invoke-RestMethod -Method Get -Uri $u -Headers $h -TimeoutSec 20;$b=([string]$r.content).Replace("`r",'').Replace("`n",'');[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b))}
function NewState([string]$id){[pscustomobject]@{projectId=$id;chapters=[pscustomobject]@{};updatedUtc=$null}}
function LoadState([string]$id){if(Test-Path $ProjectStateFile){try{$s=Get-Content $ProjectStateFile -Raw -Encoding UTF8|ConvertFrom-Json;if([string]$s.projectId-eq$id){return$s}}catch{}};NewState $id}
function SaveState($s){$s.updatedUtc=(Get-Date).ToUniversalTime().ToString('o');$s|ConvertTo-Json -Depth 30|Set-Content $ProjectStateFile -Encoding UTF8}
function ChapterState($s,[string]$id){$p=$s.chapters.PSObject.Properties[$id];if($null-eq$p){return$null};return$p.Value}
function SetChapterState($s,[string]$id,[string]$status,[string]$stage,[int]$attempt){$v=[pscustomobject]@{status=$status;stage=$stage;attempt=$attempt;updatedUtc=(Get-Date).ToUniversalTime().ToString('o')};$p=$s.chapters.PSObject.Properties[$id];if($null-eq$p){$s.chapters|Add-Member -NotePropertyName $id -NotePropertyValue $v}else{$p.Value=$v};SaveState $s;if($status-in@('SUCCESS','SUCCESS_RECOVERED','REJECTED','FAILED','BLOCKED')){[ordered]@{lastExecutedId=$id;lastTerminalStatus=$status;updatedUtc=(Get-Date).ToUniversalTime().ToString('o')}|ConvertTo-Json|Set-Content $AgentStateFile -Encoding UTF8}}
function Step([string]$name,[string]$code,[string]$transcript,[bool]$show){if([string]::IsNullOrWhiteSpace($code)){return[pscustomobject]@{name=$name;status='SKIPPED';error=$null}};Log($name+' START');try{$o=&([ScriptBlock]::Create($code))*>&1;if($null-ne$o){$o|Out-String|Add-Content $transcript -Encoding UTF8};Log($name+' OK');[pscustomobject]@{name=$name;status='OK';error=$null}}catch{($_|Out-String)|Add-Content $transcript -Encoding UTF8;if($show){Write-Host($_|Out-String)-ForegroundColor Red}else{Log($name+' handled internally')'WARN'};[pscustomobject]@{name=$name;status='FAILED';error=$_.Exception.Message}}}
function Put([string]$path,[string]$text,[string]$msg,$h,[int]$retries){$u='https://api.github.com/repos/'+$Repo+'/contents/'+$path;$body=@{message=$msg;content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text));branch=$Branch}|ConvertTo-Json -Compress;for($i=1;$i-le$retries;$i++){try{Invoke-RestMethod -Method Put -Uri $u -Headers $h -ContentType'application/json' -Body $body -TimeoutSec 20|Out-Null;return$true}catch{if($i-lt$retries){Start-Sleep -Seconds([Math]::Min(4,$i*2))}}};return$false}
function Publish([string]$id,[string]$stamp,[string]$result,[string]$transcript,$h,[int]$retries){$safe=$id-replace'[^a-zA-Z0-9._-]','_';$r=Get-Content $result -Raw -Encoding UTF8;$t='';if(Test-Path $transcript){$t=Get-Content $transcript -Raw -Encoding UTF8};$a=Put('results/'+$safe+'-'+$stamp+'.json')$r('v4.0 result '+$id)$h $retries;$b=Put('results/'+$safe+'-'+$stamp+'.output.txt')$t('v4.0 output '+$id)$h $retries;return($a-and$b)}
function Terminal([string]$s){return$s-in@('SUCCESS','SUCCESS_RECOVERED','REJECTED','FAILED','BLOCKED')}

if(-not(Admin)){Write-Host'3EN requires Administrator.';exit 1}
$h=Headers
$mutex=New-Object Threading.Mutex($false,'Global\3EN-Agent-Project-v40');if(-not$mutex.WaitOne(0)){Write-Host'3EN project already active.';exit 2}
try{
 Log'3EN Agent Runner v4.0 started'
 $project=RepoText $ProjectPath $h|ConvertFrom-Json
 $projectId=[string](Prop $project'projectId' '');$chapters=@(Prop $project'chapters' @());if([string]::IsNullOrWhiteSpace($projectId)-or$chapters.Count-lt1){throw'PRECHECK_FAILED'}
 $policy=Prop $project'policy'$null;$show=[bool](Prop $policy'showErrors'$false);$maxDefault=[int](Prop $policy'maxAttempts'2);$publishRetries=[int](Prop $policy'publishRetries'3);$rollbackFinal=[bool](Prop $policy'autoRollbackOnFinalFailure'$true);$riskPolicy=[string](Prop $policy'highRiskAction' 'reject');$allowedRisk=@('low','medium','high');$allowedExpected=@('SUCCESS','SUCCESS_RECOVERED','REJECTED','FAILED','BLOCKED')
 # PRECHECK: validate every chapter and task before first machine change.
 $seen=@{};$taskCache=@{}
 foreach($ch in$chapters){$id=[string](Prop $ch'id' '');$path=[string](Prop $ch'path' '');if([string]::IsNullOrWhiteSpace($id)-or[string]::IsNullOrWhiteSpace($path)-or$seen.ContainsKey($id)){throw'PRECHECK_FAILED'};$seen[$id]=$true;$task=RepoText $path $h|ConvertFrom-Json;if([string](Prop $task'id' '')-ne$id){throw'PRECHECK_FAILED'};$risk=([string](Prop $task'risk' 'low')).ToLowerInvariant();if($risk-notin$allowedRisk){throw'PRECHECK_FAILED'};$expected=[string](Prop $ch'expectedStatus' 'SUCCESS');if($expected-notin$allowedExpected){throw'PRECHECK_FAILED'};$deps=@(Prop $ch'dependsOn' @());foreach($d in$deps){$did=[string](Prop $d'id' '');$dst=[string](Prop $d'status' 'SUCCESS');if([string]::IsNullOrWhiteSpace($did)-or$dst-notin$allowedExpected){throw'PRECHECK_FAILED'}};$taskCache[$id]=$task}
 foreach($ch in$chapters){foreach($d in@(Prop $ch'dependsOn' @())){if(-not$seen.ContainsKey([string](Prop $d'id' ''))){throw'PRECHECK_FAILED'}}}
 if($riskPolicy-notin@('reject','prompt','approve')){throw'PRECHECK_FAILED'}
 Log('PRECHECK PASS chapters='+$chapters.Count)
 $state=LoadState $projectId;$counts=[ordered]@{success=0;recovered=0;rejected=0;failed=0;blocked=0};$mismatch=$false
 foreach($ch in$chapters){
  $id=[string]$ch.id;$expected=[string](Prop $ch'expectedStatus' 'SUCCESS');$cs=ChapterState $state $id;if($null-ne$cs-and(Terminal([string]$cs.status))){Log('RESUME SKIP '+$id+' status='+$cs.status);continue}
  $depsOk=$true;foreach($d in@(Prop $ch'dependsOn' @())){$ds=ChapterState $state([string]$d.id);if($null-eq$ds-or[string]$ds.status-ne[string]$d.status){$depsOk=$false;break}}
  if(-not$depsOk){SetChapterState $state $id'BLOCKED''DEPENDENCY'0;Log('CHAPTER TERMINAL id='+$id+' status=BLOCKED');$counts.blocked++;if($expected-ne'BLOCKED'){$mismatch=$true};continue}
  $task=$taskCache[$id];$risk=([string](Prop $task'risk' 'low')).ToLowerInvariant();$approval='approve';if($risk-eq'high'){$approval=$riskPolicy};if($approval-eq'prompt'){Write-Host'[Y] approve high-risk chapter [N] reject';while($true){$k=[Console]::ReadKey($true);if($k.KeyChar-eq'y'-or$k.KeyChar-eq'Y'){$approval='approve';break};if($k.KeyChar-eq'n'-or$k.KeyChar-eq'N'){$approval='reject';break}}}
  $stamp=Get-Date -Format'yyyyMMdd-HHmmss';$dir=Join-Path $RunsDir($stamp+'-'+$id);New-Item -ItemType Directory -Force -Path $dir|Out-Null;$tr=Join-Path $dir'transcript.txt';$res=Join-Path $dir'result.json';$steps=New-Object System.Collections.Generic.List[object]
  if($approval-eq'reject'){SetChapterState $state $id'REJECTED''RISK_POLICY'0;[ordered]@{projectId=$projectId;chapterId=$id;risk=$risk;status='REJECTED';stage='RISK_POLICY';attempts=0;steps=@()}|ConvertTo-Json -Depth 20|Set-Content $res -Encoding UTF8;[void](Publish $id $stamp $res $tr $h $publishRetries);Log('CHAPTER TERMINAL id='+$id+' status=REJECTED');$counts.rejected++;if($expected-ne'REJECTED'){$mismatch=$true};continue}
  $backup=[string](Prop $task'backup' '');$script=[string](Prop $task'script' '');$test=[string](Prop $task'test' '');$repair=[string](Prop $task'repair' '');$rollback=[string](Prop $task'rollback' '');$max=[int](Prop $ch'maxAttempts'$maxDefault);if($max-lt1){$max=1}
  SetChapterState $state $id'RUNNING''BACKUP_PENDING'0;$bs=Step'BACKUP'$backup $tr $show;[void]$steps.Add($bs);if($bs.status-eq'FAILED'){$status='FAILED';$attempt=0}else{SetChapterState $state $id'RUNNING''BACKUP_DONE'0;$status='FAILED';$attempt=0;for($a=1;$a-le$max;$a++){$attempt=$a;SetChapterState $state $id'RUNNING''SCRIPT_PENDING'$a;$ss=Step('SCRIPT_'+$a)$script $tr $show;[void]$steps.Add($ss);$ok=$ss.status-eq'OK';if($ok){SetChapterState $state $id'RUNNING''CHANGE_DONE'$a;if(-not[string]::IsNullOrWhiteSpace($test)){SetChapterState $state $id'RUNNING''TEST_PENDING'$a;$ts=Step('TEST_'+$a)$test $tr $show;[void]$steps.Add($ts);$ok=$ts.status-eq'OK'}};if($ok){if($a-eq1){$status='SUCCESS'}else{$status='SUCCESS_RECOVERED'};break};if($a-lt$max-and-not[string]::IsNullOrWhiteSpace($repair)){SetChapterState $state $id'RUNNING''REPAIR_PENDING'$a;$rp=Step('REPAIR_'+$a)$repair $tr $show;[void]$steps.Add($rp);if($rp.status-ne'OK'){break}}else{break}}}
  if($status-eq'FAILED'-and$rollbackFinal-and-not[string]::IsNullOrWhiteSpace($rollback)){SetChapterState $state $id'RUNNING''ROLLBACK_PENDING'$attempt;$rb=Step'ROLLBACK'$rollback $tr $show;[void]$steps.Add($rb)}
  SetChapterState $state $id $status'TERMINAL'$attempt;[ordered]@{projectId=$projectId;chapterId=$id;risk=$risk;status=$status;stage='TERMINAL';attempts=$attempt;steps=$steps.ToArray()}|ConvertTo-Json -Depth 30|Set-Content $res -Encoding UTF8;[void](Publish $id $stamp $res $tr $h $publishRetries);Log('CHAPTER TERMINAL id='+$id+' status='+$status);if($status-eq'SUCCESS'){$counts.success++}elseif($status-eq'SUCCESS_RECOVERED'){$counts.recovered++}else{$counts.failed++};if($expected-ne$status){$mismatch=$true}
 }
 $remaining=0;foreach($ch in$chapters){$cs=ChapterState $state([string]$ch.id);if($null-eq$cs-or-not(Terminal([string]$cs.status))){$remaining++}}
 $accepted=(-not$mismatch-and$remaining-eq0);$verdict='SUCCESS';if($counts.recovered-gt0){$verdict='RECOVERED'};if(-not$accepted){$verdict='NEEDS_DECISION'}
 $summary=[ordered]@{schemaVersion=2;projectId=$projectId;runnerVersion='4.0';verdict=$verdict;accepted=$accepted;counts=$counts;remaining=$remaining;completedUtc=(Get-Date).ToUniversalTime().ToString('o')};$txt=$summary|ConvertTo-Json -Depth 20;$stamp=Get-Date -Format'yyyyMMdd-HHmmss';$txt|Set-Content(Join-Path $RunsDir('project-'+$projectId+'.summary.json'))-Encoding UTF8;[void](Put('results/project-'+$projectId+'-'+$stamp+'.summary.json')$txt('v4.0 project summary '+$projectId)$h $publishRetries)
 Write-Host'';if($accepted){Write-Host('PROJECT '+$verdict)-ForegroundColor Green;exit 0}else{Write-Host'PROJECT NEEDS DECISION'-ForegroundColor Yellow;exit 4}
}finally{try{$mutex.ReleaseMutex()}catch{};$mutex.Dispose()}
