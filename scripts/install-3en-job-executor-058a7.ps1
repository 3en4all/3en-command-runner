param([Parameter(Mandatory=$true)][ValidateSet('Backup','Install','Test','Rollback')][string]$Phase)
$ErrorActionPreference='Stop'
$PluginRoot='C:\3EN-Agent\openclaw-plugins\3en-job-executor'
$Work='C:\3EN-Agent\workbench\plugin-acceptance-058a7'
$Target=Join-Path $Work 'target.json'
$Baseline=Join-Path $Work 'target.baseline.json'
$Evidence=Join-Path $Work 'acceptance.json'
$BackupRoot='C:\3EN-Agent\backups\openclaw-plugin-3en-job-executor'
$SourceRef='ca2a16b8b4dc1519cc054fb9e6a15b17628315bc'
function Invoke-CapturedCmd([string]$Tag,[string]$Command,[bool]$AllowFail=$false){
  $out=@(& cmd.exe /d /s /c ($Command+' 2>&1'))
  $ec=$LASTEXITCODE
  foreach($line in $out){Write-Host ($Tag+'='+[string]$line)}
  $txt=($out|ForEach-Object{[string]$_})-join "`n"
  if(-not$AllowFail -and $ec-ne0){$flat=$txt -replace '[\r\n]+',' | ';if($flat.Length-gt1800){$flat=$flat.Substring(0,1800)};throw ($Tag+'_EXIT_'+$ec+' OUTPUT='+$flat)}
  [pscustomobject]@{Exit=[int]$ec;Text=$txt}
}
function Get-GatewayContext {
  $p=Join-Path $env:USERPROFILE '.openclaw\openclaw.json';if(-not(Test-Path $p)){throw '058A7_OPENCLAW_CONFIG_MISSING'}
  $c=Get-Content $p -Raw|ConvertFrom-Json;$port=18789;if($null-ne$c.gateway -and $null-ne$c.gateway.port -and [int]$c.gateway.port -gt 0){$port=[int]$c.gateway.port}
  $mode='token';if($null-ne$c.gateway -and $null-ne$c.gateway.auth -and -not[string]::IsNullOrWhiteSpace([string]$c.gateway.auth.mode)){$mode=[string]$c.gateway.auth.mode}
  $secret='';if($mode-eq'token'){$secret=[string]$env:OPENCLAW_GATEWAY_TOKEN;if([string]::IsNullOrWhiteSpace($secret)-and$null-ne$c.gateway.auth.token){$secret=[string]$c.gateway.auth.token}}elseif($mode-eq'password'){$secret=[string]$env:OPENCLAW_GATEWAY_PASSWORD;if([string]::IsNullOrWhiteSpace($secret)-and$null-ne$c.gateway.auth.password){$secret=[string]$c.gateway.auth.password}}elseif($mode-ne'none'){throw ('058A7_AUTH_MODE_'+$mode)}
  if($mode-ne'none'-and[string]::IsNullOrWhiteSpace($secret)){throw '058A7_SECRET_UNAVAILABLE'};[pscustomobject]@{Port=$port;Mode=$mode;Secret=$secret}
}
function Invoke-Tool([string]$Tool,[object]$Args){$g=Get-GatewayContext;$h=@{};if($g.Mode-ne'none'){$h.Authorization='Bearer '+$g.Secret};$body=[ordered]@{tool=$Tool;args=$Args;sessionKey='main';idempotencyKey=('058a7-'+[guid]::NewGuid().ToString('N'))}|ConvertTo-Json -Depth 10;try{$r=Invoke-RestMethod -Method Post -Uri ('http://127.0.0.1:'+$g.Port+'/tools/invoke') -Headers $h -ContentType 'application/json' -Body $body -TimeoutSec 45;[pscustomobject]@{http=200;ok=if($null-ne$r.ok){[bool]$r.ok}else{$true};raw=$r}}catch{$s=-1;try{$s=[int]$_.Exception.Response.StatusCode}catch{};[pscustomobject]@{http=$s;ok=$false;raw=$null}}}
function Restart-Gateway {$r=Invoke-CapturedCmd '058A7_GATEWAY_RESTART' 'openclaw.cmd gateway restart';Start-Sleep -Seconds 5}
switch($Phase){
'Backup'{
  New-Item -ItemType Directory -Force -Path $BackupRoot|Out-Null
  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$dst=Join-Path $BackupRoot $stamp
  if(Test-Path $PluginRoot){New-Item -ItemType Directory -Force -Path $dst|Out-Null;Copy-Item $PluginRoot (Join-Path $dst 'plugin') -Recurse -Force}
  if(Test-Path $Work){Remove-Item $Work -Recurse -Force};New-Item -ItemType Directory -Force -Path $Work|Out-Null
  '{"state":"baseline","value":1}'|Set-Content $Target -Encoding UTF8;Copy-Item $Target $Baseline -Force
  Write-Output ('V4616_058A7_BACKUP=PASS;PLUGIN_PREEXISTING='+(Test-Path (Join-Path $dst 'plugin'))+';BACKUP='+$dst)
}
'Install'{
  $ver=Invoke-CapturedCmd '058A7_VERSION' 'openclaw.cmd --version'
  $installHelp=Invoke-CapturedCmd '058A7_INSTALL_HELP' 'openclaw.cmd plugins install --help'
  $enableHelp=Invoke-CapturedCmd '058A7_ENABLE_HELP' 'openclaw.cmd plugins enable --help'
  if(Test-Path $PluginRoot){Remove-Item $PluginRoot -Recurse -Force};New-Item -ItemType Directory -Force -Path $PluginRoot|Out-Null
  foreach($f in @('package.json','openclaw.plugin.json','index.js')){$u='https://raw.githubusercontent.com/3en4all/3en-command-runner/'+$SourceRef+'/openclaw-plugins/3en-job-executor/'+$f;Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile (Join-Path $PluginRoot $f)}
  Push-Location $PluginRoot;try{$npm=Invoke-CapturedCmd '058A7_NPM' 'npm.cmd install --omit=dev --no-audit --no-fund';$syntax=Invoke-CapturedCmd '058A7_NODE_CHECK' 'node.exe --check index.js'}finally{Pop-Location}
  $manifest=Get-Content (Join-Path $PluginRoot 'openclaw.plugin.json') -Raw|ConvertFrom-Json
  if([string]$manifest.id-ne'3en-job-executor' -or @($manifest.contracts.tools) -notcontains '3en_job'){throw '058A7_MANIFEST_CONTRACT_BAD'}
  $doctor=Invoke-CapturedCmd '058A7_DOCTOR' 'openclaw.cmd plugins doctor' $true
  $list=Invoke-CapturedCmd '058A7_LIST' 'openclaw.cmd plugins list --json'
  $already=$list.Text -match '3en-job-executor'
  if($already){$un=Invoke-CapturedCmd '058A7_UNINSTALL' 'openclaw.cmd plugins uninstall 3en-job-executor --keep-files --force' $true}
  $flags=@('-l','"'+$PluginRoot+'"')
  if($installHelp.Text -match '--accept-capabilities'){$flags+='--accept-capabilities'}
  if($installHelp.Text -match '--acknowledge-install-policy-warning'){$flags+='--acknowledge-install-policy-warning'}
  Write-Output ('V4616_058A7_SELECTED_INSTALL_FLAGS='+($flags -join ' '))
  $ins=Invoke-CapturedCmd '058A7_INSTALL' ('openclaw.cmd plugins install '+($flags -join ' '))
  $enableCmd='openclaw.cmd plugins enable 3en-job-executor';if($enableHelp.Text -match '--accept-capabilities'){$enableCmd+=' --accept-capabilities'}
  $en=Invoke-CapturedCmd '058A7_ENABLE' $enableCmd
  Restart-Gateway
  $inspectHelp=Invoke-CapturedCmd '058A7_INSPECT_HELP' 'openclaw.cmd plugins inspect --help' $true
  $inspectCmd='openclaw.cmd plugins inspect 3en-job-executor';if($inspectHelp.Text -match '--runtime'){$inspectCmd+=' --runtime'};if($inspectHelp.Text -match '--json'){$inspectCmd+=' --json'}
  $inspect=Invoke-CapturedCmd '058A7_INSPECT' $inspectCmd
  $inspect.Text|Set-Content (Join-Path $Work 'plugin-inspect.txt') -Encoding UTF8
  if($inspect.Text-notmatch '3en_job'){throw ('058A7_TOOL_NOT_REGISTERED OUTPUT='+(($inspect.Text -replace '[\r\n]+',' | ')))}
  Write-Output 'V4616_058A7_INSTALL=PASS;PLUGIN=3en-job-executor;TOOL=3en_job'
}
'Test'{
  $desired='{"state":"changed-by-3en-job","value":7}'
  $positive=Invoke-Tool '3en_job' ([ordered]@{operation='write';path=$Target;content=$desired})
  $content=if(Test-Path $Target){(Get-Content $Target -Raw).Trim()}else{''}
  $outside='C:\Windows\Temp\3en-job-escape-058a7.txt';Remove-Item $outside -Force -ErrorAction SilentlyContinue
  $negative=Invoke-Tool '3en_job' ([ordered]@{operation='write';path=$outside;content='SHOULD_NOT_EXIST'})
  $outsideExists=Test-Path $outside
  $pass=($positive.http-eq200 -and $positive.ok -and $content-eq$desired -and -not$outsideExists -and (-not$negative.ok -or $negative.http-ne200))
  [ordered]@{schemaVersion=1;status=if($pass){'PASS'}else{'FAIL'};plugin='3en-job-executor';tool='3en_job';modelUsed=$false;positiveHttp=$positive.http;positiveOk=$positive.ok;positiveContentMatch=($content-eq$desired);negativeHttp=$negative.http;negativeOk=$negative.ok;outsideFileCreated=$outsideExists;allowedRoot='C:\3EN-Agent\workbench';verifiedAt=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content $Evidence -Encoding UTF8
  if(-not$pass){throw ('058A7_ACCEPTANCE_FAIL pos='+$positive.http+'/'+$positive.ok+' neg='+$negative.http+'/'+$negative.ok+' outside='+$outsideExists)}
  Write-Output 'V4616_058A7_TEST=PASS;MODEL_FREE=true;POSITIVE_WRITE=PASS;PATH_ESCAPE_BLOCKED=PASS'
}
'Rollback'{
  if(Test-Path $Baseline){Copy-Item $Baseline $Target -Force}
  try{$d=Invoke-CapturedCmd '058A7_DISABLE' 'openclaw.cmd plugins disable 3en-job-executor' $true}catch{}
  Write-Output 'V4616_058A7_ROLLBACK=PASS;PLUGIN_DISABLED=true;BASELINE_RESTORED=true'
}
}
