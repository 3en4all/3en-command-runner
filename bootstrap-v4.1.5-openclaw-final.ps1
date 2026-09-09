$ErrorActionPreference='Stop'
$root='C:/3EN-Agent'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$runner402=Join-Path $root '3en-agent-runner-v4.0.2.ps1'
$patch=Join-Path $root 'patch-v4.0.3-resume-verdict.ps1'
$runner403=Join-Path $root '3en-agent-runner-v4.0.3.ps1'
$project=Join-Path $root 'project-v4.1.5-openclaw-final.json'
$ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$base='https://raw.githubusercontent.com/3en4all/3en-command-runner/main/'
Invoke-WebRequest -Uri ($base+'3en-agent-runner-v4.0.2.ps1?ts='+$ts) -OutFile $runner402 -UseBasicParsing
Invoke-WebRequest -Uri ($base+'patch-v4.0.3-resume-verdict.ps1?ts='+($ts+1)) -OutFile $patch -UseBasicParsing
Invoke-WebRequest -Uri ($base+'project-v4.1.5-openclaw-final.json?ts='+($ts+2)) -OutFile $project -UseBasicParsing
$t=$null;$e=$null
[System.Management.Automation.Language.Parser]::ParseFile($runner402,[ref]$t,[ref]$e)|Out-Null
if(@($e).Count -gt 0){throw ('RUNNER402_SYNTAX_ERRORS='+@($e).Count)}
$pt=$null;$pe=$null
[System.Management.Automation.Language.Parser]::ParseFile($patch,[ref]$pt,[ref]$pe)|Out-Null
if(@($pe).Count -gt 0){throw ('PATCH_SYNTAX_ERRORS='+@($pe).Count)}
$first=(Get-Content -LiteralPath $patch -TotalCount 1)
if($first -notmatch '^\s*param\s*\('){throw ('PATCH_STALE_OR_INVALID_FIRSTLINE='+$first)}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $patch -Source $runner402 -Destination $runner403
if($LASTEXITCODE -ne 0){throw ('RUNNER403_PATCH_FAILED='+$LASTEXITCODE)}
$t=$null;$e=$null
[System.Management.Automation.Language.Parser]::ParseFile($runner403,[ref]$t,[ref]$e)|Out-Null
if(@($e).Count -gt 0){throw ('RUNNER403_SYNTAX_ERRORS='+@($e).Count)}
Write-Host '3EN v4.1.5 OPENCLAW FINAL START'
$p=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner403,'-ProjectPath','project-v4.1.5-openclaw-final.json') -WorkingDirectory $root -Wait -PassThru -NoNewWindow
if($p.ExitCode -ne 0){Write-Host '3EN v4.1.5 NEEDS AUTOMATIC REPAIR';exit 1}
Write-Host '3EN v4.1.5 OPENCLAW BRIDGE ACCEPTED'
