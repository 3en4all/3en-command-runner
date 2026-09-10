param([Parameter(Mandatory=$true)][ValidateSet('Backup','Install','Test','Rollback')][string]$Phase)
$ErrorActionPreference='Stop'
$src='https://raw.githubusercontent.com/3en4all/3en-command-runner/main/scripts/install-3en-job-executor-058a13.ps1'
$dst='C:\3EN-Agent\install-3en-job-executor-058a14-engine.ps1'
$raw=(Invoke-WebRequest -UseBasicParsing -Uri ($src+'?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -TimeoutSec 20).Content
if([string]::IsNullOrWhiteSpace($raw)){throw '058A14_SOURCE_EMPTY'}
$raw=$raw.Replace('058A13','058A14').Replace('058a13','058a14')
$old=@"
  if(Test-Path `$PluginRoot){Remove-Item `$PluginRoot -Recurse -Force};New-Item -ItemType Directory -Force -Path `$PluginRoot|Out-Null
  foreach(`$f in @('package.json','openclaw.plugin.json','index.js')){`$u='https://raw.githubusercontent.com/3en4all/3en-command-runner/'+`$SourceRef+'/openclaw-plugins/3en-job-executor/'+`$f;Invoke-WebRequest -UseBasicParsing -Uri `$u -OutFile (Join-Path `$PluginRoot `$f) -TimeoutSec 15}
  `$npm=Invoke-Bounded '058A14_NPM' 'npm.cmd' 'install typebox@1.1.39 --no-save --legacy-peer-deps --ignore-scripts --no-audit --no-fund' 55 `$PluginRoot;if(`$npm.Exit-ne0){throw ('058A14_NPM_EXIT_'+`$npm.Exit)}
  `$node=Invoke-Bounded '058A14_NODE_CHECK' 'node.exe' '--check index.js' 10 `$PluginRoot;if(`$node.Exit-ne0){throw ('058A14_NODE_EXIT_'+`$node.Exit)}
"@
$new=@"
  if(-not(Test-Path `$PluginRoot)){New-Item -ItemType Directory -Force -Path `$PluginRoot|Out-Null}
  `$typebox=Join-Path `$PluginRoot 'node_modules\typebox\package.json';if(-not(Test-Path `$typebox)){throw '058A14_LOCAL_TYPEBOX_MISSING'}
  foreach(`$f in @('package.json','openclaw.plugin.json','index.js')){`$u='https://raw.githubusercontent.com/3en4all/3en-command-runner/'+`$SourceRef+'/openclaw-plugins/3en-job-executor/'+`$f;Invoke-WebRequest -UseBasicParsing -Uri `$u -OutFile (Join-Path `$PluginRoot `$f) -TimeoutSec 15}
  `$node=Invoke-Bounded '058A14_NODE_CHECK' 'node.exe' '--check index.js' 10 `$PluginRoot;if(`$node.Exit-ne0){throw ('058A14_NODE_EXIT_'+`$node.Exit)}
  Write-Host '058A14_DEPENDENCY_REUSE=PASS;NPM_SKIPPED=true'
"@
if(-not$raw.Contains($old)){throw '058A14_INSTALL_PATCH_TARGET_MISSING'}
$raw=$raw.Replace($old,$new)
Set-Content -LiteralPath $dst -Value $raw -Encoding UTF8
$tok=$null;$err=$null;[System.Management.Automation.Language.Parser]::ParseFile($dst,[ref]$tok,[ref]$err)|Out-Null;if(@($err).Count){throw ('058A14_ENGINE_SYNTAX_ERRORS='+@($err).Count)}
Write-Host '058A14_ENGINE_BUILD=PASS;NPM_REMOVED=true;DIRECT_CONFIG=true'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dst -Phase $Phase
if($LASTEXITCODE -ne0){throw ('058A14_ENGINE_EXIT_'+$LASTEXITCODE)}
