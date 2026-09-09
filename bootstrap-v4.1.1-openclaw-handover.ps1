$ErrorActionPreference = 'Stop'
$root = 'C:\3EN-Agent'
$runner = Join-Path $root '3en-agent-runner-v4.0.2.ps1'
$log = Join-Path $root 'bootstrap-v4.1.1-openclaw.log'
$backupRoot = Join-Path $root ('backups\v4.1.1-handover\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $root,$backupRoot | Out-Null

function Write-BootLog {
    param([string]$Message,[string]$Level='INFO')
    $line = '[{0}][{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message
    Add-Content -LiteralPath $log -Encoding UTF8 -Value $line
}

function Publish-Diagnostic {
    param([string]$Message)
    try {
        $token = $env:THREEEN_GH_TOKEN
        if ([string]::IsNullOrWhiteSpace($token)) { $token = [Environment]::GetEnvironmentVariable('THREEEN_GH_TOKEN','User') }
        if ([string]::IsNullOrWhiteSpace($token)) { return }
        $headers = @{
            Authorization = 'Bearer ' + $token
            Accept = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
            'User-Agent' = '3EN-Bootstrap-v4.1.1'
        }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $path = 'results/bootstrap-v4.1.1-' + $stamp + '.diagnostic.txt'
        $uri = 'https://api.github.com/repos/3en4all/3en-command-runner/contents/' + $path
        $text = "3EN v4.1.1 bootstrap diagnostic`r`n" + $Message + "`r`n"
        if (Test-Path -LiteralPath $log) { $text += "`r`n--- LOCAL LOG ---`r`n" + (Get-Content -LiteralPath $log -Raw -Encoding UTF8) }
        $body = @{message='Publish v4.1.1 bootstrap diagnostic';content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text));branch='main'} | ConvertTo-Json -Compress
        Invoke-RestMethod -Method Put -Uri $uri -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 20 | Out-Null
    } catch {}
}

try {
    Write-BootLog 'BOOTSTRAP START'

    # Backup current local runner before handover.
    if (Test-Path -LiteralPath $runner) {
        Copy-Item -LiteralPath $runner -Destination (Join-Path $backupRoot '3en-agent-runner-v4.0.2.ps1') -Force
    }

    # Stop only stale 3EN runner hosts. Never stop this PowerShell process.
    $me = $PID
    $stale = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        ($_.Name -eq 'powershell.exe' -or $_.Name -eq 'pwsh.exe') -and
        $_.ProcessId -ne $me -and
        $_.CommandLine -match '3en-agent-runner-v(?:3(?:\.\d+)+|4(?:\.\d+)*)\.ps1'
    })

    foreach ($proc in $stale) {
        try {
            Write-BootLog ('Stopping stale runner PID=' + $proc.ProcessId + ' CMD=' + $proc.CommandLine)
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
        } catch {
            Write-BootLog ('Failed stopping PID=' + $proc.ProcessId + ': ' + $_.Exception.Message) 'WARN'
        }
    }

    if ($stale.Count -gt 0) { Start-Sleep -Seconds 2 }

    # Refresh the accepted v4.0.2 execution engine.
    $uri = 'https://raw.githubusercontent.com/3en4all/3en-command-runner/main/3en-agent-runner-v4.0.2.ps1?ts=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $runner

    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors) | Out-Null
    if (@($errors).Count -gt 0) {
        foreach ($e in @($errors)) { Write-BootLog ('Parser: ' + $e.Message) 'ERROR' }
        Publish-Diagnostic ('RUNNER_SYNTAX_FAILED count=' + @($errors).Count)
        Write-Host '3EN v4.1.1 NEEDS AUTOMATIC REPAIR' -ForegroundColor Yellow
        return
    }

    # Probe the exact mutex used by v4.0.2 before starting the project.
    $probe = New-Object Threading.Mutex($false,'Global\3EN-Agent-Project-v402')
    $owned = $false
    try {
        $owned = $probe.WaitOne(0)
        if (-not $owned) {
            Publish-Diagnostic 'MUTEX_STILL_OWNED_AFTER_STALE_RUNNER_CLEANUP'
            Write-Host '3EN v4.1.1 NEEDS AUTOMATIC REPAIR' -ForegroundColor Yellow
            return
        }
    } finally {
        if ($owned) { try { $probe.ReleaseMutex() } catch {} }
        $probe.Dispose()
    }

    Write-BootLog ('HANDOVER CLEAN staleRunners=' + $stale.Count)
    Write-Host '3EN v4.1.1 OPENCLAW BRIDGE START' -ForegroundColor Cyan

    # Run in a child PowerShell so runner exit codes cannot terminate this host.
    $args = @(
        '-NoProfile',
        '-ExecutionPolicy','Bypass',
        '-File',$runner,
        '-ProjectPath','project-v4.1-openclaw-bridge.json'
    )
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Wait -PassThru -NoNewWindow
    $code = $p.ExitCode
    Write-BootLog ('Runner returned code=' + $code)

    if ($code -eq 0) {
        Write-Host '3EN v4.1.1 OPENCLAW BRIDGE ACCEPTED' -ForegroundColor Green
        Write-BootLog 'BOOTSTRAP ACCEPTED'
        return
    }

    Publish-Diagnostic ('RUNNER_RETURNED_NONZERO code=' + $code)
    Write-Host '3EN v4.1.1 NEEDS AUTOMATIC REPAIR' -ForegroundColor Yellow
}
catch {
    Write-BootLog ($_ | Out-String) 'ERROR'
    Publish-Diagnostic ('BOOTSTRAP_EXCEPTION=' + $_.Exception.Message)
    Write-Host '3EN v4.1.1 NEEDS AUTOMATIC REPAIR' -ForegroundColor Yellow
}
