param([Parameter(Mandatory=$true)][ValidateSet('Backup','Install','Test','Rollback')][string]$Phase)
$ErrorActionPreference='Stop'
$BaseUrl='https://raw.githubusercontent.com/3en4all/3en-command-runner/main/scripts/install-3en-job-executor-058a8.ps1'
$Engine='C:\3EN-Agent\install-3en-job-executor-058a10-engine.ps1'

function Build-Engine {
  $raw=(Invoke-WebRequest -UseBasicParsing -Uri ($BaseUrl+'?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -TimeoutSec 20).Content
  if([string]::IsNullOrWhiteSpace($raw)){throw '058A10_SOURCE_EMPTY'}
  $raw=$raw.Replace('058A8','058A10').Replace('058a8','058a10').Replace('V4617','V4619')
  $old="function Invoke-CapturedCmd([string]`$Tag,[string]`$Command,[bool]`$AllowFail=`$false,[int]`$TimeoutSec=25){"
  $new="function Invoke-CapturedCmd([string]`$Tag,[string]`$Command,[bool]`$AllowFail=`$false,[int]`$TimeoutSec=25,[string]`$WorkingDirectory=''){"
  if(-not $raw.Contains($old)){throw '058A10_SIGNATURE_PATCH_TARGET_MISSING'}
  $raw=$raw.Replace($old,$new)
  $old2='  $psi.RedirectStandardError=$true'
  $new2="  `$psi.RedirectStandardError=`$true`r`n  if(-not[string]::IsNullOrWhiteSpace(`$WorkingDirectory)){if(-not(Test-Path -LiteralPath `$WorkingDirectory)){throw (`$Tag+'_WORKDIR_MISSING_'+`$WorkingDirectory)};`$psi.WorkingDirectory=`$WorkingDirectory}"
  if(-not $raw.Contains($old2)){throw '058A10_PSI_PATCH_TARGET_MISSING'}
  $raw=$raw.Replace($old2,$new2)
  $old3="`$npm=Invoke-CapturedCmd '058A10_NPM' 'npm.cmd install --omit=dev --no-audit --no-fund' `$false 35;`$syntax=Invoke-CapturedCmd '058A10_NODE_CHECK' 'node.exe --check index.js' `$false 10"
  $new3="`$npm=Invoke-CapturedCmd '058A10_NPM' 'npm.cmd install --omit=dev --no-audit --no-fund' `$false 35 `$PluginRoot;`$syntax=Invoke-CapturedCmd '058A10_NODE_CHECK' 'node.exe --check index.js' `$false 10 `$PluginRoot"
  if(-not $raw.Contains($old3)){throw '058A10_CALL_PATCH_TARGET_MISSING'}
  $raw=$raw.Replace($old3,$new3)
  Set-Content -LiteralPath $Engine -Value $raw -Encoding UTF8
  $tok=$null;$err=$null;[System.Management.Automation.Language.Parser]::ParseFile($Engine,[ref]$tok,[ref]$err)|Out-Null
  if(@($err).Count -gt 0){throw ('058A10_ENGINE_SYNTAX_ERRORS='+@($err).Count)}
  if((Get-Content -LiteralPath $Engine -Raw) -notmatch 'WorkingDirectory=\$WorkingDirectory'){throw '058A10_WORKDIR_PATCH_VERIFY_FAIL'}
  Write-Host '058A10_ENGINE_BUILD=PASS;EXPLICIT_CHILD_WORKDIR=true'
}

Build-Engine
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Engine -Phase $Phase
if($LASTEXITCODE -ne 0){throw ('058A10_ENGINE_EXIT_'+$LASTEXITCODE)}
