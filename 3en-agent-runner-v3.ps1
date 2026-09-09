# 3EN Agent Runner v3
# Windows 11 / PowerShell 7+
# Run from elevated PowerShell (Administrator).

param(
    [Parameter(Mandatory=$true)][string]$TaskUrl,
    [int]$PollSeconds = 15,
    [string]$Root = "C:\3EN-Agent",
    [string]$ResultRepo = "3en4all/3en-command-runner",
    [string]$ResultBranch = "main"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$StateFile = Join-Path $Root "3en-agent.state.json"
$LogFile   = Join-Path $Root "3en-agent.log"
$RunsDir   = Join-Path $Root "runs"
New-Item -ItemType Directory -Force -Path $Root,$RunsDir | Out-Null

function Write-AgentLog {
    param([string]$Message,[string]$Level="INFO")
    $ts=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line="[$ts][$Level] $Message"
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Test-IsAdministrator {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=[Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Sha256Text {
    param([string]$Text)
    $sha=[System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes=[Text.Encoding]::UTF8.GetBytes($Text)
        $hash=$sha.ComputeHash($bytes)
        ([BitConverter]::ToString($hash)-replace '-','').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Load-State {
    if(Test-Path $StateFile){
        try { return Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }
    [pscustomobject]@{lastExecutedId='';lastExecutedHash=''}
}

function Save-State {
    param([string]$Id,[string]$Hash)
    [ordered]@{lastExecutedId=$Id;lastExecutedHash=$Hash;updatedUtc=(Get-Date).ToUniversalTime().ToString('o')} |
        ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
}

function Get-RemoteTask {
    param([string]$Url)
    $ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $requestUrl=if($Url.Contains('?')){"${Url}&ts=$ts"}else{"${Url}?ts=$ts"}
    Write-AgentLog "Fetching task..."
    $r=Invoke-WebRequest -Uri $requestUrl -Headers @{'Cache-Control'='no-cache';Pragma='no-cache';'User-Agent'='3EN-Agent-v3'} -TimeoutSec 20
    Write-AgentLog "FETCH OK HTTP=$($r.StatusCode)"
    $task=[string]$r.Content | ConvertFrom-Json
    Write-AgentLog "PARSE OK ID=$($task.id)"
    foreach($required in @('id','title','description','script')){
        if(-not $task.PSObject.Properties.Name.Contains($required) -or [string]::IsNullOrWhiteSpace([string]$task.$required)){
            throw "Task JSON missing field: $required"
        }
    }
    $task
}

function Show-Task {
    param($Task,[string]$Hash)
    Write-Host ""
    Write-Host "====================================================================" -ForegroundColor DarkGray
    Write-Host "3EN AGENT v3 - NEW TASK" -ForegroundColor Yellow
    Write-Host "ID:          $($Task.id)"
    Write-Host "TITLE:       $($Task.title)" -ForegroundColor Cyan
    Write-Host "DESCRIPTION: $($Task.description)"
    Write-Host "SHA256:      $Hash"
    Write-Host "--------------------------------------------------------------------"
    foreach($p in @(@('BACKUP','backup','Magenta'),@('SCRIPT','script','Green'),@('TEST','test','Blue'),@('ROLLBACK','rollback','DarkYellow'))){
        if($Task.PSObject.Properties.Name.Contains($p[1])){
            $v=[string]$Task.($p[1])
            if(-not [string]::IsNullOrWhiteSpace($v)){
                Write-Host "$($p[0]):" -ForegroundColor $p[2]
                Write-Host $v
                Write-Host "--------------------------------------------------------------------"
            }
        }
    }
    Write-Host "====================================================================" -ForegroundColor DarkGray
}

function Get-KeyChoice {
    param([string]$Prompt)
    Write-Host ""
    Write-Host $Prompt -ForegroundColor Yellow
    Write-Host "Press Y or N (no Enter required)." -ForegroundColor DarkGray
    while($true){
        if([Console]::KeyAvailable){
            $k=[Console]::ReadKey($true)
            $c=[char]::ToUpperInvariant($k.KeyChar)
            if($c -in @('Y','N')){Write-Host $c;return $c}
        }
        Start-Sleep -Milliseconds 50
    }
}

function Invoke-Step {
    param([string]$Name,[string]$Code,[string]$TranscriptPath)
    if([string]::IsNullOrWhiteSpace($Code)){return [pscustomobject]@{name=$Name;status='SKIPPED';exitCode=$null;error=$null}}
    Write-Host ""; Write-Host ">>> $Name" -ForegroundColor Yellow
    try {
        $global:LASTEXITCODE=0
        $out=& ([ScriptBlock]::Create($Code)) *>&1
        $out | Tee-Object -FilePath $TranscriptPath -Append | Out-Host
        $ec=$global:LASTEXITCODE; if($null -eq $ec){$ec=0}
        if($ec -ne 0){return [pscustomobject]@{name=$Name;status='FAILED';exitCode=$ec;error="LASTEXITCODE=$ec"}}
        [pscustomobject]@{name=$Name;status='OK';exitCode=$ec;error=$null}
    } catch {
        $_ | Out-String | Add-Content $TranscriptPath -Encoding UTF8
        [pscustomobject]@{name=$Name;status='FAILED';exitCode=$global:LASTEXITCODE;error=$_.Exception.Message}
    }
}

function Publish-ResultToGitHub {
    param([string]$TaskId,[string]$RunStamp,[string]$ResultPath,[string]$TranscriptPath,[string]$OverallStatus)
    $token=[Environment]::GetEnvironmentVariable('THREEEN_GH_TOKEN','User')
    if([string]::IsNullOrWhiteSpace($token)){$token=$env:THREEEN_GH_TOKEN}
    if([string]::IsNullOrWhiteSpace($token)){
        Write-AgentLog "GitHub result upload skipped: THREEEN_GH_TOKEN is not configured." "WARN"
        return
    }

    $steps=Get-Content $ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $transcript=''
    if(Test-Path $TranscriptPath){
        $transcript=Get-Content $TranscriptPath -Raw -Encoding UTF8
        if($transcript.Length -gt 50000){$transcript=$transcript.Substring(0,50000)+"`n[TRUNCATED]"}
    }

    $payload=[ordered]@{
        taskId=$TaskId
        runStamp=$RunStamp
        computer=$env:COMPUTERNAME
        status=$OverallStatus
        completedUtc=(Get-Date).ToUniversalTime().ToString('o')
        steps=$steps
        transcript=$transcript
    } | ConvertTo-Json -Depth 20

    $safeId=$TaskId -replace '[^a-zA-Z0-9._-]','_'
    $remotePath="results/$safeId-$RunStamp.json"
    $api="https://api.github.com/repos/$ResultRepo/contents/$remotePath"
    $b64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $body=@{message="Result $TaskId $RunStamp";content=$b64;branch=$ResultBranch} | ConvertTo-Json
    $headers=@{Authorization="Bearer $token";Accept='application/vnd.github+json';'X-GitHub-Api-Version'='2022-11-28';'User-Agent'='3EN-Agent-v3'}
    Invoke-RestMethod -Method Put -Uri $api -Headers $headers -Body $body -ContentType 'application/json' | Out-Null
    Write-AgentLog "RESULT UPLOADED: $remotePath"
}

if(-not (Test-IsAdministrator)){Write-Host 'ERROR: PowerShell must run as Administrator.' -ForegroundColor Red;exit 1}
Write-AgentLog "3EN Agent Runner v3 started."
Write-AgentLog "Task URL: $TaskUrl"
Write-AgentLog "Result repo: $ResultRepo / $ResultBranch"
Write-AgentLog "Polling every $PollSeconds seconds."
$state=Load-State

while($true){
    try {
        $task=Get-RemoteTask -Url $TaskUrl
        $normalized=$task | ConvertTo-Json -Depth 20 -Compress
        $hash=Get-Sha256Text $normalized
        $already=($state.lastExecutedId -eq [string]$task.id -and $state.lastExecutedHash -eq $hash)
        if($already){
            Write-AgentLog "No new task. ID=$($task.id)"
        } else {
            Write-AgentLog "TASK DETECTED ID=$($task.id) SHA256=$hash"
            Show-Task $task $hash
            if((Get-KeyChoice '[Y] Approve task   [N] Reject task') -eq 'Y'){
                $runStamp=Get-Date -Format 'yyyyMMdd-HHmmss'
                $safeId=([string]$task.id)-replace '[^a-zA-Z0-9._-]','_'
                $runDir=Join-Path $RunsDir "$runStamp-$safeId"
                New-Item -ItemType Directory -Force -Path $runDir | Out-Null
                $taskFile=Join-Path $runDir 'task.json';$transcript=Join-Path $runDir 'transcript.txt';$resultFile=Join-Path $runDir 'result.json'
                $task | ConvertTo-Json -Depth 20 | Set-Content $taskFile -Encoding UTF8
                $results=@();$overall='SUCCESS'

                if($task.PSObject.Properties.Name.Contains('backup') -and -not [string]::IsNullOrWhiteSpace([string]$task.backup)){
                    $r=Invoke-Step 'BACKUP' ([string]$task.backup) $transcript;$results+=$r
                    if($r.status -ne 'OK'){$overall='FAILED_BACKUP'}
                }
                if($overall -eq 'SUCCESS'){
                    $r=Invoke-Step 'SCRIPT' ([string]$task.script) $transcript;$results+=$r
                    if($r.status -ne 'OK'){$overall='FAILED_SCRIPT'}
                }
                if($overall -eq 'SUCCESS' -and $task.PSObject.Properties.Name.Contains('test') -and -not [string]::IsNullOrWhiteSpace([string]$task.test)){
                    $r=Invoke-Step 'TEST' ([string]$task.test) $transcript;$results+=$r
                    if($r.status -ne 'OK'){$overall='FAILED_TEST'}
                }
                if($overall -ne 'SUCCESS' -and $task.PSObject.Properties.Name.Contains('rollback') -and -not [string]::IsNullOrWhiteSpace([string]$task.rollback)){
                    if((Get-KeyChoice '[Y] Run rollback   [N] Leave as-is') -eq 'Y'){$results+=Invoke-Step 'ROLLBACK' ([string]$task.rollback) $transcript}
                }
                $results | ConvertTo-Json -Depth 10 | Set-Content $resultFile -Encoding UTF8
                Publish-ResultToGitHub ([string]$task.id) $runStamp $resultFile $transcript $overall

                if($overall -eq 'SUCCESS'){
                    Save-State ([string]$task.id) $hash;$state=Load-State
                    Write-AgentLog "Task completed successfully. ID=$($task.id)"
                    Write-Host 'TASK COMPLETE' -ForegroundColor Green
                } else {
                    Write-AgentLog "Task finished with status $overall. ID=$($task.id)" 'ERROR'
                }
                Write-Host "Run directory: $runDir"
            } else {Write-AgentLog "Task rejected by user. ID=$($task.id)" 'WARN'}
        }
    } catch {Write-AgentLog "Poll failed: $($_.Exception.Message)" 'ERROR'}
    Start-Sleep -Seconds $PollSeconds
}
