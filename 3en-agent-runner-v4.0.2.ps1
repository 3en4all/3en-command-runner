# 3EN Agent Runner v4.0.2 - Autonomous Core
# Clean Windows PowerShell 5.1 rewrite
param(
    [string]$ProjectPath = 'project-v4.0-acceptance.json',
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

function Get-Prop {
    param($Object,[string]$Name,$Default=$null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}

function Get-Headers {
    $token = $env:THREEEN_GH_TOKEN
    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = [Environment]::GetEnvironmentVariable('THREEEN_GH_TOKEN','User')
    }
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'TOKEN_MISSING' }
    return @{
        Authorization = 'Bearer ' + $token
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = '3EN-Agent-v4.0.2'
    }
}

function Get-RepoText {
    param([string]$Path,$Headers)
    $uri = 'https://api.github.com/repos/' + $Repo + '/contents/' + $Path + '?ref=' + $Branch + '&ts=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $Headers -TimeoutSec 20
    $b64 = ([string]$response.content).Replace("`r",'').Replace("`n",'')
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
}

function New-State {
    param([string]$ProjectId)
    return [pscustomobject]@{ projectId=$ProjectId; chapters=[pscustomobject]@{}; updatedUtc=$null }
}

function Load-State {
    param([string]$ProjectId)
    if (Test-Path -LiteralPath $ProjectStateFile) {
        try {
            $state = Get-Content -LiteralPath $ProjectStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$state.projectId -eq $ProjectId) { return $state }
        } catch {}
    }
    return New-State $ProjectId
}

function Save-State {
    param($State)
    $State.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $State | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $ProjectStateFile -Encoding UTF8
}

function Get-ChapterState {
    param($State,[string]$Id)
    $p = $State.chapters.PSObject.Properties[$Id]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Set-ChapterState {
    param($State,[string]$Id,[string]$Status,[string]$Stage,[int]$Attempt)
    $value = [pscustomobject]@{
        status = $Status
        stage = $Stage
        attempt = $Attempt
        updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    $p = $State.chapters.PSObject.Properties[$Id]
    if ($null -eq $p) {
        $State.chapters | Add-Member -NotePropertyName $Id -NotePropertyValue $value
    } else {
        $p.Value = $value
    }
    Save-State $State
    if ($Status -in @('SUCCESS','SUCCESS_RECOVERED','REJECTED','FAILED','BLOCKED')) {
        [ordered]@{
            lastExecutedId = $Id
            lastTerminalStatus = $Status
            updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath $AgentStateFile -Encoding UTF8
    }
}

function Invoke-Step {
    param([string]$Name,[string]$Code,[string]$Transcript,[bool]$ShowErrors)
    if ([string]::IsNullOrWhiteSpace($Code)) {
        return [pscustomobject]@{ name=$Name; status='SKIPPED'; error=$null }
    }
    Write-Log ($Name + ' START')
    try {
        $output = & ([ScriptBlock]::Create($Code)) *>&1
        if ($null -ne $output) {
            $output | Out-String | Add-Content -LiteralPath $Transcript -Encoding UTF8
        }
        Write-Log ($Name + ' OK')
        return [pscustomobject]@{ name=$Name; status='OK'; error=$null }
    } catch {
        ($_ | Out-String) | Add-Content -LiteralPath $Transcript -Encoding UTF8
        if ($ShowErrors) { Write-Host ($_ | Out-String) -ForegroundColor Red }
        else { Write-Log ($Name + ' handled internally') 'WARN' }
        return [pscustomobject]@{ name=$Name; status='FAILED'; error=$_.Exception.Message }
    }
}

function Put-Text {
    param([string]$RemotePath,[string]$Text,[string]$Message,$Headers,[int]$Retries)
    $uri = 'https://api.github.com/repos/' + $Repo + '/contents/' + $RemotePath
    $body = @{
        message = $Message
        content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
        branch = $Branch
    } | ConvertTo-Json -Compress
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Invoke-RestMethod -Method Put -Uri $uri -Headers $Headers -ContentType 'application/json' -Body $body -TimeoutSec 20 | Out-Null
            return $true
        } catch {
            if ($i -lt $Retries) { Start-Sleep -Seconds ([Math]::Min(6,$i*2)) }
        }
    }
    return $false
}

function Publish-Chapter {
    param([string]$Id,[string]$Stamp,[string]$ResultPath,[string]$Transcript,$Headers,[int]$Retries)
    $safeId = $Id -replace '[^a-zA-Z0-9._-]','_'
    $resultText = Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8
    $outputText = ''
    if (Test-Path -LiteralPath $Transcript) {
        $outputText = Get-Content -LiteralPath $Transcript -Raw -Encoding UTF8
    }
    $a = Put-Text ('results/' + $safeId + '-' + $Stamp + '.json') $resultText ('v4.0.2 result ' + $Id) $Headers $Retries
    $b = Put-Text ('results/' + $safeId + '-' + $Stamp + '.output.txt') $outputText ('v4.0.2 output ' + $Id) $Headers $Retries
    return ($a -and $b)
}

function Test-Terminal {
    param([string]$Status)
    return ($Status -in @('SUCCESS','SUCCESS_RECOVERED','REJECTED','FAILED','BLOCKED'))
}

if (-not (Test-IsAdmin)) { Write-Host '3EN requires Administrator.' -ForegroundColor Yellow; exit 1 }
$headers = Get-Headers
$mutex = New-Object Threading.Mutex($false,'Global\3EN-Agent-Project-v402')
if (-not $mutex.WaitOne(0)) { Write-Host '3EN project already active.' -ForegroundColor Yellow; exit 2 }

try {
    Write-Log '3EN Agent Runner v4.0.2 started'
    $project = Get-RepoText $ProjectPath $headers | ConvertFrom-Json
    $projectId = [string](Get-Prop $project 'projectId' '')
    $chapters = @(Get-Prop $project 'chapters' @())
    if ([string]::IsNullOrWhiteSpace($projectId) -or $chapters.Count -lt 1) { throw 'PRECHECK_FAILED' }

    $policy = Get-Prop $project 'policy' $null
    $showErrors = [bool](Get-Prop $policy 'showErrors' $false)
    $maxDefault = [int](Get-Prop $policy 'maxAttempts' 2)
    $publishRetries = [int](Get-Prop $policy 'publishRetries' 3)
    $autoRollback = [bool](Get-Prop $policy 'autoRollbackOnFinalFailure' $true)
    $highRiskAction = ([string](Get-Prop $policy 'highRiskAction' 'reject')).ToLowerInvariant()
    if ($publishRetries -lt 1) { $publishRetries = 1 }
    if ($highRiskAction -notin @('reject','approve','prompt')) { throw 'PRECHECK_FAILED' }

    $allowedRisk = @('low','medium','high')
    $allowedExpected = @('SUCCESS','SUCCESS_RECOVERED','REJECTED','FAILED','BLOCKED')
    $seen = @{}
    $taskCache = @{}

    foreach ($chapter in $chapters) {
        $id = [string](Get-Prop $chapter 'id' '')
        $path = [string](Get-Prop $chapter 'path' '')
        $expected = [string](Get-Prop $chapter 'expectedStatus' 'SUCCESS')
        if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($path) -or $seen.ContainsKey($id)) { throw 'PRECHECK_FAILED' }
        if ($expected -notin $allowedExpected) { throw 'PRECHECK_FAILED' }
        $seen[$id] = $true
        $task = Get-RepoText $path $headers | ConvertFrom-Json
        if ([string](Get-Prop $task 'id' '') -ne $id) { throw 'PRECHECK_FAILED' }
        $risk = ([string](Get-Prop $task 'risk' 'low')).ToLowerInvariant()
        if ($risk -notin $allowedRisk) { throw 'PRECHECK_FAILED' }
        foreach ($dep in @(Get-Prop $chapter 'dependsOn' @())) {
            $depId = [string](Get-Prop $dep 'id' '')
            $depStatus = [string](Get-Prop $dep 'status' 'SUCCESS')
            if ([string]::IsNullOrWhiteSpace($depId) -or $depStatus -notin $allowedExpected) { throw 'PRECHECK_FAILED' }
        }
        $taskCache[$id] = $task
    }

    foreach ($chapter in $chapters) {
        foreach ($dep in @(Get-Prop $chapter 'dependsOn' @())) {
            if (-not $seen.ContainsKey([string](Get-Prop $dep 'id' ''))) { throw 'PRECHECK_FAILED' }
        }
    }

    Write-Log ('PRECHECK PASS chapters=' + $chapters.Count)
    $state = Load-State $projectId
    $mismatch = $false
    $counts = [ordered]@{ success=0; recovered=0; rejected=0; failed=0; blocked=0 }

    foreach ($chapter in $chapters) {
        $id = [string]$chapter.id
        $expected = [string](Get-Prop $chapter 'expectedStatus' 'SUCCESS')
        $existing = Get-ChapterState $state $id
        if ($null -ne $existing -and (Test-Terminal ([string]$existing.status))) {
            Write-Log ('RESUME SKIP ' + $id + ' status=' + [string]$existing.status)
            continue
        }

        $depsOk = $true
        foreach ($dep in @(Get-Prop $chapter 'dependsOn' @())) {
            $depState = Get-ChapterState $state ([string]$dep.id)
            if ($null -eq $depState -or [string]$depState.status -ne [string]$dep.status) {
                $depsOk = $false
                break
            }
        }
        if (-not $depsOk) {
            Set-ChapterState $state $id 'BLOCKED' 'DEPENDENCY' 0
            Write-Log ('CHAPTER TERMINAL id=' + $id + ' status=BLOCKED')
            $counts.blocked++
            if ($expected -ne 'BLOCKED') { $mismatch = $true }
            continue
        }

        $task = $taskCache[$id]
        $risk = ([string](Get-Prop $task 'risk' 'low')).ToLowerInvariant()
        $approval = 'approve'
        if ($risk -eq 'high') { $approval = $highRiskAction }
        if ($approval -eq 'prompt') {
            Write-Host '[Y] approve high-risk chapter [N] reject' -ForegroundColor Yellow
            while ($true) {
                $key = [Console]::ReadKey($true)
                if ($key.KeyChar -eq 'y' -or $key.KeyChar -eq 'Y') { $approval = 'approve'; break }
                if ($key.KeyChar -eq 'n' -or $key.KeyChar -eq 'N') { $approval = 'reject'; break }
            }
        }

        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $runDir = Join-Path $RunsDir ($stamp + '-' + $id)
        New-Item -ItemType Directory -Force -Path $runDir | Out-Null
        $transcript = Join-Path $runDir 'transcript.txt'
        $resultPath = Join-Path $runDir 'result.json'
        $steps = New-Object System.Collections.Generic.List[object]

        if ($approval -eq 'reject') {
            Set-ChapterState $state $id 'REJECTED' 'RISK_POLICY' 0
            [ordered]@{ projectId=$projectId; chapterId=$id; risk=$risk; status='REJECTED'; stage='RISK_POLICY'; attempts=0; steps=@() } |
                ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultPath -Encoding UTF8
            [void](Publish-Chapter $id $stamp $resultPath $transcript $headers $publishRetries)
            Write-Log ('CHAPTER TERMINAL id=' + $id + ' status=REJECTED')
            $counts.rejected++
            if ($expected -ne 'REJECTED') { $mismatch = $true }
            continue
        }

        $backup = [string](Get-Prop $task 'backup' '')
        $script = [string](Get-Prop $task 'script' '')
        $test = [string](Get-Prop $task 'test' '')
        $repair = [string](Get-Prop $task 'repair' '')
        $rollback = [string](Get-Prop $task 'rollback' '')
        $maxAttempts = [int](Get-Prop $chapter 'maxAttempts' $maxDefault)
        if ($maxAttempts -lt 1) { $maxAttempts = 1 }

        Set-ChapterState $state $id 'RUNNING' 'BACKUP_PENDING' 0
        $backupStep = Invoke-Step 'BACKUP' $backup $transcript $showErrors
        [void]$steps.Add($backupStep)
        $status = 'FAILED'
        $attemptUsed = 0

        if ($backupStep.status -ne 'FAILED') {
            Set-ChapterState $state $id 'RUNNING' 'BACKUP_DONE' 0
            for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                $attemptUsed = $attempt
                Set-ChapterState $state $id 'RUNNING' 'SCRIPT_PENDING' $attempt
                $scriptStep = Invoke-Step ('SCRIPT_' + $attempt) $script $transcript $showErrors
                [void]$steps.Add($scriptStep)
                $ok = ($scriptStep.status -eq 'OK' -or $scriptStep.status -eq 'SKIPPED')

                if ($ok -and -not [string]::IsNullOrWhiteSpace($test)) {
                    Set-ChapterState $state $id 'RUNNING' 'TEST_PENDING' $attempt
                    $testStep = Invoke-Step ('TEST_' + $attempt) $test $transcript $showErrors
                    [void]$steps.Add($testStep)
                    $ok = ($testStep.status -eq 'OK')
                }

                if ($ok) {
                    if ($attempt -eq 1) { $status = 'SUCCESS' } else { $status = 'SUCCESS_RECOVERED' }
                    break
                }

                if ($attempt -lt $maxAttempts -and -not [string]::IsNullOrWhiteSpace($repair)) {
                    Set-ChapterState $state $id 'RUNNING' 'REPAIR_PENDING' $attempt
                    $repairStep = Invoke-Step ('REPAIR_' + $attempt) $repair $transcript $showErrors
                    [void]$steps.Add($repairStep)
                    if ($repairStep.status -ne 'OK') { break }
                } else {
                    break
                }
            }
        }

        if ($status -eq 'FAILED' -and $autoRollback -and -not [string]::IsNullOrWhiteSpace($rollback)) {
            Set-ChapterState $state $id 'RUNNING' 'ROLLBACK_PENDING' $attemptUsed
            $rollbackStep = Invoke-Step 'ROLLBACK' $rollback $transcript $showErrors
            [void]$steps.Add($rollbackStep)
        }

        Set-ChapterState $state $id $status 'TERMINAL' $attemptUsed
        [ordered]@{
            projectId=$projectId
            chapterId=$id
            risk=$risk
            status=$status
            stage='TERMINAL'
            attempts=$attemptUsed
            steps=$steps.ToArray()
        } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $resultPath -Encoding UTF8
        [void](Publish-Chapter $id $stamp $resultPath $transcript $headers $publishRetries)
        Write-Log ('CHAPTER TERMINAL id=' + $id + ' status=' + $status)

        if ($status -eq 'SUCCESS') { $counts.success++ }
        elseif ($status -eq 'SUCCESS_RECOVERED') { $counts.recovered++ }
        else { $counts.failed++ }
        if ($expected -ne $status) { $mismatch = $true }
    }

    $remaining = 0
    foreach ($chapter in $chapters) {
        $cs = Get-ChapterState $state ([string]$chapter.id)
        if ($null -eq $cs -or -not (Test-Terminal ([string]$cs.status))) { $remaining++ }
    }

    $accepted = (-not $mismatch -and $remaining -eq 0)
    $verdict = 'SUCCESS'
    if ($counts.recovered -gt 0) { $verdict = 'RECOVERED' }
    if (-not $accepted) { $verdict = 'NEEDS_DECISION' }

    $summary = [ordered]@{
        schemaVersion=3
        projectId=$projectId
        runnerVersion='4.0.2'
        verdict=$verdict
        accepted=$accepted
        counts=$counts
        remaining=$remaining
        completedUtc=(Get-Date).ToUniversalTime().ToString('o')
    }
    $summaryText = $summary | ConvertTo-Json -Depth 20
    $summaryLocal = Join-Path $RunsDir ('project-' + $projectId + '.summary.json')
    $summaryText | Set-Content -LiteralPath $summaryLocal -Encoding UTF8
    $summaryStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    [void](Put-Text ('results/project-' + $projectId + '-' + $summaryStamp + '.summary.json') $summaryText ('v4.0.2 project summary ' + $projectId) $headers $publishRetries)

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
