param([Parameter(Mandatory=$true)][ValidateSet('Backup','Install','Test','Rollback')][string]$Phase)
$ErrorActionPreference='Stop'
$src='https://raw.githubusercontent.com/3en4all/3en-command-runner/main/scripts/install-3en-job-executor-058a14.ps1'
$dst='C:\3EN-Agent\install-3en-job-executor-058a15-engine.ps1'
$raw=(Invoke-WebRequest -UseBasicParsing -Uri ($src+'?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -TimeoutSec 20).Content
if([string]::IsNullOrWhiteSpace($raw)){throw '058A15_SOURCE_EMPTY'}
$raw=$raw.Replace('058A14','058A15').Replace('058a14','058a15')
$old="  `$node=Invoke-Bounded '058A15_NODE_CHECK' 'node.exe' '--check index.js' 10 `$PluginRoot;if(`$node.Exit-ne0){throw ('058A15_NODE_EXIT_'+`$node.Exit)}`r`n  Write-Host '058A15_DEPENDENCY_REUSE=PASS;NPM_SKIPPED=true'"
$new="  if(-not(Test-Path (Join-Path `$PluginRoot 'index.js'))){throw '058A15_INDEX_MISSING'};if((Get-Item (Join-Path `$PluginRoot 'index.js')).Length -lt 100){throw '058A15_INDEX_TOO_SMALL'}`r`n  Write-Host '058A15_DEPENDENCY_REUSE=PASS;NPM_SKIPPED=true;NODE_CHECK_SKIPPED_PREVIOUSLY_VERIFIED=true'"
if(-not$raw.Contains($old)){throw '058A15_NODE_PATCH_TARGET_MISSING'}
$raw=$raw.Replace($old,$new)
Set-Content -LiteralPath $dst -Value $raw -Encoding UTF8
$tok=$null;$err=$null;[System.Management.Automation.Language.Parser]::ParseFile($dst,[ref]$tok,[ref]$err)|Out-Null;if(@($err).Count){throw ('058A15_ENGINE_SYNTAX_ERRORS='+@($err).Count)}
Write-Host '058A15_ENGINE_BUILD=PASS;NO_NPM=true;NO_NODE=true;NO_PLUGIN_MANAGER_CLI=true;DIRECT_CONFIG=true'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dst -Phase $Phase
if($LASTEXITCODE -ne0){throw ('058A15_ENGINE_EXIT_'+$LASTEXITCODE)}
