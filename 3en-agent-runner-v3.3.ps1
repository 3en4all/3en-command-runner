# 3EN Agent Runner v3.3
# Windows 11 / PowerShell
# Elevated PowerShell required.

param(
    [Parameter(Mandatory=$true)][string]$TaskUrl,
    [int]$PollSeconds = 15,
    [string]$Root = "C:\3EN-Agent",
    [string]$ResultRepo = "3en4all/3en-command-runner",
    [string]$ResultBranch = "main"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$StateFile = Join-Path $Root '3en-agent.state.json'
$LogFile   = Join-Path $Root '3en-agent.log'
$RunsDir   = Join-Path $Root 'runs'
New-Item -ItemType Directory -Force -Path $Root,$RunsDir | Out-Null

function Log([string]$Message,[string]$Level='INFO') {
    $line='[{0}][{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Is-Admin {
    $id=[Security.Principal.WindowsIdentity]::GetCurrent()
    $p=[Security.Principal.WindowsPrincipal]::new($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Sha256([string]$Text) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        $h=$sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
        return ([BitConverter]::ToString($h)-replace '-','').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Load-State {
    if(Test-Path $StateFile){
        try { return Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { Log "State read failed: $($_.Exception.Message)" 'WARN' }
    }
    return [pscustomobject]@{lastExecutedId='';lastExecutedHash=''}
}

function Save-State([string]$Id,[string]$Hash) {
    Log 'FINALIZE 1/4: saving state'
    $obj=[ordered]@{lastExecutedId=$Id;lastExecutedHash=$Hash;updatedUtc=(Get-Date).ToUniversalTime().ToString('o')}
    $obj | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
    Log 'FINALIZE 1/4: state saved'
}

function Fetch-Task([string]$Url) {
    $ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $u=if($Url.Contains('?')){"${Url}&ts=$ts"}else{"${Url}?ts=$ts"}
    Log 'Fetching task...'
    $r=Invoke-WebRequest -Uri $u -Headers @{'Cache-Control'='no-cache';Pragma='no-cache';'User-Agent'='3EN-Agent-v3.3'} -TimeoutSec 20
    Log "FETCH OK HTTP=$($r.StatusCode)"
    $t=[string]$r.Content | ConvertFrom-Json
    Log "PARSE OK ID=$($t.id)"
    foreach($req in @('id','title','description','script')){
        if(-not $t.PSObject.Properties.Name.Contains($req) -or [string]::IsNullOrWhiteSpace([string]$t.$req)){
            throw "Task JSON missing field: $req"
        }
    }
    return $t
}

function Show-Task($Task,[string]$Hash) {
    Write-Host ''
    Write-Host '====================================================================' -ForegroundColor DarkGray
    Write-Host '3EN AGENT v3.3 - NEW TASK' -ForegroundColor Yellow
    Write-Host "ID:          $($Task.id)"
    Write-Host "TITLE:       $($Task.title)" -ForegroundColor Cyan
    Write-Host "DESCRIPTION: $($Task.description)"
    Write-Host "SHA256:      $Hash"
    Write-Host '--------------------------------------------------------------------'
    foreach($x in @(@('BACKUP','backup','Magenta'),@('SCRIPT','script','Green'),@('TEST','test','Blue'),@('ROLLBACK','rollback','DarkYellow'))){
        if($Task.PSObject.Properties.Name.Contains($x[1])){
            $v=[string]$Task.($x[1])
            if(-not [string]::IsNullOrWhiteSpace($v)){
                Write-Host "$($x[0]):" -ForegroundColor $x[2]
                Write-Host $v
                Write-Host '--------------------------------------------------------------------'
            }
        }
    }
    Write-Host '====================================================================' -ForegroundColor DarkGray
}

function Choice([string]$Prompt) {
    Write-Host ''
    Write-Host $Prompt -ForegroundColor Yellow
    Write-Host 'Press Y or N (no Enter required).' -ForegroundColor DarkGray
    while($true){
        if([Console]::KeyAvailable){
            $k=[Console]::ReadKey($true)
            $c=[char]::ToUpperInvariant($k.KeyChar)
            if($c -in @('Y','N')){Write-Host $c;return $c}
        }
        Start-Sleep -Milliseconds 50
    }
}

function Run-Step([string]$Name,[string]$Code,[string]$Transcript) {
    if([string]::IsNullOrWhiteSpace($Code)){
        return [pscustomobject]@{name=$Name;status='SKIPPED';error=$null}
    }
    Write-Host ''
    Write-Host ">>> $Name" -ForegroundColor Yellow
    Log "$Name START"
    try {
        $out=& ([ScriptBlock]::Create($Code)) *>&1
        if($null -ne $out){$out | Tee-Object -FilePath $Transcript -Append | Out-Host}
        Log "$Name STEP RETURNED"
        return [pscustomobject]@{name=$Name;status='OK';error=$null}
    } catch {
        $_ | Out-String | Add-Content -LiteralPath $Transcript -Encoding UTF8
        Log "$Name FAILED: $($_.Exception.Message)" 'ERROR'
        return [pscustomobject]@{name=$Name;status='FAILED';error=$_.Exception.Message}
    }
}

function Publish-Result([string]$TaskId,[string]$RunStamp,[string]$ResultPath) {
    try {
        Log 'UPLOAD 1/6: reading token'
        $token=$env:THREEEN_GH_TOKEN
        if([string]::IsNullOrWhiteSpace($token)){
            $token=[Environment]::GetEnvironmentVariable('THREEEN_GH_TOKEN','User')
        }
        if([string]::IsNullOrWhiteSpace($token)){
            Log 'UPLOAD 1/6: token missing - upload skipped' 'WARN'
            return
        }
        Log ("UPLOAD 1/6: token present ({0} chars)" -f $token.Length)

        Log 'UPLOAD 2/6: reading result.json as RAW text'
        $payload=Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8
        if([string]::IsNullOrWhiteSpace($payload)){throw 'result.json is empty'}
        Log ("UPLOAD 2/6: raw chars={0}" -f $payload.Length)

        Log 'UPLOAD 3/6: base64 encoding RAW result'
        $b64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
        $safe=$TaskId-replace '[^a-zA-Z0-9._-]','_'
        $remotePath="results/$safe-$RunStamp.json"
        $api="https://api.github.com/repos/$ResultRepo/contents/$remotePath"
        Log ("UPLOAD 3/6: remote path={0}" -f $remotePath)

        Log 'UPLOAD 4/6: building simple GitHub API body'
        $body=@{
            message="Result $TaskId $RunStamp"
            content=$b64
            branch=$ResultBranch
        } | ConvertTo-Json -Compress
        Log ("UPLOAD 4/6: body chars={0}" -f $body.Length)

        $headers=@{
            Authorization="Bearer $token"
            Accept='application/vnd.github+json'
            'X-GitHub-Api-Version'='2022-11-28'
            'User-Agent'='3EN-Agent-v3.3'
        }

        Log 'UPLOAD 5/6: GET repository metadata'
        $repoInfo=Invoke-RestMethod -Method Get -Uri "https://api.github.com/repos/$ResultRepo" -Headers $headers -TimeoutSec 15
        Log ("UPLOAD 5/6: GET OK repo={0}" -f $repoInfo.full_name)

        Log 'UPLOAD 6/6: PUT START'
        $sw=[Diagnostics.Stopwatch]::StartNew()
        $result=Invoke-RestMethod -Method Put -Uri $api -Headers $headers -Body $body -ContentType 'application/json' -TimeoutSec 20
        $sw.Stop()
        Log ("UPLOAD 6/6: PUT OK in {0:N1}s commit={1}" -f $sw.Elapsed.TotalSeconds,$result.commit.sha)
        Log "FINALIZE 3/4: RESULT UPLOADED $remotePath"
    } catch {
        Log "UPLOAD FAILED: $($_.Exception.Message)" 'WARN'
        if($_.ErrorDetails.Message){Log "GITHUB RESPONSE: $($_.ErrorDetails.Message)" 'WARN'}
    }
}

if(-not (Is-Admin)){Write-Host 'ERROR: Run PowerShell as Administrator.' -ForegroundColor Red;exit 1}
Log '3EN Agent Runner v3.3 started.'
Log "Task URL: $TaskUrl"
Log "Polling every $PollSeconds seconds."
$state=Load-State

while($true){
    try {
        $task=Fetch-Task $TaskUrl
        $hash=Sha256 ($task|ConvertTo-Json -Depth 20 -Compress)
        if($state.lastExecutedId -eq [string]$task.id -and $state.lastExecutedHash -eq $hash){
            Log "No new task. ID=$($task.id)"
        } else {
            Log "TASK DETECTED ID=$($task.id) SHA256=$hash"
            Show-Task $task $hash
            if((Choice '[Y] Approve task   [N] Reject task') -eq 'Y'){
                $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
                $safe=([string]$task.id)-replace '[^a-zA-Z0-9._-]','_'
                $dir=Join-Path $RunsDir "$stamp-$safe"
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
                $taskFile=Join-Path $dir 'task.json'
                $transcript=Join-Path $dir 'transcript.txt'
                $resultFile=Join-Path $dir 'result.json'
                $task|ConvertTo-Json -Depth 20|Set-Content $taskFile -Encoding UTF8
                $results=@();$overall='SUCCESS'

                if($task.PSObject.Properties.Name.Contains('backup') -and -not [string]::IsNullOrWhiteSpace([string]$task.backup)){
                    $r=Run-Step 'BACKUP' ([string]$task.backup) $transcript
                    $results+=$r
                    if($r.status-ne'OK'){$overall='FAILED_BACKUP'}
                }
                if($overall-eq'SUCCESS'){
                    $r=Run-Step 'SCRIPT' ([string]$task.script) $transcript
                    $results+=$r
                    if($r.status-ne'OK'){$overall='FAILED_SCRIPT'}
                }
                if($overall-eq'SUCCESS' -and $task.PSObject.Properties.Name.Contains('test') -and -not [string]::IsNullOrWhiteSpace([string]$task.test)){
                    $r=Run-Step 'TEST' ([string]$task.test) $transcript
                    $results+=$r
                    if($r.status-ne'OK'){$overall='FAILED_TEST'}
                }
                if($overall-ne'SUCCESS' -and $task.PSObject.Properties.Name.Contains('rollback') -and -not [string]::IsNullOrWhiteSpace([string]$task.rollback)){
                    if((Choice '[Y] Run rollback   [N] Leave as-is')-eq'Y'){$results+=Run-Step 'ROLLBACK' ([string]$task.rollback) $transcript}
                }

                Log 'FINALIZE 2/4: writing result.json'
                @($results)|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $resultFile -Encoding UTF8
                Log 'FINALIZE 2/4: result.json written'

                if($overall-eq'SUCCESS'){
                    Save-State ([string]$task.id) $hash
                    $state=Load-State
                }

                Publish-Result ([string]$task.id) $stamp $resultFile

                if($overall-eq'SUCCESS'){
                    Log 'FINALIZE 4/4: COMPLETE'
                    Write-Host ''
                    Write-Host 'TASK COMPLETE' -ForegroundColor Green
                } else {
                    Log "FINALIZE 4/4: task status $overall" 'ERROR'
                }
                Write-Host "Run directory: $dir"
            } else {Log "Task rejected by user. ID=$($task.id)" 'WARN'}
        }
    } catch {
        Log "Poll failed: $($_.Exception.Message)" 'ERROR'
    }
    Start-Sleep -Seconds $PollSeconds
}
