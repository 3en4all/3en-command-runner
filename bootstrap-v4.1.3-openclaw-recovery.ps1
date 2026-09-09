$ErrorActionPreference='Stop'
$root='C:\3EN-Agent'
$runner=Join-Path $root '3en-agent-runner-v4.0.2.ps1'
$log=Join-Path $root 'bootstrap-v4.1.3.log'
New-Item -ItemType Directory -Force -Path $root | Out-Null
function W([string]$m){Add-Content -LiteralPath $log -Encoding UTF8 -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$m)}
try{
  W 'BOOTSTRAP START'
  $me=$PID
  $all=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
  foreach($p in $all){
    if($p.ProcessId -eq $me){continue}
    $cmd=[string]$p.CommandLine
    if(($p.Name -match '^(powershell|pwsh)\.exe$' -and $cmd -match '3en-agent-runner-v4\.0\.2\.ps1') -or ($p.Name -eq 'node.exe' -and $cmd -match 'openclaw')){
      try{Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; W ('Stopped stale PID='+$p.ProcessId)}catch{}
    }
  }
  Start-Sleep -Seconds 1

  $uri='https://raw.githubusercontent.com/3en4all/3en-command-runner/main/3en-agent-runner-v4.0.2.ps1?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $runner
  $t=$null;$e=$null;[System.Management.Automation.Language.Parser]::ParseFile($runner,[ref]$t,[ref]$e)|Out-Null
  if(@($e).Count -gt 0){throw ('RUNNER_SYNTAX_FAILED count='+@($e).Count)}

  $probe=New-Object Threading.Mutex($false,'Global\3EN-Agent-Project-v402')
  $owned=$false
  try{$owned=$probe.WaitOne(0);if(-not $owned){throw 'MUTEX_STILL_OWNED'}}finally{if($owned){try{$probe.ReleaseMutex()}catch{}};$probe.Dispose()}

  Write-Host '3EN v4.1.3 OPENCLAW CONFIG RECOVERY START' -ForegroundColor Cyan
  $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,'-ProjectPath','project-v4.1.3-openclaw-recovery.json')
  $proc=Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Wait -PassThru -NoNewWindow
  W ('Runner returned code='+$proc.ExitCode)
  if($proc.ExitCode -eq 0){Write-Host '3EN v4.1.3 OPENCLAW BRIDGE ACCEPTED' -ForegroundColor Green;return}
  Write-Host '3EN v4.1.3 NEEDS AUTOMATIC REPAIR' -ForegroundColor Yellow
}catch{
  W ($_|Out-String)
  Write-Host '3EN v4.1.3 NEEDS AUTOMATIC REPAIR' -ForegroundColor Yellow
}