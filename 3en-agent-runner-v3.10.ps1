# 3EN Agent Runner v3.10 - Autonomous Hardening
# Windows PowerShell 5.1
param(
    [string]$ProjectPath='project-v3.10-acceptance.json',
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

function Write-Log{param([string]$Message,[string]$Level='INFO');$l='[{0}][{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message;Write-Host $l;Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value $l}
function Is-Admin{$i=[Security.Principal.WindowsIdentity]::GetCurrent();$p=New-Object Security.Principal.WindowsPrincipal($i);$p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}
function OptS{param($o,[string]$n,[string]$d='');if($null-eq$o){return$d};$p=$o.PSObject.Properties[$n];if($null-eq$p){return$d};[string]$p.Value}
function OptI{param($o,[string]$n,[int]$d);if($null-eq$o){return$d};$p=$o.PSObject.Properties[$n];if($null-eq$p){return$d};[int]$p.Value}
function OptB{param($o,[string]$n,[bool]$d);if($null-eq$o){return$d};$p=$o.PSObject.Properties[$n];if($null-eq$p){return$d};[bool]$p.Value}
function Headers{$t=$env:THREEEN_GH_TOKEN;if([string]::IsNullOrWhiteSpace($t)){$t=[Environment]::GetEnvironmentVariable('THREEEN_GH_TOKEN','User')};if([string]::IsNullOrWhiteSpace($t)){throw'THREEEN_GH_TOKEN missing'};@{Authorization='Bearer '+$t;Accept='application/vnd.github+json';'X-GitHub-Api-Version'='2022-11-28';'User-Agent'='3EN-Agent-v3.10'}}
function RepoText{param([string]$Path,$H);$u='https://api.github.com/repos/'+$Repo+'/contents/'+$Path+'?ref='+$Branch+'&ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();$r=Invoke-RestMethod -Method Get -Uri $u -Headers $H -TimeoutSec 20;$b=([string]$r.content).Replace("`n",'').Replace("`r",'');[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b))}
function New-State{param([string]$Id);[pscustomobject]@{projectId=$Id;chapterStatuses=[pscustomobject]@{};updatedUtc=$null}}
function Load-State{param([string]$Id);if(Test-Path $ProjectStateFile){try{$s=Get-Content $ProjectStateFile -Raw -Encoding UTF8|ConvertFrom-Json;if([string]$s.projectId-eq$Id){return$s}}catch{}};New-State $Id}
function Save-State{param($s);$s.updatedUtc=(Get-Date).ToUniversalTime().ToString('o');$s|ConvertTo-Json -Depth 20|Set-Content $ProjectStateFile -Encoding UTF8}
function Get-St{param($s,[string]$id);$p=$s.chapterStatuses.PSObject.Properties[$id];if($null-eq$p){return$null};[string]$p.Value}
function Set-St{param($s,[string]$id,[string]$st);$p=$s.chapterStatuses.PSObject.Properties[$id];if($null-eq$p){$s.chapterStatuses|Add-Member -NotePropertyName $id -NotePropertyValue $st}else{$p.Value=$st};Save-State $s;[ordered]@{lastExecutedId=$id;lastTerminalStatus=$st;updatedUtc=(Get-Date).ToUniversalTime().ToString('o')}|ConvertTo-Json|Set-Content $AgentStateFile -Encoding UTF8}
function Classify{param([string]$Step,[string]$Message);if($Step-like'BACKUP*'){return'BACKUP'};if($Message-match'network|timeout|temporar|connection|HTTP'){return'TRANSIENT'};if($Step-like'TEST*'){return'VALIDATION'};if($Step-like'REPAIR*'){return'REPAIR'};return'EXECUTION'}
function Step{param([string]$Name,[string]$Code,[string]$Transcript,[bool]$Show);if([string]::IsNullOrWhiteSpace($Code)){return[pscustomobject]@{name=$Name;status='SKIPPED';class='NONE';error=$null}};Write-Log($Name+' START');try{$o=&([ScriptBlock]::Create($Code))*>&1;if($null-ne$o){$o|Out-String|Add-Content $Transcript -Encoding UTF8};Write-Log($Name+' OK');[pscustomobject]@{name=$Name;status='OK';class='NONE';error=$null}}catch{$m=$_.Exception.Message;($_|Out-String)|Add-Content $Transcript -Encoding UTF8;if($Show){Write-Host($_|Out-String)-ForegroundColor Red}else{Write-Log($Name+' handled internally')'WARN'};[pscustomobject]@{name=$Name;status='FAILED';class=(Classify $Name $m);error=$m}}}
function PutText{param([string]$Path,[string]$Text,[string]$Msg,$H,[int]$Retries=3);$u='https://api.github.com/repos/'+$Repo+'/contents/'+$Path;$body=@{message=$Msg;content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text));branch=$Branch}|ConvertTo-Json -Compress;for($i=1;$i-le$Retries;$i++){try{Invoke-RestMethod -Method Put -Uri $u -Headers $H -ContentType'application/json' -Body $body -TimeoutSec 20|Out-Null;return$true}catch{if($i-lt$Retries){Start-Sleep -Seconds([Math]::Min(4,$i*2))}}};return$false}
function PublishRun{param([string]$Id,[string]$Stamp,[string]$Result,[string]$Transcript,$H,[int]$Retries);$safe=$Id-replace'[^a-zA-Z0-9._-]','_';$rt=Get-Content $Result -Raw -Encoding UTF8;$ot='';if(Test-Path $Transcript){$ot=Get-Content $Transcript -Raw -Encoding UTF8};$a=PutText('results/'+$safe+'-'+$Stamp+'.json')$rt('v3.10 result '+$Id)$H $Retries;$b=PutText('results/'+$safe+'-'+$Stamp+'.output.txt')$ot('v3.10 output '+$Id)$H $Retries;return($a-and$b)}
function Approval{param([string]$Mode);if($Mode-eq'approve'){return$true};if($Mode-eq'reject'){return$false};Write-Host'[Y] Approve [N] Reject';while($true){if([Console]::KeyAvailable){$k=[Console]::ReadKey($true);$c=[char]::ToUpperInvariant($k.KeyChar);if($c-eq'Y'){return$true};if($c-eq'N'){return$false}};Start-Sleep -Milliseconds 50}}

if(-not(Is-Admin)){Write-Host'Run PowerShell as Administrator.';exit 1}
$H=Headers
$m=New-Object Threading.Mutex($false,'Global\3EN-Agent-Project-v310');if(-not$m.WaitOne(0)){Write-Host'Another 3EN project is active.';exit 2}
try{
 Write-Log'3EN Agent Runner v3.10 started'
 $project=RepoText $ProjectPath $H|ConvertFrom-Json
 if((-not$project.projectId)-or(@($project.chapters).Count-lt1)){throw'Invalid project manifest'}
 $policy=$null;$pp=$project.PSObject.Properties['policy'];if($null-ne$pp){$policy=$pp.Value}
 $defaultApproval=(OptS $policy'defaultApproval''approve').ToLowerInvariant();$maxDefault=OptI $policy'maxAttempts'2;$show=OptB $policy'showErrors'$false;$rollbackFinal=OptB $policy'autoRollbackOnFinalFailure'$true;$publishRetries=OptI $policy'publishRetries'3;$continueFailure=OptB $policy'continueOnFailure'$true
 $state=Load-State([string]$project.projectId);$acceptFail=$false;$recovered=0;$failed=0;$rejected=0;$success=0;$idx=0;$total=@($project.chapters).Count
 foreach($ch in @($project.chapters)){
  $idx++;$id=[string]$ch.id;$existing=Get-St $state $id;if($existing-in@('SUCCESS','SUCCESS_RECOVERED','REJECTED','FAILED')){Write-Log('RESUME SKIP '+$id+' status='+$existing);continue}
  $path=OptS $ch'path''';if([string]::IsNullOrWhiteSpace($path)){throw'Missing chapter path'};$task=RepoText $path $H|ConvertFrom-Json;if([string]$task.id-ne$id){throw'Manifest/task mismatch'}
  Write-Host'';Write-Host('3EN PROJECT '+$idx+'/'+$total+' '+$id)-ForegroundColor Cyan;Write-Host([string]$task.title)
  $mode=(OptS $ch'approval'$defaultApproval).ToLowerInvariant();$approved=Approval $mode;$expected=OptS $ch'expectedStatus'';$stamp=Get-Date -Format'yyyyMMdd-HHmmss';$dir=Join-Path $RunsDir($stamp+'-'+$id);New-Item -ItemType Directory -Force -Path $dir|Out-Null;$tr=Join-Path $dir'transcript.txt';$res=Join-Path $dir'result.json';$steps=New-Object System.Collections.Generic.List[object]
  if(-not$approved){$status='REJECTED';$rejected++;Set-St $state $id $status;[ordered]@{projectId=$project.projectId;chapterId=$id;status=$status;attempts=0;steps=@()}|ConvertTo-Json -Depth 20|Set-Content $res -Encoding UTF8;[void](PublishRun $id $stamp $res $tr $H $publishRetries);if((-$null-ne$expected)-and(-not[string]::IsNullOrWhiteSpace($expected))-and$expected-ne$status){$acceptFail=$true};continue}
  $backup=OptS $task'backup'';$script=OptS $task'script'';$test=OptS $task'test'';$repair=OptS $task'repair'';$rollback=OptS $task'rollback'';$max=OptI $ch'maxAttempts'$maxDefault;if($max-lt1){$max=1}
  $bs=Step'BACKUP'$backup $tr $show;[void]$steps.Add($bs);$status='FAILED';$attemptUsed=0
  if($bs.status-ne'FAILED'){for($a=1;$a-le$max;$a++){$attemptUsed=$a;Write-Log('ATTEMPT '+$a+'/'+$max+' id='+$id);$ss=Step('SCRIPT_'+$a)$script $tr $show;[void]$steps.Add($ss);$ok=$ss.status-eq'OK';if($ok-and(-not[string]::IsNullOrWhiteSpace($test))){$ts=Step('TEST_'+$a)$test $tr $show;[void]$steps.Add($ts);$ok=$ts.status-eq'OK'};if($ok){if($a-eq1){$status='SUCCESS'}else{$status='SUCCESS_RECOVERED'};break};if($a-lt$max){if(-not[string]::IsNullOrWhiteSpace($repair)){$rs=Step('REPAIR_'+$a)$repair $tr $show;[void]$steps.Add($rs);if($rs.status-ne'OK'){break}}else{break}}}}
  if($status-eq'FAILED'-and$rollbackFinal-and(-not[string]::IsNullOrWhiteSpace($rollback))){$rb=Step'ROLLBACK'$rollback $tr $show;[void]$steps.Add($rb)}
  if($status-eq'SUCCESS'){$success++}elseif($status-eq'SUCCESS_RECOVERED'){$recovered++}else{$failed++}
  Set-St $state $id $status;[ordered]@{projectId=$project.projectId;chapterId=$id;status=$status;attempts=$attemptUsed;steps=$steps.ToArray()}|ConvertTo-Json -Depth 30|Set-Content $res -Encoding UTF8;$pub=PublishRun $id $stamp $res $tr $H $publishRetries;if(-not$pub){Write-Log'Artifact publication deferred after retries''WARN'};Write-Log('CHAPTER TERMINAL id='+$id+' status='+$status)
  if((-not[string]::IsNullOrWhiteSpace($expected))-and$expected-ne$status){$acceptFail=$true};if($status-eq'FAILED'-and(-not$continueFailure)){break}
 }
 $remaining=0;foreach($ch in @($project.chapters)){if((Get-St $state([string]$ch.id))-notin@('SUCCESS','SUCCESS_RECOVERED','REJECTED','FAILED')){$remaining++}}
 $verdict='SUCCESS';if($recovered-gt0){$verdict='RECOVERED'};if($remaining-gt0-or$acceptFail-or$failed-gt0){$verdict='NEEDS_DECISION'}
 $summary=[ordered]@{schemaVersion=1;projectId=$project.projectId;runnerVersion='3.10';verdict=$verdict;success=$success;recovered=$recovered;rejected=$rejected;failed=$failed;remaining=$remaining;accepted=(-not$acceptFail-and$remaining-eq0-and$failed-eq0);completedUtc=(Get-Date).ToUniversalTime().ToString('o')}
 $sumText=$summary|ConvertTo-Json -Depth 10;$sumPath=Join-Path $RunsDir('project-'+([string]$project.projectId)+'.summary.json');$sumText|Set-Content $sumPath -Encoding UTF8;$sumStamp=Get-Date -Format'yyyyMMdd-HHmmss';[void](PutText('results/project-'+([string]$project.projectId)+'-'+$sumStamp+'.summary.json')$sumText('v3.10 project summary '+[string]$project.projectId)$H $publishRetries)
 Write-Host''
 if($summary.accepted){Write-Host('PROJECT '+$verdict)-ForegroundColor Green;exit 0}else{Write-Host'PROJECT NEEDS DECISION'-ForegroundColor Yellow;exit 4}
}finally{try{$m.ReleaseMutex()}catch{};$m.Dispose()}
