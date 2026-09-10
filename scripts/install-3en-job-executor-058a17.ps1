param([Parameter(Mandatory=$true)][ValidateSet('Backup','Install','Test','Rollback')][string]$Phase)
$ErrorActionPreference='Stop'
$src='https://raw.githubusercontent.com/3en4all/3en-command-runner/main/scripts/install-3en-job-executor-058a13.ps1'
$dst='C:\3EN-Agent\install-3en-job-executor-058a17-engine.ps1'
$raw=(Invoke-WebRequest -UseBasicParsing -Uri ($src+'?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -TimeoutSec 20).Content
if([string]::IsNullOrWhiteSpace($raw)){throw '058A17_SOURCE_EMPTY'}
$raw=$raw.Replace('058A13','058A17').Replace('058a13','058a17')
$pattern="(?s)  if\(Test-Path \$PluginRoot\)\{Remove-Item \$PluginRoot -Recurse -Force\};New-Item -ItemType Directory -Force -Path \$PluginRoot\|Out-Null\s+  foreach\(\$f in @\('package\.json','openclaw\.plugin\.json','index\.js'\)\)\{.*?\}\s+  \$npm=Invoke-Bounded '058A17_NPM'.*?\s+  \$node=Invoke-Bounded '058A17_NODE_CHECK'.*?\r?\n"
$replacement=@"
  if(-not(Test-Path `$PluginRoot)){New-Item -ItemType Directory -Force -Path `$PluginRoot|Out-Null}
  `$typebox=Join-Path `$PluginRoot 'node_modules\typebox\package.json';if(-not(Test-Path `$typebox)){throw '058A17_LOCAL_TYPEBOX_MISSING'}
  foreach(`$f in @('package.json','openclaw.plugin.json','index.js')){`$u='https://raw.githubusercontent.com/3en4all/3en-command-runner/'+`$SourceRef+'/openclaw-plugins/3en-job-executor/'+`$f;Invoke-WebRequest -UseBasicParsing -Uri `$u -OutFile (Join-Path `$PluginRoot `$f) -TimeoutSec 15}
  if(-not(Test-Path (Join-Path `$PluginRoot 'index.js'))){throw '058A17_INDEX_MISSING'}
  Write-Host '058A17_DEPENDENCY_REUSE=PASS;NPM_SKIPPED=true;NODE_SKIPPED=true'
"@
$rx=[regex]::new($pattern,[System.Text.RegularExpressions.RegexOptions]::Singleline)
$patched=$rx.Replace($raw,$replacement,1)
if($patched -eq $raw){throw '058A17_REGEX_PATCH_TARGET_MISSING'}
Set-Content -LiteralPath $dst -Value $patched -Encoding UTF8
$tok=$null;$err=$null;[System.Management.Automation.Language.Parser]::ParseFile($dst,[ref]$tok,[ref]$err)|Out-Null;if(@($err).Count){throw ('058A17_ENGINE_SYNTAX_ERRORS='+@($err).Count)}
Write-Host '058A17_ENGINE_BUILD=PASS;NO_NPM=true;NO_NODE=true;NO_PLUGIN_MANAGER_CLI=true;DIRECT_CONFIG=true'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dst -Phase $Phase
if($LASTEXITCODE -ne0){throw ('058A17_ENGINE_EXIT_'+$LASTEXITCODE)}
