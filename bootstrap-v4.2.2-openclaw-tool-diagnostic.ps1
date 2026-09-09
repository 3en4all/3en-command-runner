$ErrorActionPreference='Stop'
$root='C:/3EN-Agent'
$log=Join-Path $root 'bootstrap-v4.2.2-openclaw-tool-diagnostic.log'
New-Item -ItemType Directory -Force -Path $root|Out-Null
try {
  $runner=Join-Path $root '3en-agent-runner-v4.0.3.ps1'
  $project=Join-Path $root 'project-v4.2.2-openclaw-tool-diagnostic.json'
  $ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $base='https://raw.githubusercontent.com/3en4all/3en-command-runner/main/'
  if(-not(Test-Path $runner)){throw 'RUNNER403_MISSING'}
  Invoke-WebRequest -UseBasicParsing -Uri ($base+'project-v4.2.2-openclaw-tool-diagnostic.json?ts='+$ts) -OutFile $project
  ('['+(Get-Date -Format s)+'] START')|Set-Content $log -Encoding UTF8
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,'-ProjectPath','project-v4.2.2-openclaw-tool-diagnostic.json') -WorkingDirectory $root -Wait -PassThru -NoNewWindow
  ('['+(Get-Date -Format s)+'] EXIT='+$p.ExitCode)|Add-Content $log -Encoding UTF8
  Write-Host ('V422_DIAGNOSTIC_EXIT='+$p.ExitCode)
} catch {
  $msg=($_|Out-String)
  $msg|Add-Content $log -Encoding UTF8
  Write-Host 'V422_BOOTSTRAP_FAILED'
  Write-Host $msg
}
Write-Host ('LOG='+$log)
