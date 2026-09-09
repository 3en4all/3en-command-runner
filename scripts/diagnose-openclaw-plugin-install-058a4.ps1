param([Parameter(Mandatory=$true)][ValidateSet('Run','Test')][string]$Phase)
$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent\workbench\diag-058a4'
$Evidence=Join-Path $Root 'plugin-install-diagnostic.json'
$PluginRoot='C:\3EN-Agent\openclaw-plugins\3en-job-executor'
function Run-Cmd([string]$Name,[string]$Command){
  $psi=New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName='cmd.exe';$psi.Arguments='/d /s /c "'+$Command.Replace('"','\"')+'"';$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true
  $p=New-Object System.Diagnostics.Process;$p.StartInfo=$psi;[void]$p.Start();$o=$p.StandardOutput.ReadToEnd();$e=$p.StandardError.ReadToEnd();if(-not$p.WaitForExit(60000)){try{& taskkill.exe /PID $p.Id /T /F|Out-Null}catch{};return [pscustomobject]@{name=$Name;exit=124;stdout=$o;stderr=$e;timedOut=$true}}
  [pscustomobject]@{name=$Name;exit=[int]$p.ExitCode;stdout=$o;stderr=$e;timedOut=$false}
}
if($Phase-eq'Run'){
  if(Test-Path $Root){Remove-Item $Root -Recurse -Force};New-Item -ItemType Directory -Force -Path $Root|Out-Null
  $rows=@()
  $rows+=Run-Cmd 'version' 'openclaw.cmd --version'
  $rows+=Run-Cmd 'doctor' 'openclaw.cmd plugins doctor --json'
  $rows+=Run-Cmd 'list' 'openclaw.cmd plugins list --json'
  if(Test-Path (Join-Path $PluginRoot 'index.js')){$rows+=Run-Cmd 'node_check' ('node.exe --check "'+(Join-Path $PluginRoot 'index.js')+'"')}
  if(Test-Path (Join-Path $PluginRoot 'package.json')){$rows+=Run-Cmd 'npm_ls' ('cd /d "'+$PluginRoot+'" && npm.cmd ls --depth=0')}
  if(Test-Path $PluginRoot){$rows+=Run-Cmd 'install_probe' ('openclaw.cmd plugins install -l "'+$PluginRoot+'" --force --accept-capabilities --acknowledge-install-policy-warning')}
  $safe=@();foreach($r in $rows){$so=[string]$r.stdout;$se=[string]$r.stderr;$so=$so -replace '(?i)(Bearer\s+)[A-Za-z0-9._-]+','$1<redacted>';$se=$se -replace '(?i)(Bearer\s+)[A-Za-z0-9._-]+','$1<redacted>';$safe+=[ordered]@{name=$r.name;exit=$r.exit;timedOut=$r.timedOut;stdout=$so;stderr=$se}}
  [ordered]@{schemaVersion=1;status='COLLECTED';pluginRoot=$PluginRoot;results=$safe;collectedAt=(Get-Date).ToString('o')}|ConvertTo-Json -Depth 10|Set-Content $Evidence -Encoding UTF8
  foreach($r in $safe){Write-Output ('V4613_058A4_'+$r.name.ToUpper()+'_EXIT='+$r.exit+';TIMEOUT='+$r.timedOut);if($r.exit-ne0){$msg=(($r.stdout+' '+$r.stderr)-replace '[\r\n]+',' ');if($msg.Length-gt600){$msg=$msg.Substring(0,600)};Write-Output ('V4613_058A4_'+$r.name.ToUpper()+'_ERROR='+$msg)}}
}
if($Phase-eq'Test'){
  if(-not(Test-Path $Evidence)){throw '058A4_EVIDENCE_MISSING'};$e=Get-Content $Evidence -Raw|ConvertFrom-Json
  $v=@($e.results|Where-Object{$_.name-eq'version'});$d=@($e.results|Where-Object{$_.name-eq'doctor'});$i=@($e.results|Where-Object{$_.name-eq'install_probe'})
  if($v.Count-ne1 -or $d.Count-ne1 -or $i.Count-ne1){throw '058A4_REQUIRED_PROBES_MISSING'}
  if([int]$v[0].exit-ne0){throw '058A4_VERSION_PROBE_FAILED'}
  Write-Output ('V4613_058A4_TEST=PASS;VERSION_EXIT='+$v[0].exit+';DOCTOR_EXIT='+$d[0].exit+';INSTALL_EXIT='+$i[0].exit)
}
