# 3EN Agent Runner v3.8.1 - Hardened Declarative Project Orchestrator
# Windows PowerShell 5.1 / Windows 11

param(
    [string]$ProjectPath = 'project.json',
    [string]$Root = 'C:\3EN-Agent',
    [string]$Repo = '3en4all/3en-command-runner',
    [string]$Branch = 'main'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LogFile = Join-Path $Root '3en-agent.log'
$RunsDir = Join-Path $Root 'runs'
$AgentStateFile = Join-Path $Root '3en-agent.state.json'
$ProjectStateFile = Join-Path $Root '3en-project.state.json'
New-Item -ItemType Directory -Force -Path $Root, $RunsDir | Out-Null

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[{0}][{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value $line
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Headers {
    $token = $env:THREEEN_GH_TOKEN
    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = [Environment]::GetEnvironmentVariable('THREEEN_GH_TOKEN', 'User')
    }
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'THREEEN_GH_TOKEN missing.' }
    return @{
        Authorization = 'Bearer ' + $token
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = '3EN-Agent-v3.8.1'
    }
}

function Get-RepoText {
    param([string]$Path, $Headers)
    $uri = 'https://api.github.com/repos/' + $Repo + '/contents/' + $Path + '?ref=' + $Branch + '&ts=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $Headers -TimeoutSec 20
    $b64 = ([string]$response.content).Replace("`n", '').Replace("`r", '')
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
}

function Get-OptionalBool {
    param($Object, [string]$Name, [bool]$Default)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return [bool]$property.Value
}

function Get-OptionalString {
    param($Object, [string]$Name, [string]$Default = '')
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return [string]$property.Value
}

function Save-AgentState {
    param([string]$Id, [string]$Status)
    [ordered]@{
        lastExecutedId = $Id
        lastTerminalStatus = $Status
        updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $AgentStateFile -Encoding UTF8
    Write-Log ('STATE SAVED id=' + $Id + ' status=' + $Status)
}

function New-ProjectState {
    param([string]$ProjectId)
    return [pscustomobject]@{
        projectId = $ProjectId
        chapterStatuses = [pscustomobject]@{}
        updatedUtc = $null
    }
}

function Load-ProjectState {
    param([string]$ProjectId)
    if (Test-Path -LiteralPath $ProjectStateFile) {
        try {
            $state = Get-Content -LiteralPath $ProjectStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$state.projectId -eq $ProjectId) { return $state }
        } catch {
            Write-Log 'Existing project state ignored.' 'WARN'
        }
    }
    return New-ProjectState $ProjectId
}

function Save-ProjectState {
    param($State)
    $State.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $State | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ProjectStateFile -Encoding UTF8
}

function Get-ChapterStatus {
    param($State, [string]$Id)
    $property = $State.chapterStatuses.PSObject.Properties[$Id]
    if ($null -eq $property) { return $null }
    return [string]$property.Value
}

function Set-ChapterStatus {
    param($State, [string]$Id, [string]$Status)
    $property = $State.chapterStatuses.PSObject.Properties[$Id]
    if ($null -eq $property) {
        $State.chapterStatuses | Add-Member -NotePropertyName $Id -NotePropertyValue $Status
    } else {
        $property.Value = $Status
    }
    Save-ProjectState $State
    Save-AgentState $Id $Status
}

function Read-Choice {
    param([string]$Prompt)
    Write-Host ''
    Write-Host $Prompt -ForegroundColor Yellow
    Write-Host 'Press Y or N (no Enter required).' -ForegroundColor DarkGray
    while ($true) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            $char = [char]::ToUpperInvariant($key.KeyChar)
            if ($char -in @('Y', 'N')) {
                Write-Host $char
                return $char
            }
        }
        Start-Sleep -Milliseconds 50
    }
}

function Run-Step {
    param([string]$Name, [string]$Code, [string]$Transcript)
    if ([string]::IsNullOrWhiteSpace($Code)) {
        return [pscustomobject]@{ name = $Name; status = 'SKIPPED'; error = $null }
    }
    Write-Host ''
    Write-Host ('>>> ' + $Name) -ForegroundColor Yellow
    Write-Log ($Name + ' START')
    try {
        $output = & ([ScriptBlock]::Create($Code)) *>&1
        if ($null -ne $output) {
            $output | Tee-Object -FilePath $Transcript -Append | Out-Host
        }
        Write-Log ($Name + ' STEP RETURNED')
        return [pscustomobject]@{ name = $Name; status = 'OK'; error = $null }
    } catch {
        $_ | Out-String | Add-Content -LiteralPath $Transcript -Encoding UTF8
        Write-Log ($Name + ' FAILED') 'ERROR'
        return [pscustomobject]@{ name = $Name; status = 'FAILED'; error = $_.Exception.Message }
    }
}

function Put-Text {
    param([string]$RemotePath, [string]$Text, [string]$Message, $Headers)
    $uri = 'https://api.github.com/repos/' + $Repo + '/contents/' + $RemotePath
    $body = @{
        message = $Message
        content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
        branch = $Branch
    } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Put -Uri $uri -Headers $Headers -ContentType 'application/json' -Body $body -TimeoutSec 20 | Out-Null
}

function Publish-Run {
    param([string]$Id, [string]$Stamp, [string]$ResultPath, [string]$Transcript, $Headers)
    try {
        $safeId = $Id -replace '[^a-zA-Z0-9._-]', '_'
        $resultText = Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8
        $outputText = ''
        if (Test-Path -LiteralPath $Transcript) {
            $outputText = Get-Content -LiteralPath $Transcript -Raw -Encoding UTF8
        }
        Put-Text ('results/' + $safeId + '-' + $Stamp + '.json') $resultText ('Project result ' + $Id + ' ' + $Stamp) $Headers
        Put-Text ('results/' + $safeId + '-' + $Stamp + '.output.txt') $outputText ('Project output ' + $Id + ' ' + $Stamp) $Headers
        Write-Log 'RESULT + OUTPUT UPLOADED'
    } catch {
        Write-Log 'RESULT UPLOAD FAILED' 'WARN'
    }
}

function New-RunFiles {
    param([string]$Id, [string]$Stamp)
    $safeId = $Id -replace '[^a-zA-Z0-9._-]', '_'
    $directory = Join-Path $RunsDir ($Stamp + '-' + $safeId)
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    return [pscustomobject]@{
        directory = $directory
        transcript = Join-Path $directory 'transcript.txt'
        result = Join-Path $directory 'result.json'
    }
}

function Write-Result {
    param([string]$ProjectId, [string]$ChapterId, [string]$Status, [string]$Stamp, $Steps, [string]$ResultPath)
    [ordered]@{
        projectId = $ProjectId
        chapterId = $ChapterId
        status = $Status
        startedLocal = $Stamp
        steps = @($Steps)
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
}

function Resolve-Approval {
    param($Chapter)
    $mode = (Get-OptionalString $Chapter 'approval' 'prompt').ToLowerInvariant()
    if ($mode -notin @('prompt', 'approve', 'reject')) {
        throw ('Invalid approval mode for ' + [string]$Chapter.id)
    }
    return $mode
}

if (-not (Test-IsAdmin)) {
    Write-Host 'ERROR: Run PowerShell as Administrator.' -ForegroundColor Red
    exit 1
}

$headers = Get-Headers
$mutex = New-Object Threading.Mutex($false, 'Global\3EN-Agent-Project-v381')
if (-not $mutex.WaitOne(0)) {
    Write-Host 'ERROR: another v3.8.1 project runner is active.' -ForegroundColor Red
    exit 2
}

try {
    Write-Log '3EN Agent Runner v3.8.1 started.'
    $project = Get-RepoText $ProjectPath $headers | ConvertFrom-Json
    if ((-not $project.projectId) -or (@($project.chapters).Count -lt 1)) { throw 'Invalid project manifest.' }

    $policy = $project.PSObject.Properties['policy']
    $policyValue = $null
    if ($null -ne $policy) { $policyValue = $policy.Value }

    $continueOnSuccess = Get-OptionalBool $policyValue 'continueOnSuccess' $true
    $continueOnFailure = Get-OptionalBool $policyValue 'continueOnFailure' $true
    $continueOnRejected = Get-OptionalBool $policyValue 'continueOnRejected' $true
    $autoRollbackOnFailure = Get-OptionalBool $policyValue 'autoRollbackOnFailure' $true

    Write-Log ('PROJECT LOADED id=' + [string]$project.projectId + ' chapters=' + @($project.chapters).Count)
    $state = Load-ProjectState ([string]$project.projectId)
    $total = @($project.chapters).Count
    $index = 0
    $acceptanceFailed = $false

    foreach ($chapter in @($project.chapters)) {
        $index++
        $id = [string]$chapter.id
        $existing = Get-ChapterStatus $state $id
        if ($existing -in @('SUCCESS', 'FAILED_BACKUP', 'FAILED_SCRIPT', 'FAILED_TEST', 'REJECTED')) {
            Write-Log ('PROJECT SKIP terminal chapter ' + $id + ' status=' + $existing)
            continue
        }

        $chapterPath = Get-OptionalString $chapter 'path' ''
        if ([string]::IsNullOrWhiteSpace($chapterPath)) { throw ('Missing chapter path for ' + $id) }
        $task = Get-RepoText $chapterPath $headers | ConvertFrom-Json
        if ([string]$task.id -ne $id) { throw ('Manifest/task id mismatch for ' + $id) }

        Write-Host ''
        Write-Host '====================================================================' -ForegroundColor DarkGray
        Write-Host ('3EN AGENT v3.8.1 - PROJECT CHAPTER ' + $index + '/' + $total) -ForegroundColor Yellow
        Write-Host ('ID:    ' + [string]$task.id)
        Write-Host ('TITLE: ' + [string]$task.title) -ForegroundColor Cyan
        Write-Host '====================================================================' -ForegroundColor DarkGray

        $approvalMode = Resolve-Approval $chapter
        $approved = $true
        if ($approvalMode -eq 'reject') {
            $approved = $false
            Write-Log ('DECLARATIVE REJECT ' + $id)
        } elseif ($approvalMode -eq 'approve') {
            Write-Log ('DECLARATIVE APPROVE ' + $id)
        } else {
            $approved = ((Read-Choice '[Y] Approve chapter   [N] Reject chapter') -eq 'Y')
        }

        $expectedStatus = Get-OptionalString $chapter 'expectedStatus' ''

        if (-not $approved) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $files = New-RunFiles $id $stamp
            Write-Result ([string]$project.projectId) $id 'REJECTED' $stamp @() $files.result
            Set-ChapterStatus $state $id 'REJECTED'
            Publish-Run $id $stamp $files.result $files.transcript $headers
            Write-Log ('CHAPTER TERMINAL id=' + $id + ' status=REJECTED')
            if ((-not [string]::IsNullOrWhiteSpace($expectedStatus)) -and ($expectedStatus -ne 'REJECTED')) {
                $acceptanceFailed = $true
                Write-Log ('EXPECTED STATUS MISMATCH id=' + $id) 'ERROR'
            }
            if (-not $continueOnRejected) { break }
            continue
        }

        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $files = New-RunFiles $id $stamp
        $steps = New-Object System.Collections.Generic.List[object]
        $overall = 'SUCCESS'

        $backupCode = Get-OptionalString $task 'backup' ''
        $scriptCode = Get-OptionalString $task 'script' ''
        $testCode = Get-OptionalString $task 'test' ''
        $rollbackCode = Get-OptionalString $task 'rollback' ''

        if (-not [string]::IsNullOrWhiteSpace($backupCode)) {
            $step = Run-Step 'BACKUP' $backupCode $files.transcript
            [void]$steps.Add($step)
            if ($step.status -ne 'OK') { $overall = 'FAILED_BACKUP' }
        }
        if ($overall -eq 'SUCCESS') {
            $step = Run-Step 'SCRIPT' $scriptCode $files.transcript
            [void]$steps.Add($step)
            if ($step.status -ne 'OK') { $overall = 'FAILED_SCRIPT' }
        }
        if (($overall -eq 'SUCCESS') -and (-not [string]::IsNullOrWhiteSpace($testCode))) {
            $step = Run-Step 'TEST' $testCode $files.transcript
            [void]$steps.Add($step)
            if ($step.status -ne 'OK') { $overall = 'FAILED_TEST' }
        }
        if (($overall -ne 'SUCCESS') -and (-not [string]::IsNullOrWhiteSpace($rollbackCode))) {
            if ($autoRollbackOnFailure) {
                $step = Run-Step 'ROLLBACK' $rollbackCode $files.transcript
                [void]$steps.Add($step)
            } else {
                if ((Read-Choice '[Y] Run rollback   [N] Leave as-is') -eq 'Y') {
                    $step = Run-Step 'ROLLBACK' $rollbackCode $files.transcript
                    [void]$steps.Add($step)
                }
            }
        }

        Write-Result ([string]$project.projectId) $id $overall $stamp $steps.ToArray() $files.result
        Set-ChapterStatus $state $id $overall
        Publish-Run $id $stamp $files.result $files.transcript $headers
        Write-Log ('CHAPTER TERMINAL id=' + $id + ' status=' + $overall)
        Write-Host ('CHAPTER COMPLETE: ' + $id + ' -> ' + $overall) -ForegroundColor Green

        if ((-not [string]::IsNullOrWhiteSpace($expectedStatus)) -and ($expectedStatus -ne $overall)) {
            $acceptanceFailed = $true
            Write-Log ('EXPECTED STATUS MISMATCH id=' + $id) 'ERROR'
        }

        if ($overall -eq 'SUCCESS') {
            if (-not $continueOnSuccess) { break }
        } else {
            if (-not $continueOnFailure) { break }
        }
    }

    $remaining = 0
    foreach ($chapter in @($project.chapters)) {
        $status = Get-ChapterStatus $state ([string]$chapter.id)
        if ($status -notin @('SUCCESS', 'FAILED_BACKUP', 'FAILED_SCRIPT', 'FAILED_TEST', 'REJECTED')) {
            $remaining++
        }
    }

    if (($remaining -eq 0) -and (-not $acceptanceFailed)) {
        Write-Log ('PROJECT ACCEPTED id=' + [string]$project.projectId)
        Write-Host 'PROJECT ACCEPTED' -ForegroundColor Green
        exit 0
    }
    if ($remaining -eq 0) {
        Write-Log ('PROJECT COMPLETE BUT ACCEPTANCE FAILED id=' + [string]$project.projectId) 'ERROR'
        exit 4
    }
    Write-Log ('PROJECT STOPPED remaining=' + $remaining) 'WARN'
    exit 3
} finally {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
