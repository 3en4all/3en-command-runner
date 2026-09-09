$ErrorActionPreference='Stop'
$root='C:\3EN-Agent'
$runner=Join-Path $root '3en-agent-runner-v3.9.ps1'
$backupRoot=Join-Path $root ('backups\v39-bootstrap\'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $root,$backupRoot | Out-Null

$existing=Get-ChildItem -LiteralPath $root -Filter '3en-agent-runner-v*.ps1' -File -ErrorAction SilentlyContinue
foreach($f in $existing){Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $backupRoot $f.Name) -Force}

$uri='https://raw.githubusercontent.com/3en4all/3en-command-runner/main/3en-agent-runner-v3.9.ps1?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $runner

$tokens=$null
$errors=$null
[System.Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors) | Out-Null
if(@($errors).Count -gt 0){throw 'Runner validation failed.'}

Write-Host '3EN v3.9 AUTONOMY START' -ForegroundColor Cyan
& $runner -ProjectPath 'project-v3.9-acceptance.json'
$exitCode=$LASTEXITCODE
if($exitCode -ne 0){exit $exitCode}
Write-Host '3EN v3.9 AUTONOMY ACCEPTED' -ForegroundColor Green
