$ErrorActionPreference = 'Stop'
$root = 'C:\3EN-Agent'
$runner = Join-Path $root '3en-agent-runner-v4.0.2.ps1'
$log = Join-Path $root 'bootstrap-v4.1-openclaw.log'
New-Item -ItemType Directory -Force -Path $root | Out-Null

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
            'User-Agent' = '3EN-Bootstrap-v4.1'
        }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $path = 'results/bootstrap-v4.1-' + $stamp + '.diagnostic.txt'
        $uri = 'https://api.github.com/repos/3en4all/3en-command-runner/contents/' + $path
        $text = "3EN v4.1 bootstrap diagnostic`r`n" + $Message + "`r`n"
        if (Test-Path -LiteralPath $log) { $text += "`r`n--- LOCAL LOG ---`r`n" + (Get-Content -LiteralPath $log -Raw -Encoding UTF8) }
        $body = @{message='Publish v4.1 bootstrap diagnostic';content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text));branch='main'} | ConvertTo-Json -Compress
        Invoke-RestMethod -Method Put -Uri $uri -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 20 | Out-Null
    } catch {}
}

try {
    Write-BootLog 'BOOTSTRAP START'
    $uri = 'https://raw.githubusercontent.com/3en4all/3en-command-runner/main/3en-agent-runner-v4.0.2.ps1?ts=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $runner
    $tokens=$null; $errors=$null
    [System.Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors) | Out-Null
    if (@($errors).Count -gt 0) {
        foreach($e in @($errors)){ Write-BootLog ('Parser: ' + $e.Message) 'ERROR' }
        Publish-Diagnostic ('RUNNER_SYNTAX_FAILED count=' + @($errors).Count)
        Write-Host '3EN v4.1 NEEDS AUTOMATIC REPAIR' -ForegroundColor Yellow
        return
    }
    Write-Host '3EN v4.1 OPENCLAW BRIDGE START' -ForegroundColor Cyan
    & $runner -ProjectPath 'project-v4.1-openclaw-bridge.json'
    $code = $LASTEXITCODE
    Write-BootLog ('Runner returned code=' + $code)
    if ($code -eq 0) {
        Write-Host '3EN v4.1 OPENCLAW BRIDGE ACCEPTED' -ForegroundColor Green
        return
    }
    Publish-Diagnostic ('RUNNER_RETURNED_NONZERO code=' + $code)
    Write-Host '3EN v4.1 NEEDS AUTOMATIC REPAIR' -ForegroundColor Yellow
}
catch {
    Write-BootLog ($_ | Out-String) 'ERROR'
    Publish-Diagnostic ('BOOTSTRAP_EXCEPTION=' + $_.Exception.Message)
    Write-Host '3EN v4.1 NEEDS AUTOMATIC REPAIR' -ForegroundColor Yellow
}
