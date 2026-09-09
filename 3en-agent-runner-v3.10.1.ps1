# 3EN Agent Runner v3.10.1 - cumulative autonomous hardening
# Windows PowerShell 5.1

param(
    [string]$ProjectPath = 'project-v3.10-full-regression.json',
    [string]$Root = 'C:\3EN-Agent',
    [string]$Repo = '3en4all/3en-command-runner',
    [string]$Branch = 'main'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RunsDir = Join-Path $Root 'runs'
$LogFile = Join-Path $Root '3en-agent.log'
$ProjectStateFile = Join-Path $Root '3en-project.state.json'
$AgentStateFile = Join-Path $Root '3en-agent.state.json'
New-Item -ItemType Directory -Force -Path $Root,$RunsDir | Out-Null

function Write-Log {
    param([string]$Message,[string]$Level='INFO')
    $line = '[{0}][{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value $line
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-OptionalString {
    param($Object,[string]$Name,[string]$Default='')
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return [string]$p.Value
}

function Get-OptionalInt {
    param($Object,[string]$Name,[int]$Default)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return [int]$p.Value
}

function Get-OptionalBool {
    param($Object,[string]$Name,[bool]$Default)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return [bool]$p.Value
}

function Get-Headers {
    $token = $env:THREEEN_GH_TOKEN
    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = [Environment]::GetEnvironmentVariable('THREEEN_GH_TOKEN','User')
    }
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'THREEEN_GH_TOKEN missing.' }
    return @{
        Authorization = 'Bearer ' + $token
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = '3EN-Agent-v3.10.1'
    }
}

function Get-RepoText {
    param([string]$Path,$Headers)
    $uri = 'https://api.github.com/repos/' + $Repo + '/contents/' + $Path + '?ref=' + $Branch + '&ts=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $Headers -TimeoutSec 20
    $b64 = ([string]$response.content).Replace("`n",'').Replace("`r",'')
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
}

function New-ProjectState {
    param([string]$ProjectId)
    return [pscustomobject]@{projectId=$ProjectId;chapterStatuses=[pscustomobject]@{};updatedUtc=$null}
}

function Load-ProjectState {
    param([string]$ProjectId)
    if (Test-Path -LiteralPath $ProjectStateFile) {
        try {
            $state = Get-Content -LiteralPath $ProjectStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$state.projectId -eq $ProjectId) { return $state }
        } catch {}
    }
    return New-ProjectState $ProjectId
}

function Save-ProjectState {
    param($State)
    $State.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $State | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $ProjectStateFile -Encoding UTF8
}

function Get-ChapterStatus {
    param($State,[string]$Id)
    $p = $State.chapterStatuses.PSObject.Properties[$Id]
    if ($null -eq $p) { return $null }
    return [string]$p.Value
}

function Set-ChapterStatus {
    param($State,[string]$Id,[string]$Status)
    $p = $State.chapterStatuses.PSObject.Properties[$Id]
    if ($null -eq $p) {
        $State.chapterStatuses | Add-Member -NotePropertyName $Id -NotePropertyValue $Status
    } else {
        $p.Value = $Status
    }
    Save-ProjectState $State
    [ordered]@{
        lastExecutedId = $Id
        lastTerminalStatus = $Status
        updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $AgentStateFile -Encoding UTF8
}

function Get-FailureClass {
    param([string]$Step,[string]$Message)
    if ($Step -like 'BACKUP*') { return 'BACKUP' }
    if ($Message -match '(?i)timeout|temporar|network|connection|HTTP\s*5\d\d|rate limit') { return 'TRANSIENT' }
    if ($Step -like 'TEST*') { return 'VALIDATION' }
    if ($Step -like 'REPAIR*') { return 'REPAIR' }
    return 'EXECUTION'
}

function Invoke-CodeStep {
    param([string]$Name,[string]$Code,[string]$Transcript,[bool]$ShowErrors)
    if ([string]::IsNullOrWhiteSpace($Code)) {
        return [pscustomobject]@{name=$Name;status='SKIPPED';failureClass='NONE';error=$null}
    }
    Write-Log ($Name + ' START')
    try {
        $output = & ([ScriptBlock]::Create($Code)) *>&1
        if ($null -ne $output) { $output | Out-String | Add-Content -LiteralPath $Transcript -Encoding UTF8 }
        Write-Log ($Name + ' OK')
        return [pscustomobject]@{name=$Name;status='OK';failureClass='NONE';error=$null}
    } catch {
        $message = $_.Exception.Message
        ($_ | Out-String) | Add-Content -LiteralPath $Transcript -Encoding UTF8
        if ($ShowErrors) { Write-Host ($_ | Out-String) -ForegroundColor Red }
        else { Write-Log ($Name + ' handled internally') 'WARN' }
        return [pscustomobject]@{name=$Name;status='FAILED';failureClass=(Get-FailureClass $Name $message);error=$message}
    }
}

function Put-TextWithRetry {
    param([string]$RemotePath,[string]$Text,[string]$Message,$Headers,[int]$Retries)
    $uri = 'https://api.github.com/repos/' + $Repo + '/contents/' + $RemotePath
    $body = @{message=$Message;content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text));branch=$Branch} | ConvertTo-Json -Compress
    for ($i=1; $i -le $Retries; $i++) {
        try {
            Invoke-RestMethod -Method Put -Uri $uri -Headers $Headers -ContentType 'application/json' -Body $body -TimeoutSec 20 | Out-Null
            return $true
        } catch {
            if ($i -lt $Retries) { Start-Sleep -Seconds ([Math]::Min(6,$i*2)) }
        }
    }
    return $false
}

function Publish-Run {
    param([string]$Id,[string]$Stamp,[string]$ResultPath,[string]$Transcript,$Headers,[int]$Retries)
    $safeId = $Id -replace '[^a-zA-Z0-9._-]','_'
    $resultText = Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8
    $outputText = ''
    if (Test-Path -LiteralPath $Transcript) { $outputText = Get-Content -LiteralPath $Transcript -Raw -Encoding UTF8 }
    $a = Put-TextWithRetry ('results/' + $safeId + '-' + $Stamp + '.json') $resultText ('v3.10.1 result ' + $Id) $Headers $Retries
    $b = Put-TextWithRetry ('results/' + $safeId + '-' + $Stamp + '.output.txt') $outputText ('v3.10.1 output ' + $Id) $Headers $Retries
    return ($a -and $b)
}

function Read-Approval {
    param([string]$Mode)
    if ($Mode -eq 'approve') { return $true }
    if ($Mode -eq 'reject') { return $false }
    Write-Host '[Y] Approve   [N] Reject' -ForegroundColor Yellow
    while ($true) {
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            $c = [char]::ToUpperInvariant($k.KeyChar)
            if ($c -eq 'Y') { return $true }
            if ($c -eq 'N') { return $false }
        }
        Start-Sleep -Milliseconds 50
    }
}

if (-not (Test-IsAdmin)) { Write-Host 'Run PowerShell as Administrator.' -ForegroundColor Yellow; exit 1 }

$headers = Get-Headers
$mutex = New-Object Threading.Mutex($false,'Global\3EN-Agent-Project-v3101')
if (-not $mutex.WaitOne(0)) { Write-Host 'Another 3EN project is active.' -ForegroundColor Yellow; exit 2 }

try {
    Write-Log '3EN Agent Runner v3.10.1 started.'
    $project = Get-RepoText $ProjectPath $headers | ConvertFrom-Json
    if ((-not $project.projectId) -or (@($project.chapters).Count -lt 1)) { throw 'Invalid project manifest.' }

    $policy = $null
    $pp = $project.PSObject.Properties['policy']
    if ($null -ne $pp) { $policy = $pp.Value }

    $defaultApproval = (Get-OptionalString $policy 'defaultApproval' 'approve').ToLowerInvariant()
    $maxAttemptsDefault = Get-OptionalInt $policy 'maxAttempts' 2
    $showErrors = Get-OptionalBool $policy 'showErrors' $false
    $autoRollback = Get-OptionalBool $policy 'autoRollbackOnFinalFailure' $true
    $continueOnFailure = Get-OptionalBool $policy 'continueOnFailure' $true
    $publishRetries = Get-OptionalInt $policy 'publishRetries' 3
    if ($publishRetries -lt 1) { $publishRetries = 1 }

    $state = Load-ProjectState ([string]$project.projectId)
    $index = 0
    $total = @($project.chapters).Count

    foreach ($chapter in @($project.chapters)) {
        $index++
        $id = [string]$chapter.id
        $expected = Get-OptionalString $chapter 'expectedStatus' ''
        $existing = Get-ChapterStatus $state $id
        if ($existing -in @('SUCCESS','SUCCESS_RECOVERED','REJECTED','FAILED_BACKUP','FAILED_SCRIPT','FAILED_TEST','FAILED_REPAIR')) {
            Write-Log ('RESUME SKIP ' + $id + ' status=' + $existing)
            continue
        }

        $path = Get-OptionalString $chapter 'path' ''
        if ([string]::IsNullOrWhiteSpace($path)) { throw ('Missing chapter path for ' + $id) }
        $task = Get-RepoText $path $headers | ConvertFrom-Json
        if ([string]$task.id -ne $id) { throw ('Manifest/task mismatch for ' + $id) }

        Write-Host ''
        Write-Host ('3EN PROJECT ' + $index + '/' + $total + '  ' + $id) -ForegroundColor Cyan
        Write-Host ([string]$task.title)

        $approval = (Get-OptionalString $chapter 'approval' $defaultApproval).ToLowerInvariant()
        if ($approval -notin @('approve','reject','prompt')) { throw ('Invalid approval mode for ' + $id) }
        $approved = Read-Approval $approval

        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $safeId = $id -replace '[^a-zA-Z0-9._-]','_'
        $runDir = Join-Path $RunsDir ($stamp + '-' + $safeId)
        New-Item -ItemType Directory -Force -Path $runDir | Out-Null
        $transcript = Join-Path $runDir 'transcript.txt'
        $resultPath = Join-Path $runDir 'result.json'
        $steps = New-Object System.Collections.Generic.List[object]

        if (-not $approved) {
            $status = 'REJECTED'
            Set-ChapterStatus $state $id $status
            [ordered]@{projectId=$project.projectId;chapterId=$id;expectedStatus=$expected;status=$status;attempts=0;steps=@()} | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $resultPath -Encoding UTF8
            [void](Publish-Run $id $stamp $resultPath $transcript $headers $publishRetries)
            continue
        }

        $backup = Get-OptionalString $task 'backup' ''
        $script = Get-OptionalString $task 'script' ''
        $test = Get-OptionalString $task 'test' ''
        $repair = Get-OptionalString $task 'repair' ''
        $rollback = Get-OptionalString $task 'rollback' ''
        $maxAttempts = Get-OptionalInt $chapter 'maxAttempts' $maxAttemptsDefault
        if ($maxAttempts -lt 1) { $maxAttempts = 1 }

        $backupStep = Invoke-CodeStep 'BACKUP' $backup $transcript $showErrors
        [void]$steps.Add($backupStep)
        $status = 'FAILED_BACKUP'
        $attemptUsed = 0

        if ($backupStep.status -eq 'OK' -or $backupStep.status -eq 'SKIPPED') {
            $lastFailureStatus = 'FAILED_SCRIPT'
            for ($attempt=1; $attempt -le $maxAttempts; $attempt++) {
                $attemptUsed = $attempt
                Write-Log ('ATTEMPT ' + $attempt + '/' + $maxAttempts + ' id=' + $id)
                $scriptStep = Invoke-CodeStep ('SCRIPT_' + $attempt) $script $transcript $showErrors
                [void]$steps.Add($scriptStep)
                if ($scriptStep.status -ne 'OK' -and $scriptStep.status -ne 'SKIPPED') {
                    $lastFailureStatus = 'FAILED_SCRIPT'
                    $ok = $false
                } else {
                    $ok = $true
                    if (-not [string]::IsNullOrWhiteSpace($test)) {
                        $testStep = Invoke-CodeStep ('TEST_' + $attempt) $test $transcript $showErrors
                        [void]$steps.Add($testStep)
                        if ($testStep.status -ne 'OK') {
                            $lastFailureStatus = 'FAILED_TEST'
                            $ok = $false
                        }
                    }
                }

                if ($ok) {
                    if ($attempt -eq 1) { $status = 'SUCCESS' } else { $status = 'SUCCESS_RECOVERED' }
                    break
                }

                $status = $lastFailureStatus
                if ($attempt -lt $maxAttempts -and -not [string]::IsNullOrWhiteSpace($repair)) {
                    $repairStep = Invoke-CodeStep ('REPAIR_' + $attempt) $repair $transcript $showErrors
                    [void]$steps.Add($repairStep)
                    if ($repairStep.status -ne 'OK') {
                        $status = 'FAILED_REPAIR'
                        break
                    }
                } else {
                    break
                }
            }
        }

        if ($status -like 'FAILED_*' -and $autoRollback -and -not [string]::IsNullOrWhiteSpace($rollback)) {
            $rollbackStep = Invoke-CodeStep 'ROLLBACK' $rollback $transcript $showErrors
            [void]$steps.Add($rollbackStep)
        }

        Set-ChapterStatus $state $id $status
        [ordered]@{
            projectId=$project.projectId
            chapterId=$id
            expectedStatus=$expected
            status=$status
            attempts=$attemptUsed
            steps=$steps.ToArray()
        } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $resultPath -Encoding UTF8

        $published = Publish-Run $id $stamp $resultPath $transcript $headers $publishRetries
        if (-not $published) { Write-Log 'Artifact publication deferred after retries.' 'WARN' }
        Write-Log ('CHAPTER TERMINAL id=' + $id + ' status=' + $status)

        if ($status -like 'FAILED_*' -and -not $continueOnFailure) { break }
    }

    $chapterSummary = New-Object System.Collections.Generic.List[object]
    $unexpected = 0
    $remaining = 0
    $recovered = 0
    $success = 0
    $rejected = 0
    $expectedFailures = 0

    foreach ($chapter in @($project.chapters)) {
        $id = [string]$chapter.id
        $expected = Get-OptionalString $chapter 'expectedStatus' ''
        $actual = Get-ChapterStatus $state $id
        $match = $false
        if ($null -ne $actual -and -not [string]::IsNullOrWhiteSpace($expected)) { $match = ($actual -eq $expected) }
        elseif ($null -ne $actual) { $match = $true }

        if ($null -eq $actual) { $remaining++ }
        elseif (-not $match) { $unexpected++ }
        elseif ($actual -eq 'SUCCESS') { $success++ }
        elseif ($actual -eq 'SUCCESS_RECOVERED') { $recovered++ }
        elseif ($actual -eq 'REJECTED') { $rejected++ }
        elseif ($actual -like 'FAILED_*') { $expectedFailures++ }

        [void]$chapterSummary.Add([pscustomobject]@{id=$id;expected=$expected;actual=$actual;match=$match})
    }

    $accepted = ($remaining -eq 0 -and $unexpected -eq 0)
    $verdict = 'SUCCESS'
    if ($accepted -and $recovered -gt 0) { $verdict = 'RECOVERED' }
    if (-not $accepted) { $verdict = 'NEEDS_DECISION' }

    $summary = [ordered]@{
        schemaVersion=1
        projectId=$project.projectId
        runnerVersion='3.10.1'
        verdict=$verdict
        accepted=$accepted
        counts=[ordered]@{success=$success;recovered=$recovered;rejected=$rejected;expectedFailures=$expectedFailures;unexpected=$unexpected;remaining=$remaining}
        chapters=$chapterSummary.ToArray()
        completedUtc=(Get-Date).ToUniversalTime().ToString('o')
    }
    $summaryText = $summary | ConvertTo-Json -Depth 30
    $localSummary = Join-Path $RunsDir ('project-' + ([string]$project.projectId) + '.summary.json')
    $summaryText | Set-Content -LiteralPath $localSummary -Encoding UTF8
    $summaryStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    [void](Put-TextWithRetry ('results/project-' + ([string]$project.projectId) + '-' + $summaryStamp + '.summary.json') $summaryText ('v3.10.1 project summary ' + [string]$project.projectId) $headers $publishRetries)

    Write-Host ''
    if ($accepted) {
        Write-Host ('PROJECT ' + $verdict) -ForegroundColor Green
        exit 0
    }
    Write-Host 'PROJECT NEEDS DECISION' -ForegroundColor Yellow
    exit 4
}
finally {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
