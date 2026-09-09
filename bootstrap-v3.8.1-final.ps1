# 3EN Agent v3.8.1 - one-command bootstrap + final acceptance run
$ErrorActionPreference = 'Stop'
$Root = 'C:\3EN-Agent'
$Runner = Join-Path $Root '3en-agent-runner-v3.8.1.ps1'
$BackupRoot = Join-Path $Root ('backups\v3.8.1-bootstrap\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$Raw = 'https://raw.githubusercontent.com/3en4all/3en-command-runner/main/3en-agent-runner-v3.8.1.ps1'

New-Item -ItemType Directory -Force -Path $Root, $BackupRoot | Out-Null
if (Test-Path -LiteralPath $Runner) {
    Copy-Item -LiteralPath $Runner -Destination (Join-Path $BackupRoot '3en-agent-runner-v3.8.1.ps1') -Force
}

$temp = Join-Path $env:TEMP ('3en-agent-runner-v3.8.1-' + [guid]::NewGuid().ToString('N') + '.ps1')
try {
    Invoke-WebRequest -UseBasicParsing -Uri $Raw -OutFile $temp
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($temp, [ref]$tokens, [ref]$errors) | Out-Null
    if (@($errors).Count -ne 0) { throw 'Runner validation failed.' }
    Copy-Item -LiteralPath $temp -Destination $Runner -Force
} finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}

Write-Host '3EN v3.8.1 READY - starting final project acceptance.' -ForegroundColor Cyan
& $Runner -ProjectPath 'project-retry-039-040.json'
exit $LASTEXITCODE
