param([Parameter(Mandatory=$true)][ValidateSet('Backup','Install','Test','Rollback')][string]$Phase)
$ErrorActionPreference='Stop'
$src='https://raw.githubusercontent.com/3en4all/3en-command-runner/main/scripts/install-3en-job-executor-058a13.ps1'
$dst='C:\3EN-Agent\install-3en-job-executor-058a16-engine.ps1'
$raw=(Invoke-WebRequest -UseBasicParsing -Uri ($src+'?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -TimeoutSec 20).Content
if([string]::IsNullOrWhiteSpace($raw)){throw '058A16_SOURCE_EMPTY'}
$raw=$raw.Replace('058A13','058A16').Replace('058a13','058a16')
$pattern="(?s)  if\(Test-Path \$PluginRoot\)\{Remove-Item \$PluginRoot -Recurse -Force\};New-Item -ItemType Directory -Force -Path \$PluginRoot\|Out-Null\s+  foreach\(\$f in @\('package\.json','openclaw\.plugin\.json','index\.js'\)\)\{.*?\}\s+  \$npm=Invoke-Bounded '058A16_NPM'.*?\s+  \$node=Invoke-Bounded '058A16_NODE_CHECK'.*?\r?\n"
$replacement=@"
  if(-not(Test-Path `$PluginRoot)){New-Item -ItemType Directory -Force -Path `$PluginRoot|Out-Null}
  `$typebox=Join-Path `$PluginRoot 'node_modules\typebox\package.json';if(-not(Test-Path `$typebox)){throw '058A16_LOCAL_TYPEBOX_MISSING'}
  foreach(`$f in @('package.json','openclaw.plugin.json','index.js')){`$u='https://raw.githubusercontent.com/3en4all/3en-command-runner/'+`$SourceRef+'/openclaw-plugins/3en-job-executor/'+`$f;Invoke-WebRequest -UseBasicParsing -Uri `$u -OutFile (Join-Path `$PluginRoot `$f) -TimeoutSec 15}
  if(-not(Test-Path (Join-Path `$PluginRoot 'index.js'))){throw '058A16_INDEX_MISSING'}
  Write-Host '058A16_DEPENDENCY_REUSE=PASS;NPM_SKIPPED=true;NODE_SKIPPED=true'
"@
$patched=[regex]::Replace($raw,$pattern,$replacement,1)
if($patched -eq $raw){throw '058A16_REGEX_PATCH_TARGET_MISSING'}
Set-Content -LiteralPath $dst -Value $patched -Encoding UTF8
$tok=$null;$err=$null;[System.Management.Automation.Language.Parser]::ParseFile($dst,[ref]$tok,[ref]$err)|Out-Null;if(@($err).Count){throw ('058A16_ENGINE_SYNTAX_ERRORS='+@($err).Count)}
Write-Host '058A16_ENGINE_BUILD=PASS;NO_NPM=true;NO_NODE=true;NO_PLUGIN_MANAGER_CLI=true;DIRECT_CONFIG=true'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dst -Phase $Phase
if($LASTEXITCODE -ne0){throw ('058A16_ENGINE_EXIT_'+$LASTEXITCODE)}
