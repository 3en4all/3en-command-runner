$ErrorActionPreference = 'Stop'
$root = 'C:/3EN-Agent'
$stateFile = "$root/3en-agent.state.json"
$logFile = "$root/handover-v3.7.log"
$runner37 = "$root/3en-agent-runner-v3.7.ps1"
$project = "$root/project.json"

function HLog([string]$m) {
    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
    Add-Content -LiteralPath $logFile -Encoding UTF8 -Value $line
}

HLog 'HANDOVER_V37_START'
$deadline = (Get-Date).AddMinutes(10)
$ready = $false
while ((Get-Date) -lt $deadline) {
    try {
        if (Test-Path -LiteralPath $stateFile) {
            $s = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
            if ($s.lastExecutedId -eq '2026-09-09-045' -and $s.lastTerminalStatus -eq 'SUCCESS') {
                $ready = $true
                HLog '045_SUCCESS_OBSERVED'
                break
            }
        }
    } catch {
        HLog ('STATE_READ_RETRY=' + $_.Exception.Message)
    }
    Start-Sleep -Seconds 2
}
if (-not $ready) { HLog 'FATAL=045_SUCCESS_TIMEOUT'; exit 61 }
if (-not (Test-Path -LiteralPath $runner37)) { HLog 'FATAL=RUNNER37_MISSING'; exit 62 }
if (-not (Test-Path -LiteralPath $project)) { HLog 'FATAL=PROJECT_JSON_MISSING'; exit 63 }
$tok = $null
$err = $null
[System.Management.Automation.Language.Parser]::ParseFile($runner37,[ref]$tok,[ref]$err) | Out-Null
if (@($err).Count -ne 0) { HLog ('FATAL=RUNNER37_SYNTAX_' + @($err).Count); exit 64 }
$old = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine -like '*3en-agent-runner-v3.6.ps1*' })
foreach ($p in $old) {
    try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; HLog ('STOPPED_V36_PID=' + $p.ProcessId) }
    catch { HLog ('STOP_V36_WARN=' + $_.Exception.Message) }
}
Start-Sleep -Seconds 2
$projectUrl = 'https://api.github.com/repos/3en4all/3en-command-runner/contents/project.json?ref=main'
$p37 = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner37,'-ProjectUrl',$projectUrl) -PassThru
Start-Sleep -Seconds 3
if ($p37.HasExited) { HLog ('FATAL=V37_EXITED_EARLY_CODE_' + $p37.ExitCode); exit 65 }
HLog ('STARTED_V37_PID=' + $p37.Id)
HLog 'HANDOVER_V37_COMPLETE=TRUE'
exit 0
