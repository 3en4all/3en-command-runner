$ErrorActionPreference='Stop'
$root='C:/3EN-Agent'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$runner=Join-Path $root '3en-agent-runner-v4.0.3.ps1'
$project=Join-Path $root 'project-v4.2.1-openclaw-executor-probe.json'
$ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$base='https://raw.githubusercontent.com/3en4all/3en-command-runner/main/'
Invoke-WebRequest -Uri ($base+'3en-agent-runner-v4.0.2.ps1?ts='+$ts) -OutFile (Join-Path $root '3en-agent-runner-v4.0.2.ps1') -UseBasicParsing
Invoke-WebRequest -Uri ($base+'patch-v4.0.3-resume-verdict.ps1?ts='+($ts+1)) -OutFile (Join-Path $root 'patch-v4.0.3-resume-verdict.ps1') -UseBasicParsing
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'patch-v4.0.3-resume-verdict.ps1') -Source (Join-Path $root '3en-agent-runner-v4.0.2.ps1') -Destination $runner
if($LASTEXITCODE -ne 0){throw ('RUNNER403_PATCH_FAILED='+$LASTEXITCODE)}
Invoke-WebRequest -Uri ($base+'project-v4.2.1-openclaw-executor-probe.json?ts='+($ts+2)) -OutFile $project -UseBasicParsing
Write-Host '3EN v4.2.1 OPENCLAW EXECUTOR PROBE START'
$p=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,'-ProjectPath','project-v4.2.1-openclaw-executor-probe.json') -WorkingDirectory $root -Wait -PassThru -NoNewWindow
if($p.ExitCode -ne 0){Write-Host ('3EN v4.2.1 NEEDS AUTOMATIC REPAIR code='+$p.ExitCode);exit $p.ExitCode}
Write-Host '3EN v4.2.1 EXECUTOR PROBE=PASS'