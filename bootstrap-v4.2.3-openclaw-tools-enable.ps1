$ErrorActionPreference='Stop'
$root='C:/3EN-Agent'
$project=Join-Path $root 'project-v4.2.3-openclaw-tools-enable.json'
$runner=Join-Path $root '3en-agent-runner-v4.0.3.ps1'
$ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
Invoke-WebRequest -UseBasicParsing -Uri ('https://raw.githubusercontent.com/3en4all/3en-command-runner/main/project-v4.2.3-openclaw-tools-enable.json?ts='+$ts) -OutFile $project
if(-not(Test-Path $runner)){throw 'RUNNER403_MISSING'}
& $runner -ProjectPath 'project-v4.2.3-openclaw-tools-enable.json'
Write-Host ('V423_EXIT='+$LASTEXITCODE)