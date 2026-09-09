$ErrorActionPreference='Stop'
$root='C:\3EN-Agent'
New-Item -ItemType Directory -Force -Path $root | Out-Null
function Get-Remote([string]$path,[string]$dest){
  $u='https://raw.githubusercontent.com/3en4all/3en-command-runner/v403-hardening/'+$path+'?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $dest
}
function Parse-Ok([string]$p){
  $t=$null;$e=$null
  [System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e)|Out-Null
  if(@($e).Count -gt 0){throw ('SYNTAX_ERRORS '+$p+' count='+@($e).Count)}
}
function Clear-ProjectState {
  $state=Join-Path $root '3en-project.state.json'
  if(Test-Path $state){Remove-Item $state -Force}
}
try {
  Write-Host '3EN v4.0.4 HARDENING R5 START' -ForegroundColor Cyan

  $v402=Join-Path $root '3en-agent-runner-v4.0.2.ps1'
  $p403=Join-Path $root 'patch-v4.0.3-resume-verdict.ps1'
  $v403=Join-Path $root '3en-agent-runner-v4.0.3.ps1'
  $p404=Join-Path $root 'patch-v4.0.4-global-verdict.ps1'
  $v404=Join-Path $root '3en-agent-runner-v4.0.4.ps1'

  Get-Remote '3en-agent-runner-v4.0.2.ps1' $v402
  Get-Remote 'patch-v4.0.3-resume-verdict.ps1' $p403
  Get-Remote 'patch-v4.0.4-global-verdict.ps1' $p404
  Parse-Ok $v402; Parse-Ok $p403; Parse-Ok $p404

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p403 -Source $v402 -Destination $v403
  if($LASTEXITCODE -ne 0){throw 'V403_BUILD_FAILED'}
  Parse-Ok $v403

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p404 -Source $v403 -Destination $v404
  if($LASTEXITCODE -ne 0){throw 'V404_BUILD_FAILED'}
  Parse-Ok $v404
  $code=Get-Content $v404 -Raw
  $must='$accepted = (-not $mismatch -and $remaining -eq 0 -and $counts.failed -eq 0 -and $counts.blocked -eq 0)'
  if(-not $code.Contains($must)){throw 'V404_GLOBAL_VERDICT_MARKER_MISSING'}
  Write-Host '3EN v4.0.4 BUILD PASS' -ForegroundColor Green

  Clear-ProjectState
  & $v404 -ProjectPath 'project-v4.0.4-resume-regression.json' -Branch 'v403-hardening'
  $first=$LASTEXITCODE
  if($first -ne 4){throw ('V404_REGRESSION_FIRST_EXPECTED_CODE4 got='+$first)}
  $sumPath=Join-Path $root 'runs\project-2026-09-09-v404-resume-regression.summary.json'
  if(-not(Test-Path $sumPath)){throw 'V404_REGRESSION_SUMMARY1_MISSING'}
  $s1=Get-Content $sumPath -Raw | ConvertFrom-Json
  if([bool]$s1.accepted -or [int]$s1.counts.failed -ne 1 -or [int]$s1.counts.blocked -ne 0){throw 'V404_REGRESSION_FIRST_SEMANTICS_FAILED'}

  & $v404 -ProjectPath 'project-v4.0.4-resume-regression.json' -Branch 'v403-hardening'
  $second=$LASTEXITCODE
  if($second -ne 4){throw ('V404_REGRESSION_SECOND_EXPECTED_CODE4 got='+$second)}
  $s2=Get-Content $sumPath -Raw | ConvertFrom-Json
  if([bool]$s2.accepted -or [int]$s2.counts.failed -ne 1 -or [int]$s2.counts.blocked -ne 0){throw 'V404_REGRESSION_RESUME_SEMANTICS_FAILED'}
  Write-Host '3EN v4.0.4 RESUME/GLOBAL VERDICT REGRESSION PASS' -ForegroundColor Green

  Clear-ProjectState
  Write-Host '3EN v4.1.3 OPENCLAW ACCEPTANCE START' -ForegroundColor Cyan
  & $v404 -ProjectPath 'project-v4.1.3-openclaw-acceptance.json' -Branch 'v403-hardening'
  $oc=$LASTEXITCODE
  if($oc -ne 0){Write-Host ('3EN v4.1.3 OPENCLAW FAILED code='+$oc) -ForegroundColor Yellow; return}
  $ocSum=Join-Path $root 'runs\project-2026-09-09-v413-openclaw-acceptance.summary.json'
  if(-not(Test-Path $ocSum)){throw 'V413_SUMMARY_MISSING'}
  $os=Get-Content $ocSum -Raw | ConvertFrom-Json
  $okCount=[int]$os.counts.success+[int]$os.counts.recovered
  if(-not [bool]$os.accepted -or $okCount -ne 3 -or [int]$os.counts.failed -ne 0 -or [int]$os.counts.blocked -ne 0){throw 'V413_SUMMARY_INVALID'}
  Write-Host '3EN v4.1.3 OPENCLAW BRIDGE ACCEPTED' -ForegroundColor Green
} catch {
  Write-Host ('3EN R5 FAILED: '+$_.Exception.Message) -ForegroundColor Yellow
}
