param([Parameter(Mandatory=$true)][ValidateSet('Backup','Install','Test','Rollback')][string]$Phase)
$ErrorActionPreference='Stop'
$src='https://raw.githubusercontent.com/3en4all/3en-command-runner/main/scripts/install-3en-job-executor-058a11.ps1'
$dst='C:\3EN-Agent\install-3en-job-executor-058a12-engine.ps1'
$wrapper=(Invoke-WebRequest -UseBasicParsing -Uri ($src+'?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -TimeoutSec 20).Content
if([string]::IsNullOrWhiteSpace($wrapper)){throw '058A12_SOURCE_EMPTY'}
# Rebuild directly from 058a8 to avoid nested wrappers.
$base=(Invoke-WebRequest -UseBasicParsing -Uri ('https://raw.githubusercontent.com/3en4all/3en-command-runner/main/scripts/install-3en-job-executor-058a8.ps1?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -TimeoutSec 20).Content
$base=$base.Replace('058A8','058A12').Replace('058a8','058a12').Replace('V4617','V4621')
$old="function Invoke-CapturedCmd([string]`$Tag,[string]`$Command,[bool]`$AllowFail=`$false,[int]`$TimeoutSec=25){"
$new="function Invoke-CapturedCmd([string]`$Tag,[string]`$Command,[bool]`$AllowFail=`$false,[int]`$TimeoutSec=25,[string]`$WorkingDirectory=''){"
if(-not $base.Contains($old)){throw '058A12_SIGNATURE_TARGET_MISSING'}
$base=$base.Replace($old,$new)
$base=$base.Replace('  $psi.RedirectStandardError=$true',"  `$psi.RedirectStandardError=`$true`r`n  if(-not[string]::IsNullOrWhiteSpace(`$WorkingDirectory)){if(-not(Test-Path -LiteralPath `$WorkingDirectory)){throw (`$Tag+'_WORKDIR_MISSING_'+`$WorkingDirectory)};`$psi.WorkingDirectory=`$WorkingDirectory}")
$oldNpm="`$npm=Invoke-CapturedCmd '058A12_NPM' 'npm.cmd install --omit=dev --no-audit --no-fund' `$false 35;`$syntax=Invoke-CapturedCmd '058A12_NODE_CHECK' 'node.exe --check index.js' `$false 10"
$newNpm="`$npm=Invoke-CapturedCmd '058A12_NPM' 'npm.cmd install typebox@1.1.39 --no-save --legacy-peer-deps --ignore-scripts --no-audit --no-fund' `$false 55 `$PluginRoot;`$syntax=Invoke-CapturedCmd '058A12_NODE_CHECK' 'node.exe --check index.js' `$false 10 `$PluginRoot"
if(-not $base.Contains($oldNpm)){throw '058A12_NPM_TARGET_MISSING'}
$base=$base.Replace($oldNpm,$newNpm)
$oldBlock=@"
  if(`$list.Text -match '3en-job-executor'){`$un=Invoke-CapturedCmd '058A12_UNINSTALL' 'openclaw.cmd plugins uninstall 3en-job-executor --keep-files --force' `$true 12}
  `$flags=@('-l','"'+`$PluginRoot+'"');if(`$installHelp.Text -match '--accept-capabilities'){`$flags+='--accept-capabilities'};if(`$installHelp.Text -match '--acknowledge-install-policy-warning'){`$flags+='--acknowledge-install-policy-warning'}
  Write-Output ('V4621_058A12_SELECTED_INSTALL_FLAGS='+(`$flags -join ' '))
  `$ins=Invoke-CapturedCmd '058A12_INSTALL' ('openclaw.cmd plugins install '+(`$flags -join ' ')) `$false 20
"@
$newBlock=@"
  `$flags=@('-l','"'+`$PluginRoot+'"');if(`$installHelp.Text -match '--accept-capabilities'){`$flags+='--accept-capabilities'};if(`$installHelp.Text -match '--acknowledge-install-policy-warning'){`$flags+='--acknowledge-install-policy-warning'}
  if(`$list.Text -match '3en-job-executor'){
    Write-Output 'V4621_058A12_PLUGIN_ALREADY_REGISTERED=TRUE;UNINSTALL_SKIPPED=true;INSTALL_SKIPPED=true'
  } else {
    Write-Output ('V4621_058A12_SELECTED_INSTALL_FLAGS='+(`$flags -join ' '))
    `$ins=Invoke-CapturedCmd '058A12_INSTALL' ('openclaw.cmd plugins install '+(`$flags -join ' ')) `$false 20
  }
"@
if(-not $base.Contains($oldBlock)){throw '058A12_INSTALL_BLOCK_TARGET_MISSING'}
$base=$base.Replace($oldBlock,$newBlock)
Set-Content -LiteralPath $dst -Value $base -Encoding UTF8
$tok=$null;$err=$null;[System.Management.Automation.Language.Parser]::ParseFile($dst,[ref]$tok,[ref]$err)|Out-Null
if(@($err).Count -gt 0){throw ('058A12_ENGINE_SYNTAX_ERRORS='+@($err).Count)}
Write-Host '058A12_ENGINE_BUILD=PASS;REUSE_REGISTERED_PLUGIN=true;UNINSTALL_REMOVED=true'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dst -Phase $Phase
if($LASTEXITCODE -ne 0){throw ('058A12_ENGINE_EXIT_'+$LASTEXITCODE)}
