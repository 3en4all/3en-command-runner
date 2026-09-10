param([Parameter(Mandatory=$true)][ValidateSet('Backup','Install','Test','Rollback')][string]$Phase)
$ErrorActionPreference='Stop'
$PluginId='3en-job-executor'
$PluginRoot='C:\3EN-Agent\openclaw-plugins\3en-job-executor'
$Work='C:\3EN-Agent\workbench\plugin-acceptance-058a13'
$Config=Join-Path $env:USERPROFILE '.openclaw\openclaw.json'
$ConfigBackup=Join-Path $Work 'openclaw.before.json'
$PluginBackup=Join-Path $Work 'plugin.before'
$Target=Join-Path $Work 'target.json'
$Evidence=Join-Path $Work 'acceptance.json'
$SourceRef='ca2a16b8b4dc1519cc054fb9e6a15b17628315bc'

function Ensure-Prop($Obj,[string]$Name,$Value){
  $p=$Obj.PSObject.Properties[$Name]
  if($null-eq$p){$Obj|Add-Member -NotePropertyName $Name -NotePropertyValue $Value}else{$p.Value=$Value}
}
function Invoke-Bounded([string]$Tag,[string]$File,[string]$Args,[int]$TimeoutSec,[string]$Cwd=''){
  $psi=New-Object System.Diagnostics.ProcessStartInfo;$psi.FileName=$File;$psi.Arguments=$Args;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
  if($Cwd){$psi.WorkingDirectory=$Cwd}
  $p=New-Object System.Diagnostics.Process;$p.StartInfo=$psi;if(-not$p.Start()){throw ($Tag+'_START_FAILED')}
  $ot=$p.StandardOutput.ReadToEndAsync();$et=$p.StandardError.ReadToEndAsync();$ok=$p.WaitForExit($TimeoutSec*1000)
  if(-not$ok){try{& taskkill.exe /PID $p.Id /T /F 2>$null|Out-Null}catch{};Write-Host ($Tag+'_TIMEOUT='+$TimeoutSec+'S');return [pscustomobject]@{Exit=124;TimedOut=$true;Text=''}}
  $txt=(($ot.Result,$et.Result|Where-Object{$_})-join "`n").Trim();foreach($l in ($txt-split '[\r\n]+')){if($l){Write-Host ($Tag+'='+$l)}}
  [pscustomobject]@{Exit=[int]$p.ExitCode;TimedOut=$false;Text=$txt}
}
function GatewayContext{
  $c=Get-Content $Config -Raw|ConvertFrom-Json;$port=18789;if($c.gateway.port){$port=[int]$c.gateway.port};$mode='token';if($c.gateway.auth.mode){$mode=[string]$c.gateway.auth.mode};$secret=''
  if($mode-eq'token'){$secret=[string]$env:OPENCLAW_GATEWAY_TOKEN;if(-not$secret-and$c.gateway.auth.token){$secret=[string]$c.gateway.auth.token}}
  elseif($mode-eq'password'){$secret=[string]$env:OPENCLAW_GATEWAY_PASSWORD;if(-not$secret-and$c.gateway.auth.password){$secret=[string]$c.gateway.auth.password}}
  if($mode-ne'none'-and-not$secret){throw '058A13_GATEWAY_SECRET_UNAVAILABLE'}
  [pscustomobject]@{Port=$port;Mode=$mode;Secret=$secret}
}
function Wait-Gateway([int]$Seconds=10){$g=GatewayContext;$d=(Get-Date).AddSeconds($Seconds);do{$tcp=New-Object Net.Sockets.TcpClient;try{$ar=$tcp.BeginConnect('127.0.0.1',$g.Port,$null,$null);if($ar.AsyncWaitHandle.WaitOne(700)){try{$tcp.EndConnect($ar);if($tcp.Connected){return $true}}catch{}}}finally{$tcp.Close()};Start-Sleep -Milliseconds 400}while((Get-Date)-lt$d);return $false}
function Invoke-Tool([object]$Args){$g=GatewayContext;$h=@{};if($g.Mode-ne'none'){$h.Authorization='Bearer '+$g.Secret};$b=[ordered]@{tool='3en_job';args=$Args;sessionKey='main';idempotencyKey=('058a13-'+[guid]::NewGuid().ToString('N'))}|ConvertTo-Json -Depth 10;try{$r=Invoke-RestMethod -Method Post -Uri ('http://127.0.0.1:'+$g.Port+'/tools/invoke') -Headers $h -ContentType 'application/json' -Body $b -TimeoutSec 8;[pscustomobject]@{http=200;ok=if($null-ne$r.ok){[bool]$r.ok}else{$true};raw=$r}}catch{$s=-1;try{$s=[int]$_.Exception.Response.StatusCode}catch{};[pscustomobject]@{http=$s;ok=$false;raw=$null}}}
function Set-PluginConfig{
  if(-not(Test-Path $Config)){throw '058A13_OPENCLAW_CONFIG_MISSING'}
  $c=Get-Content $Config -Raw|ConvertFrom-Json
  if($null-eq$c.plugins){Ensure-Prop $c 'plugins' ([pscustomobject]@{})};Ensure-Prop $c.plugins 'enabled' $true
  if($null-eq$c.plugins.load){Ensure-Prop $c.plugins 'load' ([pscustomobject]@{})}
  $paths=@();if($c.plugins.load.paths){$paths=@($c.plugins.load.paths)};if($paths -notcontains $PluginRoot){$paths+=$PluginRoot};Ensure-Prop $c.plugins.load 'paths' $paths
  if($null-eq$c.plugins.entries){Ensure-Prop $c.plugins 'entries' ([pscustomobject]@{})}
  $ep=$c.plugins.entries.PSObject.Properties[$PluginId];if($null-eq$ep){$entry=[pscustomobject]@{};Ensure-Prop $c.plugins.entries $PluginId $entry}else{$entry=$ep.Value};Ensure-Prop $entry 'enabled' $true
  if($c.plugins.allow){$allow=@($c.plugins.allow);if($allow -notcontains $PluginId){$allow+=$PluginId};Ensure-Prop $c.plugins 'allow' $allow}
  if($c.plugins.deny){$deny=@($c.plugins.deny|Where-Object{$_ -ne $PluginId});Ensure-Prop $c.plugins 'deny' $deny}
  $c|ConvertTo-Json -Depth 50|Set-Content $Config -Encoding UTF8
  $v=Get-Content $Config -Raw|ConvertFrom-Json;if(-not$v.plugins.entries.$PluginId.enabled){throw '058A13_CONFIG_ENABLE_VERIFY_FAIL'};if(@($v.plugins.load.paths)-notcontains$PluginRoot){throw '058A13_CONFIG_PATH_VERIFY_FAIL'}
}

switch($Phase){
'Backup'{
  if(Test-Path $Work){Remove-Item $Work -Recurse -Force};New-Item -ItemType Directory -Force -Path $Work|Out-Null
  if(-not(Test-Path $Config)){throw '058A13_OPENCLAW_CONFIG_MISSING'};Copy-Item $Config $ConfigBackup -Force
  if(Test-Path $PluginRoot){Copy-Item $PluginRoot $PluginBackup -Recurse -Force}
  '{"state":"baseline","value":1}'|Set-Content $Target -Encoding UTF8
  Write-Host '058A13_BACKUP=PASS;CONFIG=true;PLUGIN_BASELINE=true'
}
'Install'{
  if(Test-Path $PluginRoot){Remove-Item $PluginRoot -Recurse -Force};New-Item -ItemType Directory -Force -Path $PluginRoot|Out-Null
  foreach($f in @('package.json','openclaw.plugin.json','index.js')){$u='https://raw.githubusercontent.com/3en4all/3en-command-runner/'+$SourceRef+'/openclaw-plugins/3en-job-executor/'+$f;Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile (Join-Path $PluginRoot $f) -TimeoutSec 15}
  $npm=Invoke-Bounded '058A13_NPM' 'npm.cmd' 'install typebox@1.1.39 --no-save --legacy-peer-deps --ignore-scripts --no-audit --no-fund' 55 $PluginRoot;if($npm.Exit-ne0){throw ('058A13_NPM_EXIT_'+$npm.Exit)}
  $node=Invoke-Bounded '058A13_NODE_CHECK' 'node.exe' '--check index.js' 10 $PluginRoot;if($node.Exit-ne0){throw ('058A13_NODE_EXIT_'+$node.Exit)}
  Set-PluginConfig
  Write-Host '058A13_INSTALL=PASS;PLUGIN_MANAGER_CLI_BYPASSED=true;CONFIG_ENABLED=true;LOAD_PATH_SET=true'
}
'Test'{
  if(-not(Wait-Gateway 6)){throw '058A13_GATEWAY_NOT_LISTENING'}
  $desired='{"state":"changed-by-3en-job","value":13}'
  $pos=Invoke-Tool ([ordered]@{operation='write';path=$Target;content=$desired})
  if(-not($pos.http-eq200-and$pos.ok)){
    Write-Host ('058A13_HOT_RELOAD_MISS='+$pos.http+'/'+$pos.ok+';TRY_BOUNDED_RESTART=true')
    $rr=Invoke-Bounded '058A13_GATEWAY_RESTART' 'openclaw.cmd' 'gateway restart' 18
    Start-Sleep -Seconds 2
    if(-not(Wait-Gateway 10)){throw '058A13_GATEWAY_RESTART_NOT_READY'}
    $pos=Invoke-Tool ([ordered]@{operation='write';path=$Target;content=$desired})
  }
  $content=if(Test-Path $Target){(Get-Content $Target -Raw).Trim()}else{''}
  $outside='C:\Windows\Temp\3en-job-escape-058a13.txt';Remove-Item $outside -Force -ErrorAction SilentlyContinue
  $neg=Invoke-Tool ([ordered]@{operation='write';path=$outside;content='SHOULD_NOT_EXIST'});$oe=Test-Path $outside
  $pass=($pos.http-eq200-and$pos.ok-and$content-eq$desired-and-not$oe-and(-not$neg.ok-or$neg.http-ne200))
  [ordered]@{status=if($pass){'PASS'}else{'FAIL'};revision='058a13';tool='3en_job';modelUsed=$false;positiveHttp=$pos.http;positiveOk=$pos.ok;positiveContentMatch=($content-eq$desired);negativeHttp=$neg.http;negativeOk=$neg.ok;outsideFileCreated=$oe;pluginManagerCliBypassed=$true;verifiedAt=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content $Evidence -Encoding UTF8
  if(-not$pass){throw ('058A13_ACCEPTANCE_FAIL pos='+$pos.http+'/'+$pos.ok+' neg='+$neg.http+'/'+$neg.ok+' content='+($content-eq$desired)+' outside='+$oe)}
  Write-Host '058A13_TEST=PASS;MODEL_FREE=true;POSITIVE_WRITE=PASS;PATH_ESCAPE_BLOCKED=PASS;OPENCLAW_LOCAL_EXECUTOR=ACCEPTED'
}
'Rollback'{
  if(Test-Path $ConfigBackup){Copy-Item $ConfigBackup $Config -Force}
  if(Test-Path $PluginRoot){Remove-Item $PluginRoot -Recurse -Force};if(Test-Path $PluginBackup){Copy-Item $PluginBackup $PluginRoot -Recurse -Force}
  Write-Host '058A13_ROLLBACK=PASS;CONFIG_RESTORED=true;PLUGIN_RESTORED=true'
}
}
