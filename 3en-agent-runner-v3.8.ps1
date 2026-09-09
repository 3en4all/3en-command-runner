# 3EN Agent Runner v3.8 - Declarative Project Orchestrator
# Windows PowerShell 5.1 / Windows 11

param(
    [string]$ProjectPath = 'project.json',
    [string]$Root = 'C:\3EN-Agent',
    [string]$Repo = '3en4all/3en-command-runner',
    [string]$Branch = 'main'
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$LogFile=Join-Path $Root '3en-agent.log'
$RunsDir=Join-Path $Root 'runs'
$AgentStateFile=Join-Path $Root '3en-agent.state.json'
$ProjectStateFile=Join-Path $Root '3en-project.state.json'
New-Item -ItemType Directory -Force -Path $Root,$RunsDir|Out-Null

function Log([string]$Message,[string]$Level='INFO'){
    $line='[{0}][{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value $line
}
function Is-Admin{
    $id=[Security.Principal.WindowsIdentity]::GetCurrent()
    $p=[Security.Principal.WindowsPrincipal]::new($id)
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-Headers{
    $token=$env:THREEEN_GH_TOKEN
    if([string]::IsNullOrWhiteSpace($token)){$token=[Environment]::GetEnvironmentVariable('THREEEN_GH_TOKEN','User')}
    if([string]::IsNullOrWhiteSpace($token)){throw 'THREEEN_GH_TOKEN missing.'}
    @{Authorization=('Bearer '+$token);Accept='application/vnd.github+json';'X-GitHub-Api-Version'='2022-11-28';'User-Agent'='3EN-Agent-v3.8'}
}
function Get-RepoText([string]$Path,$Headers){
    $u='https://api.github.com/repos/'+$Repo+'/contents/'+$Path+'?ref='+$Branch+'&ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $r=Invoke-RestMethod -Method Get -Uri $u -Headers $Headers -TimeoutSec 20
    $b64=([string]$r.content).Replace("`n",'').Replace("`r",'')
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
}
function Get-Bool($Object,[string]$Name,[bool]$Default){
    if($null-eq$Object){return $Default}
    $p=$Object.PSObject.Properties[$Name]
    if($null-eq$p){return $Default}
    [bool]$p.Value
}
function Save-AgentState([string]$Id,[string]$Status){
    [ordered]@{lastExecutedId=$Id;lastTerminalStatus=$Status;updatedUtc=(Get-Date).ToUniversalTime().ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath $AgentStateFile -Encoding UTF8
    Log ('STATE SAVED id='+$Id+' status='+$Status)
}
function Load-ProjectState([string]$ProjectId){
    if(Test-Path -LiteralPath $ProjectStateFile){
        try{$s=Get-Content -LiteralPath $ProjectStateFile -Raw -Encoding UTF8|ConvertFrom-Json;if([string]$s.projectId-eq$ProjectId){return $s}}catch{}
    }
    [pscustomobject]@{projectId=$ProjectId;chapterStatuses=[pscustomobject]@{};updatedUtc=$null}
}
function Save-ProjectState($State){$State.updatedUtc=(Get-Date).ToUniversalTime().ToString('o');$State|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $ProjectStateFile -Encoding UTF8}
function Get-ChapterStatus($State,[string]$Id){$p=$State.chapterStatuses.PSObject.Properties[$Id];if($null-eq$p){return $null};[string]$p.Value}
function Set-ChapterStatus($State,[string]$Id,[string]$Status){
    $p=$State.chapterStatuses.PSObject.Properties[$Id]
    if($null-eq$p){$State.chapterStatuses|Add-Member -NotePropertyName $Id -NotePropertyValue $Status}else{$p.Value=$Status}
    Save-ProjectState $State;Save-AgentState $Id $Status
}
function Choice([string]$Prompt){
    Write-Host '';Write-Host $Prompt -ForegroundColor Yellow;Write-Host 'Press Y or N (no Enter required).' -ForegroundColor DarkGray
    while($true){if([Console]::KeyAvailable){$k=[Console]::ReadKey($true);$c=[char]::ToUpperInvariant($k.KeyChar);if($c-in@('Y','N')){Write-Host $c;return $c}};Start-Sleep -Milliseconds 50}
}
function Run-Step([string]$Name,[string]$Code,[string]$Transcript){
    if([string]::IsNullOrWhiteSpace($Code)){return [pscustomobject]@{name=$Name;status='SKIPPED';error=$null}}
    Write-Host '';Write-Host ('>>> '+$Name) -ForegroundColor Yellow;Log ($Name+' START')
    try{$out=&([ScriptBlock]::Create($Code))*>&1;if($null-ne$out){$out|Tee-Object -FilePath $Transcript -Append|Out-Host};Log($Name+' STEP RETURNED');[pscustomobject]@{name=$Name;status='OK';error=$null}}
    catch{$_|Out-String|Add-Content -LiteralPath $Transcript -Encoding UTF8;Log($Name+' FAILED') 'ERROR';[pscustomobject]@{name=$Name;status='FAILED';error=$_.Exception.Message}}
}
function Put-Text([string]$RemotePath,[string]$Text,[string]$Message,$Headers){
    $api='https://api.github.com/repos/'+$Repo+'/contents/'+$RemotePath
    $body=@{message=$Message;content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text));branch=$Branch}|ConvertTo-Json -Compress
    Invoke-RestMethod -Method Put -Uri $api -Headers $Headers -ContentType 'application/json' -Body $body -TimeoutSec 20|Out-Null
}
function Publish-Run([string]$Id,[string]$Stamp,[string]$ResultPath,[string]$Transcript,$Headers){
    try{$safe=$Id-replace'[^a-zA-Z0-9._-]','_';$result=Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8;$output=if(Test-Path -LiteralPath $Transcript){Get-Content -LiteralPath $Transcript -Raw -Encoding UTF8}else{''};Put-Text ('results/'+$safe+'-'+$Stamp+'.json') $result ('Project result '+$Id+' '+$Stamp) $Headers;Put-Text ('results/'+$safe+'-'+$Stamp+'.output.txt') $output ('Project output '+$Id+' '+$Stamp) $Headers;Log 'RESULT + OUTPUT UPLOADED'}catch{Log 'RESULT UPLOAD FAILED' 'WARN'}
}
function Publish-Terminal([string]$ProjectId,[string]$Id,[string]$Status,[string]$Stamp,$Steps,$Headers){
    $safe=$Id-replace'[^a-zA-Z0-9._-]','_';$dir=Join-Path $RunsDir ($Stamp+'-'+$safe);New-Item -ItemType Directory -Force -Path $dir|Out-Null
    $transcript=Join-Path $dir 'transcript.txt';$result=Join-Path $dir 'result.json'
    [ordered]@{projectId=$ProjectId;chapterId=$Id;status=$Status;startedLocal=$Stamp;steps=@($Steps)}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $result -Encoding UTF8
    Publish-Run $Id $Stamp $result $transcript $Headers
}
function Resolve-Approval($Chapter){
    $p=$Chapter.PSObject.Properties['approval']
    if($null-eq$p){return 'prompt'}
    $v=([string]$p.Value).ToLowerInvariant()
    if($v-notin@('prompt','approve','reject')){throw ('Invalid approval mode for '+$Chapter.id)}
    $v
}

if(-not(Is-Admin)){Write-Host 'ERROR: Run PowerShell as Administrator.' -ForegroundColor Red;exit 1}
$headers=Get-Headers
$mutex=New-Object Threading.Mutex($false,'Global\3EN-Agent-Project-v38')
if(-not$mutex.WaitOne(0)){Write-Host 'ERROR: another v3.8 project runner is active.' -ForegroundColor Red;exit 2}
try{
    Log '3EN Agent Runner v3.8 started.'
    $project=Get-RepoText $ProjectPath $headers|ConvertFrom-Json
    if(-not$project.projectId-or@($project.chapters).Count-lt1){throw 'Invalid project manifest.'}
    $continueSuccess=Get-Bool $project.policy 'continueOnSuccess' $true
    $continueFailure=Get-Bool $project.policy 'continueOnFailure' $true
    $continueRejected=Get-Bool $project.policy 'continueOnRejected' $true
    Log ('PROJECT LOADED id='+$project.projectId+' chapters='+@($project.chapters).Count)
    $state=Load-ProjectState ([string]$project.projectId);$total=@($project.chapters).Count;$index=0;$acceptanceFailed=$false

    foreach($chapter in @($project.chapters)){
        $index++;$id=[string]$chapter.id;$existing=Get-ChapterStatus $state $id
        if($existing-in@('SUCCESS','FAILED_BACKUP','FAILED_SCRIPT','FAILED_TEST','REJECTED')){Log('PROJECT SKIP terminal chapter '+$id+' status='+$existing);continue}
        $task=Get-RepoText ([string]$chapter.path) $headers|ConvertFrom-Json
        if([string]$task.id-ne$id){throw('Manifest/task id mismatch for '+$id)}
        Write-Host '';Write-Host '====================================================================' -ForegroundColor DarkGray;Write-Host ('3EN AGENT v3.8 - PROJECT CHAPTER '+$index+'/'+$total) -ForegroundColor Yellow;Write-Host ('ID: '+$task.id);Write-Host ('TITLE: '+$task.title) -ForegroundColor Cyan;Write-Host '====================================================================' -ForegroundColor DarkGray

        $mode=Resolve-Approval $chapter
        $approved=$true
        if($mode-eq'reject'){$approved=$false;Log('DECLARATIVE REJECT '+$id)}
        elseif($mode-eq'approve'){Log('DECLARATIVE APPROVE '+$id)}
        else{$approved=((Choice '[Y] Approve chapter   [N] Reject chapter')-eq'Y')}

        if(-not$approved){
            $stamp=Get-Date -Format 'yyyyMMdd-HHmmss';Set-ChapterStatus $state $id 'REJECTED';Publish-Terminal ([string]$project.projectId) $id 'REJECTED' $stamp @() $headers;Log('CHAPTER TERMINAL id='+$id+' status=REJECTED')
            $ep=$chapter.PSObject.Properties['expectedStatus'];if($null-ne$ep-and[string]$ep.Value-ne'REJECTED'){$acceptanceFailed=$true}
            if(-not$continueRejected){break};continue
        }

        $stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$safe=$id-replace'[^a-zA-Z0-9._-]','_';$dir=Join-Path $RunsDir ($stamp+'-'+$safe);New-Item -ItemType Directory -Force -Path $dir|Out-Null;$transcript=Join-Path $dir 'transcript.txt';$resultFile=Join-Path $dir 'result.json';$steps=New-Object System.Collections.Generic.List[object];$overall='SUCCESS'
        if($task.PSObject.Properties.Name.Contains('backup')-and-not[string]::IsNullOrWhiteSpace([string]$task.backup)){$r=Run-Step 'BACKUP' ([string]$task.backup) $transcript;[void]$steps.Add($r);if($r.status-ne'OK'){$overall='FAILED_BACKUP'}}
        if($overall-eq'SUCCESS'){$r=Run-Step 'SCRIPT' ([string]$task.script) $transcript;[void]$steps.Add($r);if($r.status-ne'OK'){$overall='FAILED_SCRIPT'}}
        if($overall-eq'SUCCESS'-and$task.PSObject.Properties.Name.Contains('test')-and-not[string]::IsNullOrWhiteSpace([string]$task.test)){$r=Run-Step 'TEST' ([string]$task.test) $transcript;[void]$steps.Add($r);if($r.status-ne'OK'){$overall='FAILED_TEST'}}
        if($overall-ne'SUCCESS'-and$task.PSObject.Properties.Name.Contains('rollback')-and-not[string]::IsNullOrWhiteSpace([string]$task.rollback)){$autoRollback=Get-Bool $project.policy 'autoRollbackOnFailure' $true;if($autoRollback){$r=Run-Step 'ROLLBACK' ([string]$task.rollback) $transcript;[void]$steps.Add($r)}elseif((Choice '[Y] Run rollback   [N] Leave as-is')-eq'Y'){$r=Run-Step 'ROLLBACK' ([string]$task.rollback) $transcript;[void]$steps.Add($r)}}
        [ordered]@{projectId=$project.projectId;chapterId=$id;status=$overall;startedLocal=$stamp;steps=$steps.ToArray()}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $resultFile -Encoding UTF8
        Set-ChapterStatus $state $id $overall;Publish-Run $id $stamp $resultFile $transcript $headers;Log('CHAPTER TERMINAL id='+$id+' status='+$overall);Write-Host('CHAPTER COMPLETE: '+$id+' -> '+$overall) -ForegroundColor Green
        $ep=$chapter.PSObject.Properties['expectedStatus'];if($null-ne$ep-and[string]$ep.Value-ne$overall){$acceptanceFailed=$true;Log('EXPECTED STATUS MISMATCH id='+$id) 'ERROR'}
        if($overall-eq'SUCCESS'){if(-not$continueSuccess){break}}else{if(-not$continueFailure){break}}
    }

    $remaining=0
    foreach($chapter in @($project.chapters)){$st=Get-ChapterStatus $state ([string]$chapter.id);if($st-notin@('SUCCESS','FAILED_BACKUP','FAILED_SCRIPT','FAILED_TEST','REJECTED')){$remaining++}}
    if($remaining-eq0-and-not$acceptanceFailed){Log('PROJECT ACCEPTED id='+$project.projectId);Write-Host 'PROJECT ACCEPTED' -ForegroundColor Green;exit 0}
    if($remaining-eq0){Log('PROJECT COMPLETE BUT ACCEPTANCE FAILED id='+$project.projectId) 'ERROR';exit 4}
    Log('PROJECT STOPPED remaining='+$remaining) 'WARN';exit 3
}finally{try{$mutex.ReleaseMutex()}catch{};$mutex.Dispose()}
