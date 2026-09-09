$ErrorActionPreference='Stop'
$root='C:\3EN-Agent'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$runner402=Join-Path $root '3en-agent-runner-v4.0.2.ps1'
$runner403=Join-Path $root '3en-agent-runner-v4.0.3.ps1'

function Get-Raw([string]$path,[string]$out,[string]$ref='v403-hardening') {
  $u='https://raw.githubusercontent.com/3en4all/3en-command-runner/'+$ref+'/'+$path+'?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $out
}
function Assert-Syntax([string]$path) {
  $t=$null;$e=$null;[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$t,[ref]$e)|Out-Null
  if(@($e).Count -gt 0){throw ('SYNTAX_ERRORS '+$path+' count='+@($e).Count)}
}
function Read-Summary([string]$projectId) {
  $p=Join-Path $root ('runs\project-'+$projectId+'.summary.json')
  if(-not(Test-Path $p)){throw ('SUMMARY_MISSING '+$projectId)}
  return (Get-Content $p -Raw | ConvertFrom-Json)
}

Write-Host '3EN v4.0.3 + v4.1.3 FULL RECOVERY START' -ForegroundColor Cyan

Get-Raw '3en-agent-runner-v4.0.2.ps1' $runner402 'main'
Assert-Syntax $runner402

& $runner402 -ProjectPath 'project-v4.0.3-hardening-retry.json' -Branch 'v403-hardening'
$code=$LASTEXITCODE
if($code -ne 0){Write-Host ('3EN v4.0.3 HARDENING FAILED code='+$code) -ForegroundColor Yellow; return}
if(-not(Test-Path $runner403)){Write-Host '3EN v4.0.3 RUNNER MISSING' -ForegroundColor Yellow; return}
Assert-Syntax $runner403
Write-Host '3EN v4.0.3 HARDENING BUILD PASS' -ForegroundColor Green

# Fresh regression state so the first pass executes the sentinel.
$state=Join-Path $root '3en-project.state.json'
if(Test-Path $state){
  try{$s=Get-Content $state -Raw|ConvertFrom-Json; if([string]$s.projectId -eq '2026-09-09-v403-resume-regression'){Remove-Item $state -Force}}catch{}
}

& $runner403 -ProjectPath 'project-v4.0.3-resume-regression.json' -Branch 'v403-hardening'
$c1=$LASTEXITCODE
if($c1 -ne 0){Write-Host ('3EN v4.0.3 REGRESSION PASS1 FAILED code='+$c1) -ForegroundColor Yellow; return}
$s1=Read-Summary '2026-09-09-v403-resume-regression'
if(-not $s1.accepted -or [int]$s1.counts.failed -ne 1){Write-Host '3EN v4.0.3 REGRESSION PASS1 SUMMARY INVALID' -ForegroundColor Yellow; return}

& $runner403 -ProjectPath 'project-v4.0.3-resume-regression.json' -Branch 'v403-hardening'
$c2=$LASTEXITCODE
if($c2 -ne 0){Write-Host ('3EN v4.0.3 REGRESSION PASS2 FAILED code='+$c2) -ForegroundColor Yellow; return}
$s2=Read-Summary '2026-09-09-v403-resume-regression'
if(-not $s2.accepted -or [int]$s2.counts.failed -ne 1){Write-Host '3EN v4.0.3 RESUME VERDICT REGRESSION FAILED' -ForegroundColor Yellow; return}
Write-Host '3EN v4.0.3 RESUME VERDICT REGRESSION PASS' -ForegroundColor Green

# Fresh project id means no stale 049/050/051 resume state can contaminate this acceptance.
& $runner403 -ProjectPath 'project-v4.1.3-openclaw-acceptance.json' -Branch 'v403-hardening'
$c3=$LASTEXITCODE
if($c3 -ne 0){Write-Host ('3EN v4.1.3 OPENCLAW ACCEPTANCE FAILED code='+$c3) -ForegroundColor Yellow; return}
$s3=Read-Summary '2026-09-09-v413-openclaw-acceptance'
if(-not $s3.accepted -or [int]$s3.counts.failed -ne 0 -or [int]$s3.counts.blocked -ne 0 -or ([int]$s3.counts.success+[int]$s3.counts.recovered) -ne 3){Write-Host '3EN v4.1.3 SUMMARY INVALID' -ForegroundColor Yellow; return}
Write-Host '3EN v4.0.3 HARDENING PASS' -ForegroundColor Green
Write-Host '3EN v4.1.3 OPENCLAW BRIDGE ACCEPTED' -ForegroundColor Green
