$ErrorActionPreference='Stop'
$root='C:\3EN-Agent'
$runner=Join-Path $root '3en-agent-runner-v4.0.2.ps1'
$log=Join-Path $root 'bootstrap-v4.1.4-openclaw.log'
New-Item -ItemType Directory -Force -Path $root | Out-Null

function W([string]$m,[string]$level='INFO'){
  Add-Content -LiteralPath $log -Encoding UTF8 -Value ('[{0}][{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$level,$m)
}

try {
  W 'BOOTSTRAP START'

  # Never kill another 3EN project. Wait synchronously until the accepted runner mutex is free.
  $free=$false
  for($i=0;$i -lt 150;$i++){
    $probe=New-Object Threading.Mutex($false,'Global\3EN-Agent-Project-v402')
    $owned=$false
    try {
      $owned=$probe.WaitOne(0)
      if($owned){$free=$true;break}
    } finally {
      if($owned){try{$probe.ReleaseMutex()}catch{}}
      $probe.Dispose()
    }
    if($i -eq 0){Write-Host '3EN: another project is active; queued v4.1.4 recovery.' -ForegroundColor DarkYellow}
    Start-Sleep -Seconds 2
  }
  if(-not $free){throw '3EN_MUTEX_BUSY_TIMEOUT'}

  # Refresh and parser-check the accepted execution engine.
  $uri='https://raw.githubusercontent.com/3en4all/3en-command-runner/main/3en-agent-runner-v4.0.2.ps1?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $runner
  $t=$null;$e=$null
  [System.Management.Automation.Language.Parser]::ParseFile($runner,[ref]$t,[ref]$e)|Out-Null
  if(@($e).Count -gt 0){throw ('RUNNER_SYNTAX_FAILED count='+@($e).Count)}

  Write-Host '3EN v4.1.4 OPENCLAW RECOVERY START' -ForegroundColor Cyan
  W 'Launching v4.1.4 project in isolated child PowerShell'

  $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,'-ProjectPath','project-v4.1.4-openclaw-recovery.json')
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Wait -PassThru -NoNewWindow
  W ('Runner returned code='+$p.ExitCode)

  if($p.ExitCode -eq 0){
    Write-Host '3EN v4.1.4 OPENCLAW BRIDGE ACCEPTED' -ForegroundColor Green
    return
  }
  Write-Host '3EN v4.1.4 NEEDS AUTOMATIC REPAIR' -ForegroundColor Yellow
}
catch {
  W ($_|Out-String) 'ERROR'
  Write-Host '3EN v4.1.4 NEEDS AUTOMATIC REPAIR' -ForegroundColor Yellow
}
