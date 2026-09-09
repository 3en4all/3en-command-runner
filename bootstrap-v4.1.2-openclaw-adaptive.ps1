$ErrorActionPreference='Stop'
$root='C:\3EN-Agent'
$runner=Join-Path $root '3en-agent-runner-v4.0.2.ps1'
$log=Join-Path $root 'bootstrap-v4.1.2.log'
New-Item -ItemType Directory -Force -Path $root | Out-Null
function W([string]$m){Add-Content -LiteralPath $log -Encoding UTF8 -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$m)}
try{
  W 'BOOTSTRAP START'
  $me=$PID
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
      $_.ProcessId -ne $me -and $_.Name -match '^(powershell|pwsh|node)\.exe$' -and
      ($_.CommandLine -match '3en-agent-runner-v4\.0\.2\.ps1' -or $_.CommandLine -match 'openclaw\s+onboard')
    } |
    ForEach-Object { try{Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; W ('Stopped stale PID='+$_.ProcessId)}catch{} }

  $uri='https://raw.githubusercontent.com/3en4all/3en-command-runner/main/3en-agent-runner-v4.0.2.ps1?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $runner
  $t=$null;$e=$null;[System.Management.Automation.Language.Parser]::ParseFile($runner,[ref]$t,[ref]$e)|Out-Null
  if(@($e).Count -gt 0){Write-Host '3EN v4.1.2 NEEDS AUTOMATIC REPAIR' -ForegroundColor Yellow; return}
  Write-Host '3EN v4.1.2 OPENCLAW ADAPTIVE RECOVERY START' -ForegroundColor Cyan
  & $runner -ProjectPath 'project-v4.1.2-openclaw-adaptive.json'
  $code=$LASTEXITCODE
  W ('Runner returned code='+$code)
  if($code -eq 0){Write-Host '3EN v4.1.2 OPENCLAW BRIDGE ACCEPTED' -ForegroundColor Green; return}
  Write-Host '3EN v4.1.2 NEEDS AUTOMATIC REPAIR' -ForegroundColor Yellow
}catch{
  W ($_|Out-String)
  Write-Host '3EN v4.1.2 NEEDS AUTOMATIC REPAIR' -ForegroundColor Yellow
  return
}