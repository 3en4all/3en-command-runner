param([Parameter(Mandatory=$true)][ValidateSet('Backup','Install','Test','Rollback')][string]$Phase)
$ErrorActionPreference='Stop'
$BaseUrl='https://raw.githubusercontent.com/3en4all/3en-command-runner/main/scripts/install-3en-job-executor-058a10.ps1'
$Wrapper='C:\3EN-Agent\install-3en-job-executor-058a11-base.ps1'
$Engine='C:\3EN-Agent\install-3en-job-executor-058a11-engine.ps1'

$raw=(Invoke-WebRequest -UseBasicParsing -Uri ($BaseUrl+'?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -TimeoutSec 20).Content
if([string]::IsNullOrWhiteSpace($raw)){throw '058A11_SOURCE_EMPTY'}
$raw=$raw.Replace('058A10','058A11').Replace('058a10','058a11').Replace('V4619','V4620')
# Materialize the prior wrapper, but point it at a local patched 058a8-derived engine source.
$base058a8=(Invoke-WebRequest -UseBasicParsing -Uri ('https://raw.githubusercontent.com/3en4all/3en-command-runner/main/scripts/install-3en-job-executor-058a8.ps1?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -TimeoutSec 20).Content
$base058a8=$base058a8.Replace('058A8','058A11').Replace('058a8','058a11').Replace('V4617','V4620')
$old="function Invoke-CapturedCmd([string]`$Tag,[string]`$Command,[bool]`$AllowFail=`$false,[int]`$TimeoutSec=25){"
$new="function Invoke-CapturedCmd([string]`$Tag,[string]`$Command,[bool]`$AllowFail=`$false,[int]`$TimeoutSec=25,[string]`$WorkingDirectory=''){"
if(-not $base058a8.Contains($old)){throw '058A11_SIGNATURE_TARGET_MISSING'}
$base058a8=$base058a8.Replace($old,$new)
$old2='  $psi.RedirectStandardError=$true'
$new2="  `$psi.RedirectStandardError=`$true`r`n  if(-not[string]::IsNullOrWhiteSpace(`$WorkingDirectory)){if(-not(Test-Path -LiteralPath `$WorkingDirectory)){throw (`$Tag+'_WORKDIR_MISSING_'+`$WorkingDirectory)};`$psi.WorkingDirectory=`$WorkingDirectory}"
$base058a8=$base058a8.Replace($old2,$new2)
$old3="`$npm=Invoke-CapturedCmd '058A11_NPM' 'npm.cmd install --omit=dev --no-audit --no-fund' `$false 35;`$syntax=Invoke-CapturedCmd '058A11_NODE_CHECK' 'node.exe --check index.js' `$false 10"
$new3="`$npm=Invoke-CapturedCmd '058A11_NPM' 'npm.cmd install typebox@1.1.39 --no-save --legacy-peer-deps --ignore-scripts --no-audit --no-fund' `$false 55 `$PluginRoot;`$syntax=Invoke-CapturedCmd '058A11_NODE_CHECK' 'node.exe --check index.js' `$false 10 `$PluginRoot"
if(-not $base058a8.Contains($old3)){throw '058A11_NPM_CALL_TARGET_MISSING'}
$base058a8=$base058a8.Replace($old3,$new3)
Set-Content -LiteralPath $Engine -Value $base058a8 -Encoding UTF8
$tok=$null;$err=$null;[System.Management.Automation.Language.Parser]::ParseFile($Engine,[ref]$tok,[ref]$err)|Out-Null
if(@($err).Count -gt 0){throw ('058A11_ENGINE_SYNTAX_ERRORS='+@($err).Count)}
if((Get-Content $Engine -Raw) -notmatch 'typebox@1\.1\.39 --no-save --legacy-peer-deps'){throw '058A11_TARGETED_NPM_VERIFY_FAIL'}
Write-Host '058A11_ENGINE_BUILD=PASS;EXPLICIT_CHILD_WORKDIR=true;TARGETED_TYPEBOX_INSTALL=true'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Engine -Phase $Phase
if($LASTEXITCODE -ne 0){throw ('058A11_ENGINE_EXIT_'+$LASTEXITCODE)}
