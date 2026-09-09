# 3EN Agent Runner v2.2
# Windows 11 / PowerShell 7+
# Run from elevated PowerShell (Administrator).

param(
    [Parameter(Mandatory=$true)]
    [string]$TaskUrl,

    [int]$PollSeconds = 15,

    [string]$Root = "C:\3EN-Agent"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$StateFile = Join-Path $Root "3en-agent.state.json"
$LogFile   = Join-Path $Root "3en-agent.log"
$RunsDir   = Join-Path $Root "runs"

New-Item -ItemType Directory -Force -Path $Root, $RunsDir | Out-Null

function Write-AgentLog {
    param([string]$Message, [string]$Level = "INFO")
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$ts][$Level] $Message"
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Sha256Text {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Load-State {
    if (Test-Path -LiteralPath $StateFile) {
        try {
            return Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            Write-AgentLog "State file unreadable; using empty state. $($_.Exception.Message)" "WARN"
        }
    }

    return [pscustomobject]@{
        lastExecutedId = ""
        lastExecutedHash = ""
    }
}

function Save-State {
    param([string]$Id, [string]$Hash)

    [ordered]@{
        lastExecutedId = $Id
        lastExecutedHash = $Hash
        updatedUtc = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Get-RemoteTask {
    param([string]$Url)

    $headers = @{
        "Cache-Control" = "no-cache"
        "Pragma" = "no-cache"
        "User-Agent" = "3EN-Agent-Runner-v2.2"
    }

    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $requestUrl = if ($Url.Contains("?")) { "${Url}&ts=$ts" } else { "${Url}?ts=$ts" }

    Write-AgentLog "Fetching task..."
    $response = Invoke-WebRequest -Uri $requestUrl -Headers $headers -Method Get -TimeoutSec 20

    Write-AgentLog "FETCH OK HTTP=$($response.StatusCode)"

    if ([string]::IsNullOrWhiteSpace([string]$response.Content)) {
        throw "Remote task file is empty."
    }

    $task = [string]$response.Content | ConvertFrom-Json
    Write-AgentLog "PARSE OK ID=$($task.id)"

    foreach ($required in @("id","title","description","script")) {
        if (-not $task.PSObject.Properties.Name.Contains($required)) {
            throw "Task JSON is missing required field: $required"
        }

        if ([string]::IsNullOrWhiteSpace([string]$task.$required)) {
            throw "Task JSON field '$required' is empty."
        }
    }

    return $task
}

function Show-Task {
    param($Task, [string]$Hash)

    Write-Host ""
    Write-Host "====================================================================" -ForegroundColor DarkGray
    Write-Host "3EN AGENT - NEW TASK" -ForegroundColor Yellow
    Write-Host "ID:          $($Task.id)"
    Write-Host "TITLE:       $($Task.title)" -ForegroundColor Cyan
    Write-Host "DESCRIPTION: $($Task.description)"
    Write-Host "SHA256:      $Hash"
    Write-Host "--------------------------------------------------------------------"

    foreach ($pair in @(
        @("BACKUP","backup","Magenta"),
        @("SCRIPT","script","Green"),
        @("TEST","test","Blue"),
        @("ROLLBACK","rollback","DarkYellow")
    )) {
        $label = $pair[0]
        $prop  = $pair[1]
        $color = $pair[2]

        if ($Task.PSObject.Properties.Name.Contains($prop)) {
            $value = [string]$Task.$prop
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                Write-Host "${label}:" -ForegroundColor $color
                Write-Host $value
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

    while ($true) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            $ch = [char]::ToUpperInvariant($key.KeyChar)

            if ($ch -eq 'Y' -or $ch -eq 'N') {
                Write-Host $ch
                return $ch
            }
        }

        Start-Sleep -Milliseconds 50
    }
}

function Invoke-Step {
    param(
        [string]$Name,
        [string]$Code,
        [string]$TranscriptPath
    )

    if ([string]::IsNullOrWhiteSpace($Code)) {
        return [pscustomobject]@{ name=$Name; status="SKIPPED"; exitCode=$null; error=$null }
    }

    Write-Host ""
    Write-Host ">>> $Name" -ForegroundColor Yellow

    try {
        $global:LASTEXITCODE = 0
        $output = & ([ScriptBlock]::Create($Code)) *>&1
        $output | Tee-Object -FilePath $TranscriptPath -Append | Out-Host

        $exitCode = $global:LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = 0 }

        if ($exitCode -ne 0) {
            return [pscustomobject]@{ name=$Name; status="FAILED"; exitCode=$exitCode; error="LASTEXITCODE=$exitCode" }
        }

        return [pscustomobject]@{ name=$Name; status="OK"; exitCode=$exitCode; error=$null }
    }
    catch {
        $_ | Out-String | Add-Content -LiteralPath $TranscriptPath -Encoding UTF8
        return [pscustomobject]@{ name=$Name; status="FAILED"; exitCode=$global:LASTEXITCODE; error=$_.Exception.Message }
    }
}

if (-not (Test-IsAdministrator)) {
    Write-Host "ERROR: PowerShell must be run as Administrator." -ForegroundColor Red
    exit 1
}

Write-AgentLog "3EN Agent Runner v2.2 started."
Write-AgentLog "Task URL: $TaskUrl"
Write-AgentLog "Polling every $PollSeconds seconds."

$state = Load-State

while ($true) {
    try {
        $task = Get-RemoteTask -Url $TaskUrl

        $normalized = $task | ConvertTo-Json -Depth 20 -Compress
        $hash = Get-Sha256Text -Text $normalized

        $alreadyExecuted = (
            $state.lastExecutedId -eq [string]$task.id -and
            $state.lastExecutedHash -eq $hash
        )

        if ($alreadyExecuted) {
            Write-AgentLog "No new task. ID=$($task.id)"
        }
        else {
            Write-AgentLog "TASK DETECTED ID=$($task.id) SHA256=$hash"
            Show-Task -Task $task -Hash $hash

            $choice = Get-KeyChoice -Prompt "[Y] Approve task   [N] Reject task"

            if ($choice -eq 'Y') {
                $runStamp = Get-Date -Format "yyyyMMdd-HHmmss"
                $safeId = ([string]$task.id) -replace '[^a-zA-Z0-9._-]', '_'
                $runDir = Join-Path $RunsDir "$runStamp-$safeId"
                New-Item -ItemType Directory -Force -Path $runDir | Out-Null

                $taskFile   = Join-Path $runDir "task.json"
                $transcript = Join-Path $runDir "transcript.txt"
                $resultFile = Join-Path $runDir "result.json"

                $task | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $taskFile -Encoding UTF8
                $results = @()

                if ($task.PSObject.Properties.Name.Contains("backup") -and -not [string]::IsNullOrWhiteSpace([string]$task.backup)) {
                    $r = Invoke-Step -Name "BACKUP" -Code ([string]$task.backup) -TranscriptPath $transcript
                    $results += $r
                    if ($r.status -ne "OK") {
                        Write-AgentLog "Backup failed. Task aborted. ID=$($task.id)" "ERROR"
                        $results | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resultFile -Encoding UTF8
                        continue
                    }
                }

                $r = Invoke-Step -Name "SCRIPT" -Code ([string]$task.script) -TranscriptPath $transcript
                $results += $r

                if ($r.status -ne "OK") {
                    Write-AgentLog "Main script failed. ID=$($task.id)" "ERROR"
                    $results | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resultFile -Encoding UTF8
                    continue
                }

                if ($task.PSObject.Properties.Name.Contains("test") -and -not [string]::IsNullOrWhiteSpace([string]$task.test)) {
                    $rt = Invoke-Step -Name "TEST" -Code ([string]$task.test) -TranscriptPath $transcript
                    $results += $rt

                    if ($rt.status -ne "OK") {
                        Write-AgentLog "Post-test failed. ID=$($task.id)" "ERROR"

                        if ($task.PSObject.Properties.Name.Contains("rollback") -and -not [string]::IsNullOrWhiteSpace([string]$task.rollback)) {
                            $rb = Get-KeyChoice -Prompt "[Y] Run rollback   [N] Leave as-is"
                            if ($rb -eq 'Y') {
                                $rr = Invoke-Step -Name "ROLLBACK" -Code ([string]$task.rollback) -TranscriptPath $transcript
                                $results += $rr
                            }
                        }

                        $results | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resultFile -Encoding UTF8
                        continue
                    }
                }

                $results | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resultFile -Encoding UTF8
                Save-State -Id ([string]$task.id) -Hash $hash
                $state = Load-State

                Write-AgentLog "Task completed successfully. ID=$($task.id)"
                Write-Host ""
                Write-Host "TASK COMPLETE" -ForegroundColor Green
                Write-Host "Run directory: $runDir"
                Write-Host "Result:        $resultFile"
                Write-Host "Transcript:    $transcript"
            }
            else {
                Write-AgentLog "Task rejected by user. ID=$($task.id)" "WARN"
            }
        }
    }
    catch {
        Write-AgentLog "Poll failed: $($_.Exception.Message)" "ERROR"
    }

    Start-Sleep -Seconds $PollSeconds
}
