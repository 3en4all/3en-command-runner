param([Parameter(Mandatory=$true)][ValidateSet('Backup','Execute','Test','Rollback')][string]$Phase)
$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent\workbench\admin-057y'
$Config=Join-Path $Root 'service-config.json'
$Original=Join-Path $Root 'service-config.original.json'
$Desired=Join-Path $Root 'service-config.desired.json'
$Health=Join-Path $Root 'health-test.ps1'
$Hashes=Join-Path $Root 'immutable-hashes.json'
$Evidence=Join-Path $Root 'direct-exec-evidence.json'
$Verify=Join-Path $Root 'independent-verification.json'
function Get-Sha([string]$p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash}
function Get-GatewayContext {
  $p=Join-Path $env:USERPROFILE '.openclaw\openclaw.json'
  if(-not(Test-Path $p)){throw '057Y_OPENCLAW_CONFIG_MISSING'}
  $c=Get-Content $p -Raw|ConvertFrom-Json
  $port=18789;if($null-ne$c.gateway -and $null-ne$c.gateway.port -and [int]$c.gateway.port -gt 0){$port=[int]$c.gateway.port}
  $mode='token';if($null-ne$c.gateway -and $null-ne$c.gateway.auth -and -not [string]::IsNullOrWhiteSpace([string]$c.gateway.auth.mode)){$mode=[string]$c.gateway.auth.mode}
  $secret=''
  if($mode -eq 'token'){$secret=[string]$env:OPENCLAW_GATEWAY_TOKEN;if([string]::IsNullOrWhiteSpace($secret) -and $null-ne$c.gateway.auth.token){$secret=[string]$c.gateway.auth.token}}
  elseif($mode -eq 'password'){$secret=[string]$env:OPENCLAW_GATEWAY_PASSWORD;if([string]::IsNullOrWhiteSpace($secret) -and $null-ne$c.gateway.auth.password){$secret=[string]$c.gateway.auth.password}}
  elseif($mode -ne 'none'){throw ('057Y_AUTH_MODE_'+$mode)}
  if($mode -ne 'none' -and [string]::IsNullOrWhiteSpace($secret)){throw '057Y_SECRET_UNAVAILABLE'}
  [pscustomobject]@{Port=$port;Mode=$mode;Secret=$secret}
}
function Invoke-DirectTool([string]$Tool,[object]$Args){
  $g=Get-GatewayContext;$h=@{};if($g.Mode -ne 'none'){$h.Authorization='Bearer '+$g.Secret}
  $body=[ordered]@{tool=$Tool;args=$Args;sessionKey='main';idempotencyKey=('057y-'+$Tool+'-'+[guid]::NewGuid().ToString('N'))}|ConvertTo-Json -Depth 10
  try{$r=Invoke-RestMethod -Method Post -Uri ('http://127.0.0.1:'+$g.Port+'/tools/invoke') -Headers $h -ContentType 'application/json' -Body $body -TimeoutSec 45;return [pscustomobject]@{tool=$Tool;http=200;ok=if($null-ne$r.ok){[bool]$r.ok}else{$true};response=$r;gatewayPort=$g.Port;authMode=$g.Mode}}
  catch{$s=-1;try{$s=[int]$_.Exception.Response.StatusCode}catch{};return [pscustomobject]@{tool=$Tool;http=$s;ok=$false;response=$null;gatewayPort=$g.Port;authMode=$g.Mode}}
}
switch($Phase){
'Backup'{
  if(Test-Path $Root){Remove-Item $Root -Recurse -Force};New-Item -ItemType Directory -Force -Path $Root|Out-Null
  ([ordered]@{service='3EN-DemoCollector';listenPort=8088;expectedPort=8099;enabled=$true;drill='v459-direct-exec'}|ConvertTo-Json)|Set-Content $Config -Encoding UTF8
  Copy-Item $Config $Original -Force
  ([ordered]@{service='3EN-DemoCollector';listenPort=8099;expectedPort=8099;enabled=$true;drill='v459-direct-exec'}|ConvertTo-Json)|Set-Content $Desired -Encoding UTF8
  @('$ErrorActionPreference=''Stop''','$c=Get-Content (Join-Path $PSScriptRoot ''service-config.json'') -Raw|ConvertFrom-Json','if(-not [bool]$c.enabled){exit 43}','if([int]$c.listenPort -ne [int]$c.expectedPort){exit 42}','exit 0')|Set-Content $Health -Encoding UTF8
  [ordered]@{original=(Get-Sha $Original);desired=(Get-Sha $Desired);health=(Get-Sha $Health)}|ConvertTo-Json|Set-Content $Hashes -Encoding UTF8
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Health;$ec=$LASTEXITCODE;if($ec-ne42){throw ('057Y_BASELINE_'+$ec)}
  Write-Output 'V459_057Y_BACKUP=PASS;BASELINE=42'
}
'Execute'{
  foreach($p in @($Config,$Original,$Desired,$Health,$Hashes)){if(-not(Test-Path $p)){throw ('057Y_MISSING_'+$p)}}
  $h=Get-Content $Hashes -Raw|ConvertFrom-Json;if((Get-Sha $Original)-ne[string]$h.original){throw '057Y_ORIGINAL_HASH'};if((Get-Sha $Desired)-ne[string]$h.desired){throw '057Y_DESIRED_HASH'};if((Get-Sha $Health)-ne[string]$h.health){throw '057Y_HEALTH_HASH'}
  $probe=Invoke-DirectTool 'sessions_list' ([ordered]@{})
  if($probe.http-ne200 -or -not $probe.ok){[ordered]@{schemaVersion=1;probe=$probe;exec=$null;modelUsed=$false;secretLogged=$false}|ConvertTo-Json -Depth 8|Set-Content $Evidence -Encoding UTF8;throw ('057Y_GATEWAY_PROBE_'+$probe.http)}
  $cmd='cmd.exe /d /c copy /y "'+$Desired+'" "'+$Config+'" >nul'
  $exec=Invoke-DirectTool 'exec' ([ordered]@{command=$cmd;host='gateway';timeoutSeconds=30})
  [ordered]@{schemaVersion=1;probe=[ordered]@{http=$probe.http;ok=$probe.ok;tool='sessions_list'};exec=[ordered]@{http=$exec.http;ok=$exec.ok;tool='exec'};modelUsed=$false;secretLogged=$false;target=$Config;testedAt=(Get-Date).ToString('o')}|ConvertTo-Json -Depth 8|Set-Content $Evidence -Encoding UTF8
  if($exec.http-ne200 -or -not $exec.ok){throw ('057Y_DIRECT_EXEC_'+$exec.http)}
  if((Get-Sha $Config)-ne(Get-Sha $Desired)){throw '057Y_EXEC_BYTES_MISMATCH'}
  Write-Output 'V459_057Y_DIRECT_EXEC=PASS;MODEL_USED=false;GATEWAY_API=PASS'
}
'Test'{
  foreach($p in @($Config,$Original,$Desired,$Health,$Hashes,$Evidence)){if(-not(Test-Path $p)){throw ('057Y_TEST_MISSING_'+$p)}}
  $h=Get-Content $Hashes -Raw|ConvertFrom-Json;$e=Get-Content $Evidence -Raw|ConvertFrom-Json
  if((Get-Sha $Original)-ne[string]$h.original -or (Get-Sha $Desired)-ne[string]$h.desired -or (Get-Sha $Health)-ne[string]$h.health){throw '057Y_IMMUTABLE_HASH_FAIL'}
  if([int]$e.probe.http-ne200 -or -not[bool]$e.probe.ok){throw '057Y_PROBE_EVIDENCE_FAIL'}
  if([int]$e.exec.http-ne200 -or -not[bool]$e.exec.ok -or [bool]$e.modelUsed){throw '057Y_EXEC_EVIDENCE_FAIL'}
  if((Get-Sha $Config)-ne(Get-Sha $Desired)){throw '057Y_FINAL_BYTES_FAIL'}
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Health;$ec=$LASTEXITCODE;if($ec-ne0){throw ('057Y_HEALTH_'+$ec)}
  [ordered]@{schemaVersion=1;status='PASS';architecture='ASSISTANT_TO_OPENCLAW_TOOLS_INVOKE_EXEC_TO_INDEPENDENT_VERIFIER';modelUsed=$false;gatewayProbeVerified=$true;directExecVerified=$true;backupVerified=$true;finalBytesVerified=$true;independentHealthVerified=$true;finalHealthExit=$ec;verifiedAt=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content $Verify -Encoding UTF8
  Write-Output 'V459_057Y_TEST=PASS;MODEL_FREE=true;DIRECT_EXEC=PASS;BACKUP=PASS;HEALTH=PASS'
}
'Rollback'{
  if(Test-Path $Original){Copy-Item $Original $Config -Force;if((Get-Sha $Config)-eq(Get-Sha $Original)){Write-Output 'V459_057Y_ROLLBACK=PASS'}else{Write-Output 'V459_057Y_ROLLBACK=FAIL';exit 51}}else{Write-Output 'V459_057Y_ROLLBACK=NO_ORIGINAL';exit 52}
}
}
