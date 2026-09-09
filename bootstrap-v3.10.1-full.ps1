$ErrorActionPreference='Stop'
$root='C:\3EN-Agent'
$runner=Join-Path $root '3en-agent-runner-v3.10.1.ps1'
$backupRoot=Join-Path $root ('backups\v3.10.1-full\'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $root,$backupRoot | Out-Null

$me=$PID
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProcessId -ne $me -and
        $_.CommandLine -match '3en-agent-runner-v3\.[0-9]+(?:\.[0-9]+)?\.ps1'
    } |
    ForEach-Object {
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
    }

Get-ChildItem -LiteralPath $root -Filter '3en-agent-runner-v*.ps1' -File -ErrorAction SilentlyContinue |
    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $backupRoot $_.Name) -Force }

$uri='https://raw.githubusercontent.com/3en4all/3en-command-runner/main/3en-agent-runner-v3.10.1.ps1?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $runner

$tokens=$null
$errors=$null
[System.Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors) | Out-Null
if(@($errors).Count -gt 0){throw 'Runner validation failed.'}

Write-Host '3EN v3.10.1 FULL AUTONOMOUS PROJECT START' -ForegroundColor Cyan
& $runner -ProjectPath 'project-v3.10-full-regression.json'
$code=$LASTEXITCODE
if($code -ne 0){exit $code}
Write-Host '3EN v3.10.1 FULL AUTONOMOUS PROJECT ACCEPTED' -ForegroundColor Green
