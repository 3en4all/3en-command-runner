# 3EN Agent Runner v3.9 - Self-Healing Autonomous Project Runner
# Windows PowerShell 5.1 / Windows 11

param(
    [string]$ProjectPath = 'project-v3.9-acceptance.json',
    [string]$Root = 'C:\3EN-Agent',
    [string]$Repo = '3en4all/3en-command-runner',
    [string]$Branch = 'main'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RunsDir = Join-Path $Root 'runs'
$BackupsDir = Join-Path $Root 'backups'
$LogFile = Join-Path $Root '3en-agent.log'
$ProjectStateFile = Join-Path $Root '3en-project.state.json'
$AgentStateFile = Join-Path $Root '3en-agent.state.json'
New-Item -ItemType Directory -Force -Path $Root,$RunsDir,$BackupsDir | Out-Null

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

function Get-Headers {
    $token = $env:THREEEN_GH_TOKEN
    if ([string]::IsNullOrWhiteSpace($token)) { $token = [Environment]::GetEnvironmentVariable('THREEEN_GH_TOKEN','User') }
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'THREEEN_GH_TOKEN missing.' }
    return @{
        Authorization = 'Bearer ' + $token
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = '3EN-Agent-v3.9'
    }
}

function Get-RepoText {
    param([string]$Path,$Headers)
    $uri = 'https://api.github.com/repos/' + $Repo + '/contents/' + $Path + '?ref=' + $Branch + '&ts=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $Headers -TimeoutSec 20
    $b64 = ([string]$response.content).Replace("`n",'').Replace("`r",'')
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
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
    $State | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ProjectStateFile -Encoding UTF8
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
    if ($null -eq $p) { $State.chapterStatuses | Add-Member -NotePropertyName $Id -NotePropertyValue $Status }
    else { $p.Value = $Status }
    Save-ProjectState $State
    [ordered]@{lastExecutedId=$Id;lastTerminalStatus=$Status;updatedUtc=(Get-Date).ToUniversalTime().ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $AgentStateFile -Encoding UTF8
}

function New-RunFiles {
    param([string]$Id,[string]$Stamp)
    $safeId = $Id -replace '[^a-zA-Z0-9._-]','_'
    $dir = Join-Path $RunsDir ($Stamp + '-' + $safeId)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return [pscustomobject]@{dir=$dir;transcript=(Join-Path $dir 'transcript.txt');result=(Join-Path $dir 'result.json')}
}

function Invoke-CodeStep {
    param([string]$Name,[string]$Code,[string]$Transcript,[bool]$ShowErrors)
    if ([string]::IsNullOrWhiteSpace($Code)) { return [pscustomobject]@{name=$Name;status='SKIPPED';error=$null} }
    Write-Log ($Name + ' START')
    try {
        $output = & ([ScriptBlock]::Create($Code)) *>&1
        if ($null -ne $output) { $output | Out-String | Add-Content -LiteralPath $Transcript -Encoding UTF8 }
        Write-Log ($Name + ' OK')
        return [pscustomobject]@{name=$Name;status='OK';error=$null}
    } catch {
        $detail = $_ | Out-String
        $detail | Add-Content -LiteralPath $Transcript -Encoding UTF8
        if ($ShowErrors) { Write-Host $detail -ForegroundColor Red } else { Write-Log ($Name + ' requires recovery') 'WARN' }
        return [pscustomobject]@{name=$Name;status='FAILED';error=$_.Exception.Message}
    }
}

function Put-Text {
    param([string]$RemotePath,[string]$Text,[string]$Message,$Headers)
    $uri = 'https://api.github.com/repos/' + $Repo + '/contents/' + $RemotePath
    $body = @{message=$Message;content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text));branch=$Branch} | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Put -Uri $uri -Headers $Headers -ContentType 'application/json' -Body $body -TimeoutSec 20 | Out-Null
}

function Publish-Run {
    param([string]$Id,[string]$Stamp,[string]$ResultPath,[string]$Transcript,$Headers)
    try {
        $safeId = $Id -replace '[^a-zA-Z0-9._-]','_'
        $resultText = Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8
        $outputText = ''
        if (Test-Path -LiteralPath $Transcript) { $outputText = Get-Content -LiteralPath $Transcript -Raw -Encoding UTF8 }
        Put-Text ('results/' + $safeId + '-' + $Stamp + '.json') $resultText ('v3.9 result ' + $Id + ' ' + $Stamp) $Headers
        Put-Text ('results/' + $safeId + '-' + $Stamp + '.output.txt') $outputText ('v3.9 output ' + $Id + ' ' + $Stamp) $Headers
        Write-Log 'RESULT PUBLISHED'
    } catch { Write-Log 'RESULT PUBLISH DEFERRED' 'WARN' }
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
$mutex = New-Object Threading.Mutex($false,'Global\3EN-Agent-Project-v39')
if (-not $mutex.WaitOne(0)) { Write-Host 'Another project run is active.' -ForegroundColor Yellow; exit 2 }

try {
    Write-Log '3EN Agent Runner v3.9 started.'
    $project = Get-RepoText $ProjectPath $headers | ConvertFrom-Json
    if ((-not $project.projectId) -or (@($project.chapters).Count -lt 1)) { throw 'Invalid project manifest.' }

    $policy = $null
    $policyProperty = $project.PSObject.Properties['policy']
    if ($null -ne $policyProperty) { $policy = $policyProperty.Value }

    $defaultApproval = (Get-OptionalString $policy 'defaultApproval' 'approve').ToLowerInvariant()
    $maxAttemptsDefault = Get-OptionalInt $policy 'maxAttempts' 2
    $autoRollback = Get-OptionalBool $policy 'autoRollbackOnFinalFailure' $true
    $continueOnFailure = Get-OptionalBool $policy 'continueOnFailure' $true
    $showErrors = Get-OptionalBool $policy 'showErrors' $false

    $state = Load-ProjectState ([string]$project.projectId)
    $acceptanceFailed = $false
    $index = 0
    $total = @($project.chapters).Count

    foreach ($chapter in @($project.chapters)) {
        $index++
        $id = [string]$chapter.id
        $existing = Get-ChapterStatus $state $id
        if ($existing -in @('SUCCESS','SUCCESS_RECOVERED','REJECTED','FAILED')) {
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
        $expected = Get-OptionalString $chapter 'expectedStatus' ''
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $files = New-RunFiles $id $stamp
        $steps = New-Object System.Collections.Generic.List[object]

        if (-not $approved) {
            $status = 'REJECTED'
            Set-ChapterStatus $state $id $status
            [ordered]@{projectId=$project.projectId;chapterId=$id;status=$status;attempts=0;steps=@()} | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $files.result -Encoding UTF8
            Publish-Run $id $stamp $files.result $files.transcript $headers
            if ((-not [string]::IsNullOrWhiteSpace($expected)) -and ($expected -ne $status)) { $acceptanceFailed = $true }
            continue
        }

        $backup = Get-OptionalString $task 'backup' ''
        $script = Get-OptionalString $task 'script' ''
        $test = Get-OptionalString $task 'test' ''
        $repair = Get-OptionalString $task 'repair' ''
        $rollback = Get-OptionalString $task 'rollback' ''
        $maxAttempts = Get-OptionalInt $chapter 'maxAttempts' $maxAttemptsDefault
        if ($maxAttempts -lt 1) { $maxAttempts = 1 }

        $backupStep = Invoke-CodeStep 'BACKUP' $backup $files.transcript $showErrors
        [void]$steps.Add($backupStep)
        if ($backupStep.status -eq 'FAILED') {
            $status = 'FAILED'
        } else {
            $status = 'FAILED'
            $attempt = 0
            while ($attempt -lt $maxAttempts) {
                $attempt++
                Write-Log ('ATTEMPT ' + $attempt + '/' + $maxAttempts + ' id=' + $id)
                $scriptStep = Invoke-CodeStep ('SCRIPT_' + $attempt) $script $files.transcript $showErrors
                [void]$steps.Add($scriptStep)
                $ok = ($scriptStep.status -eq 'OK')
                if ($ok -and (-not [string]::IsNullOrWhiteSpace($test))) {
                    $testStep = Invoke-CodeStep ('TEST_' + $attempt) $test $files.transcript $showErrors
                    [void]$steps.Add($testStep)
                    $ok = ($testStep.status -eq 'OK')
                }
                if ($ok) {
                    if ($attempt -eq 1) { $status = 'SUCCESS' } else { $status = 'SUCCESS_RECOVERED' }
                    break
                }
                if ($attempt -lt $maxAttempts) {
                    if (-not [string]::IsNullOrWhiteSpace($repair)) {
                        $repairStep = Invoke-CodeStep ('REPAIR_' + $attempt) $repair $files.transcript $showErrors
                        [void]$steps.Add($repairStep)
                        if ($repairStep.status -ne 'OK') { break }
                    } else { break }
                }
            }
        }

        if (($status -eq 'FAILED') -and $autoRollback -and (-not [string]::IsNullOrWhiteSpace($rollback))) {
            $rollbackStep = Invoke-CodeStep 'ROLLBACK' $rollback $files.transcript $showErrors
            [void]$steps.Add($rollbackStep)
        }

        Set-ChapterStatus $state $id $status
        [ordered]@{projectId=$project.projectId;chapterId=$id;status=$status;attempts=$maxAttempts;steps=$steps.ToArray()} | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $files.result -Encoding UTF8
        Publish-Run $id $stamp $files.result $files.transcript $headers
        Write-Log ('CHAPTER TERMINAL id=' + $id + ' status=' + $status)

        if ((-not [string]::IsNullOrWhiteSpace($expected)) -and ($expected -ne $status)) {
            $acceptanceFailed = $true
            Write-Log ('EXPECTED STATUS MISMATCH id=' + $id) 'WARN'
        }
        if (($status -eq 'FAILED') -and (-not $continueOnFailure)) { break }
    }

    $remaining = 0
    foreach ($chapter in @($project.chapters)) {
        $s = Get-ChapterStatus $state ([string]$chapter.id)
        if ($s -notin @('SUCCESS','SUCCESS_RECOVERED','REJECTED','FAILED')) { $remaining++ }
    }

    if (($remaining -eq 0) -and (-not $acceptanceFailed)) {
        Write-Log ('PROJECT ACCEPTED id=' + [string]$project.projectId)
        Write-Host ''
        Write-Host 'PROJECT ACCEPTED' -ForegroundColor Green
        exit 0
    }
    if ($remaining -eq 0) {
        Write-Host ''
        Write-Host 'PROJECT NEEDS DECISION' -ForegroundColor Yellow
        exit 4
    }
    Write-Host ''
    Write-Host 'PROJECT PARTIAL' -ForegroundColor Yellow
    exit 3
}
finally {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
