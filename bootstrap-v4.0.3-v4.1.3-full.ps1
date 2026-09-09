$ErrorActionPreference='Stop'
$root='C:\3EN-Agent'
$branch='v403-hardening'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$runner402=Join-Path $root '3en-agent-runner-v4.0.2.ps1'
$runner403=Join-Path $root '3en-agent-runner-v4.0.3.ps1'

function Get-Raw([string]$path,[string]$dest){
  $u='https://raw.githubusercontent.com/3en4all/3en-command-runner/'+$branch+'/'+$path+'?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $dest
}
function Test-Ps([string]$path){
  $t=$null;$e=$null
  [System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$t,[ref]$e)|Out-Null
  if(@($e).Count -gt 0){ throw ('SYNTAX_FAILED '+$path+' count='+@($e).Count) }
}

Write-Host '3EN v4.0.3 HARDENING + v4.1.3 OPENCLAW START' -ForegroundColor Cyan
Get-Raw '3en-agent-runner-v4.0.2.ps1' $runner402
Test-Ps $runner402

& $runner402 -ProjectPath 'project-v4.0.3-hardening.json' -Branch $branch
$c1=$LASTEXITCODE
if($c1 -ne 0){
  Write-Host ('3EN v4.0.3 HARDENING FAILED code='+$c1) -ForegroundColor Yellow
  return
}
if(-not(Test-Path $runner403)){ throw 'V403_RUNNER_NOT_CREATED' }
Test-Ps $runner403
Write-Host '3EN v4.0.3 HARDENING PASS' -ForegroundColor Green

& $runner403 -ProjectPath 'project-v4.1.3-openclaw-fresh.json' -Branch $branch
$c2=$LASTEXITCODE
if($c2 -eq 0){
  Write-Host '3EN v4.1.3 OPENCLAW BRIDGE ACCEPTED' -ForegroundColor Green
  return
}
Write-Host ('3EN v4.1.3 NEEDS AUTOMATIC REPAIR code='+$c2) -ForegroundColor Yellow
