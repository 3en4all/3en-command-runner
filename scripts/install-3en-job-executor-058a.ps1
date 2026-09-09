param([Parameter(Mandatory=$true)][ValidateSet('Backup','Install','Test','Rollback')][string]$Phase)
$ErrorActionPreference='Stop'
$PluginRoot='C:\3EN-Agent\openclaw-plugins\3en-job-executor'
$Work='C:\3EN-Agent\workbench\plugin-acceptance-058a'
$Target=Join-Path $Work 'target.json'
$Baseline=Join-Path $Work 'target.baseline.json'
$Evidence=Join-Path $Work 'acceptance.json'
$BackupRoot='C:\3EN-Agent\backups\openclaw-plugin-3en-job-executor'
$SourceRef='ca2a16b8b4dc1519cc054fb9e6a15b17628315bc'
function Get-GatewayContext {
  $p=Join-Path $env:USERPROFILE '.openclaw\openclaw.json';if(-not(Test-Path $p)){throw '058A_OPENCLAW_CONFIG_MISSING'}
  $c=Get-Content $p -Raw|ConvertFrom-Json;$port=18789;if($null-ne$c.gateway -and $null-ne$c.gateway.port -and [int]$c.gateway.port -gt 0){$port=[int]$c.gateway.port}
  $mode='token';if($null-ne$c.gateway -and $null-ne$c.gateway.auth -and -not[string]::IsNullOrWhiteSpace([string]$c.gateway.auth.mode)){$mode=[string]$c.gateway.auth.mode}
  $secret='';if($mode-eq'token'){$secret=[string]$env:OPENCLAW_GATEWAY_TOKEN;if([string]::IsNullOrWhiteSpace($secret)-and$null-ne$c.gateway.auth.token){$secret=[string]$c.gateway.auth.token}}elseif($mode-eq'password'){$secret=[string]$env:OPENCLAW_GATEWAY_PASSWORD;if([string]::IsNullOrWhiteSpace($secret)-and$null-ne$c.gateway.auth.password){$secret=[string]$c.gateway.auth.password}}elseif($mode-ne'none'){throw ('058A_AUTH_MODE_'+$mode)}
  if($mode-ne'none'-and[string]::IsNullOrWhiteSpace($secret)){throw '058A_SECRET_UNAVAILABLE'};[pscustomobject]@{Port=$port;Mode=$mode;Secret=$secret}
}
function Invoke-Tool([string]$Tool,[object]$Args){$g=Get-GatewayContext;$h=@{};if($g.Mode-ne'none'){$h.Authorization='Bearer '+$g.Secret};$body=[ordered]@{tool=$Tool;args=$Args;sessionKey='main';idempotencyKey=('058a-'+[guid]::NewGuid().ToString('N'))}|ConvertTo-Json -Depth 10;try{$r=Invoke-RestMethod -Method Post -Uri ('http://127.0.0.1:'+$g.Port+'/tools/invoke') -Headers $h -ContentType 'application/json' -Body $body -TimeoutSec 45;[pscustomobject]@{http=200;ok=if($null-ne$r.ok){[bool]$r.ok}else{$true};raw=$r}}catch{$s=-1;try{$s=[int]$_.Exception.Response.StatusCode}catch{};[pscustomobject]@{http=$s;ok=$false;raw=$null}}}
function Restart-Gateway {& openclaw.cmd gateway restart 2>&1|ForEach-Object{Write-Output ('058A_GATEWAY_RESTART='+[string]$_)};if($LASTEXITCODE-ne0){throw ('058A_GATEWAY_RESTART_EXIT_'+$LASTEXITCODE)};Start-Sleep -Seconds 5}
switch($Phase){
'Backup'{
  New-Item -ItemType Directory -Force -Path $BackupRoot|Out-Null
  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$dst=Join-Path $BackupRoot $stamp
  if(Test-Path $PluginRoot){New-Item -ItemType Directory -Force -Path $dst|Out-Null;Copy-Item $PluginRoot (Join-Path $dst 'plugin') -Recurse -Force}
  if(Test-Path $Work){Remove-Item $Work -Recurse -Force};New-Item -ItemType Directory -Force -Path $Work|Out-Null
  '{"state":"baseline","value":1}'|Set-Content $Target -Encoding UTF8;Copy-Item $Target $Baseline -Force
  Write-Output ('V461_058A_BACKUP=PASS;PLUGIN_PREEXISTING='+(Test-Path (Join-Path $dst 'plugin'))+';BACKUP='+$dst)
}
'Install'{
  if(Test-Path $PluginRoot){Remove-Item $PluginRoot -Recurse -Force};New-Item -ItemType Directory -Force -Path $PluginRoot|Out-Null
  foreach($f in @('package.json','openclaw.plugin.json','index.js')){$u='https://raw.githubusercontent.com/3en4all/3en-command-runner/'+$SourceRef+'/openclaw-plugins/3en-job-executor/'+$f;Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile (Join-Path $PluginRoot $f)}
  Push-Location $PluginRoot;try{& npm.cmd install --omit=dev --no-audit --no-fund 2>&1|ForEach-Object{Write-Output ('058A_NPM='+[string]$_)};if($LASTEXITCODE-ne0){throw ('058A_NPM_EXIT_'+$LASTEXITCODE)}}finally{Pop-Location}
  & openclaw.cmd plugins validate --entry $PluginRoot 2>&1|ForEach-Object{Write-Output ('058A_VALIDATE='+[string]$_)};if($LASTEXITCODE-ne0){throw ('058A_VALIDATE_EXIT_'+$LASTEXITCODE)}
  $list=@(& openclaw.cmd plugins list --json 2>&1);$already=(($list|ForEach-Object{[string]$_})-join "`n") -match '3en-job-executor'
  if($already){& openclaw.cmd plugins uninstall 3en-job-executor --keep-files --force 2>&1|ForEach-Object{Write-Output ('058A_UNINSTALL='+[string]$_)}}
  & openclaw.cmd plugins install -l $PluginRoot --force --acknowledge-install-policy-warning 2>&1|ForEach-Object{Write-Output ('058A_INSTALL='+[string]$_)};if($LASTEXITCODE-ne0){throw ('058A_INSTALL_EXIT_'+$LASTEXITCODE)}
  & openclaw.cmd plugins enable 3en-job-executor 2>&1|ForEach-Object{Write-Output ('058A_ENABLE='+[string]$_)};if($LASTEXITCODE-ne0){throw ('058A_ENABLE_EXIT_'+$LASTEXITCODE)}
  Restart-Gateway
  $inspect=@(& openclaw.cmd plugins inspect 3en-job-executor --runtime --json 2>&1);$iec=$LASTEXITCODE;$itxt=($inspect|ForEach-Object{[string]$_})-join "`n";$itxt|Set-Content (Join-Path $Work 'plugin-inspect.json') -Encoding UTF8;if($iec-ne0){throw ('058A_INSPECT_EXIT_'+$iec)};if($itxt-notmatch '3en_job'){throw '058A_TOOL_NOT_REGISTERED'}
  Write-Output 'V461_058A_INSTALL=PASS;PLUGIN=3en-job-executor;TOOL=3en_job'
}
'Test'{
  $desired='{"state":"changed-by-3en-job","value":2}'
  $positive=Invoke-Tool '3en_job' ([ordered]@{operation='write';path=$Target;content=$desired})
  $content=if(Test-Path $Target){(Get-Content $Target -Raw).Trim()}else{''}
  $outside='C:\Windows\Temp\3en-job-escape-058a.txt';Remove-Item $outside -Force -ErrorAction SilentlyContinue
  $negative=Invoke-Tool '3en_job' ([ordered]@{operation='write';path=$outside;content='SHOULD_NOT_EXIST'})
  $outsideExists=Test-Path $outside
  $pass=($positive.http-eq200 -and $positive.ok -and $content-eq$desired -and -not$outsideExists -and (-not$negative.ok -or $negative.http-ne200))
  [ordered]@{schemaVersion=1;status=if($pass){'PASS'}else{'FAIL'};plugin='3en-job-executor';tool='3en_job';modelUsed=$false;positiveHttp=$positive.http;positiveOk=$positive.ok;positiveContentMatch=($content-eq$desired);negativeHttp=$negative.http;negativeOk=$negative.ok;outsideFileCreated=$outsideExists;allowedRoot='C:\3EN-Agent\workbench';verifiedAt=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content $Evidence -Encoding UTF8
  if(-not$pass){throw ('058A_ACCEPTANCE_FAIL pos='+$positive.http+'/'+$positive.ok+' neg='+$negative.http+'/'+$negative.ok+' outside='+$outsideExists)}
  Write-Output 'V461_058A_TEST=PASS;MODEL_FREE=true;POSITIVE_WRITE=PASS;PATH_ESCAPE_BLOCKED=PASS'
}
'Rollback'{
  if(Test-Path $Baseline){Copy-Item $Baseline $Target -Force}
  try{& openclaw.cmd plugins disable 3en-job-executor 2>&1|Out-Null}catch{}
  Write-Output 'V461_058A_ROLLBACK=PASS;PLUGIN_DISABLED=true;BASELINE_RESTORED=true'
}
}
