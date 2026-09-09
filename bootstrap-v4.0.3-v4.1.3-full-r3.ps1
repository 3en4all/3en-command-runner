$ErrorActionPreference='Stop'
$root='C:\3EN-Agent'
New-Item -ItemType Directory -Force -Path $root | Out-Null
function Get-Remote([string]$path,[string]$dest){
  $u='https://raw.githubusercontent.com/3en4all/3en-command-runner/v403-hardening/'+$path+'?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $dest
}
function Parse-Ok([string]$p){
  $t=$null;$e=$null;[System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e)|Out-Null
  if(@($e).Count -gt 0){throw ('SYNTAX_ERRORS '+$p+' count='+@($e).Count)}
}
try {
  $v402=Join-Path $root '3en-agent-runner-v4.0.2.ps1'
  Get-Remote '3en-agent-runner-v4.0.2.ps1' $v402
  Parse-Ok $v402
  Write-Host '3EN v4.0.3 HARDENING R3 START' -ForegroundColor Cyan
  & $v402 -ProjectPath 'project-v4.0.3-hardening-r3.json' -Branch 'v403-hardening'
  if($LASTEXITCODE -ne 0){Write-Host ('3EN v4.0.3 HARDENING FAILED code='+$LASTEXITCODE) -ForegroundColor Yellow; return}

  $v403=Join-Path $root '3en-agent-runner-v4.0.3.ps1'
  if(-not(Test-Path $v403)){throw 'V403_RUNNER_MISSING_AFTER_HARDENING'}
  Parse-Ok $v403
  Write-Host '3EN v4.0.3 HARDENING PASS' -ForegroundColor Green

  $state=Join-Path $root '3en-project.state.json'
  if(Test-Path $state){Remove-Item $state -Force}
  & $v403 -ProjectPath 'project-v4.0.3-resume-regression.json' -Branch 'v403-hardening'
  if($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 4){throw ('RESUME_REGRESSION_FIRST_RUN_CODE='+$LASTEXITCODE)}
  & $v403 -ProjectPath 'project-v4.0.3-resume-regression.json' -Branch 'v403-hardening'
  if($LASTEXITCODE -ne 4){throw ('RESUME_REGRESSION_SECOND_RUN_EXPECTED_CODE4 got='+$LASTEXITCODE)}
  $sum=Get-ChildItem (Join-Path $root 'runs') -Filter 'project-2026-09-09-v403-resume-regression.summary.json' -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if(-not $sum){throw 'RESUME_REGRESSION_SUMMARY_MISSING'}
  $sj=Get-Content $sum.FullName -Raw | ConvertFrom-Json
  if([int]$sj.counts.failed -ne 1 -or [bool]$sj.accepted){throw 'RESUME_REGRESSION_SEMANTICS_FAILED'}
  Write-Host '3EN v4.0.3 RESUME VERDICT REGRESSION PASS' -ForegroundColor Green

  if(Test-Path $state){Remove-Item $state -Force}
  & $v403 -ProjectPath 'project-v4.1.3-openclaw-acceptance.json' -Branch 'v403-hardening'
  if($LASTEXITCODE -ne 0){Write-Host ('3EN v4.1.3 OPENCLAW FAILED code='+$LASTEXITCODE) -ForegroundColor Yellow; return}
  Write-Host '3EN v4.1.3 OPENCLAW BRIDGE ACCEPTED' -ForegroundColor Green
} catch {
  Write-Host ('3EN R3 FAILED: '+$_.Exception.Message) -ForegroundColor Yellow
}