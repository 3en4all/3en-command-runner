$ErrorActionPreference='Stop'
$root='C:/3EN-Agent'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$runner402=Join-Path $root '3en-agent-runner-v4.0.2.ps1'
$patch=Join-Path $root 'patch-v4.0.3-resume-verdict.ps1'
$runner403=Join-Path $root '3en-agent-runner-v4.0.3.ps1'
$project=Join-Path $root 'project-v4.1.5-openclaw-final.json'
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/3en4all/3en-command-runner/main/3en-agent-runner-v4.0.2.ps1' -OutFile $runner402 -UseBasicParsing
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/3en4all/3en-command-runner/main/patch-v4.0.3-resume-verdict.ps1' -OutFile $patch -UseBasicParsing
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/3en4all/3en-command-runner/main/project-v4.1.5-openclaw-final.json' -OutFile $project -UseBasicParsing
$t=$null;$e=$null;[System.Management.Automation.Language.Parser]::ParseFile($runner402,[ref]$t,[ref]$e)|Out-Null;if(@($e).Count -gt 0){throw ('RUNNER402_SYNTAX_ERRORS='+@($e).Count)}
&t powershell.exe
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $patch -Source $runner402 -Destination $runner403
if($LASTEXITCODE -ne 0){throw ('RUNNER403_PATCH_FAILED='+$LASTEXITCODE)}
$t=$null;$e=$null;[System.Management.Automation.Language.Parser]::ParseFile($runner403,[ref]$t,[ref]$e)|Out-Null;if(@($e).Count -gt 0){throw ('RUNNER403_SYNTAX_ERRORS='+@($e).Count)}
Write-Host '3EN v4.1.5 OPENCLAW FINAL START'
$p=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner403,'-ProjectPath','project-v4.1.5-openclaw-final.json') -WorkingDirectory $root -Wait -PassThru -NoNewWindow
if($p.ExitCode -ne 0){Write-Host '3EN v4.1.5 NEEDS AUTOMATIC REPAIR';exit 1}
Write-Host '3EN v4.1.5 OPENCLAW BRIDGE ACCEPTED'
