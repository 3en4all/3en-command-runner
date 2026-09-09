param([Parameter(Mandatory=$true)][ValidateSet('Run','Test')][string]$Phase)
$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent\workbench\diag-057x'
$Evidence=Join-Path $Root 'http-tool-surface.json'
$ProbeFile=Join-Path $Root 'probe.txt'
function Get-GatewayContext {
  $p=Join-Path $env:USERPROFILE '.openclaw\openclaw.json'
  if(-not(Test-Path $p)){throw '057X_OPENCLAW_CONFIG_MISSING'}
  $c=Get-Content $p -Raw|ConvertFrom-Json
  $port=18789;if($c.gateway.port){$port=[int]$c.gateway.port}
  $mode='token';if($c.gateway.auth.mode){$mode=[string]$c.gateway.auth.mode}
  $secret=''
  if($mode -eq 'token'){$secret=[string]$env:OPENCLAW_GATEWAY_TOKEN;if([string]::IsNullOrWhiteSpace($secret)){$secret=[string]$c.gateway.auth.token}}
  elseif($mode -eq 'password'){$secret=[string]$env:OPENCLAW_GATEWAY_PASSWORD;if([string]::IsNullOrWhiteSpace($secret)){$secret=[string]$c.gateway.auth.password}}
  elseif($mode -ne 'none'){throw ('057X_AUTH_MODE_'+$mode)}
  if($mode -ne 'none' -and [string]::IsNullOrWhiteSpace($secret)){throw '057X_SECRET_UNAVAILABLE'}
  [pscustomobject]@{Port=$port;Mode=$mode;Secret=$secret}
}
function Invoke-Probe([string]$Tool,[hashtable]$Args){
  $g=Get-GatewayContext;$h=@{};if($g.Mode -ne 'none'){$h.Authorization='Bearer '+$g.Secret}
  $body=[ordered]@{tool=$Tool;args=$Args;sessionKey='main';idempotencyKey=('057x-'+$Tool+'-'+[guid]::NewGuid().ToString('N'))}|ConvertTo-Json -Depth 8
  try{$r=Invoke-RestMethod -Method Post -Uri ('http://127.0.0.1:'+$g.Port+'/tools/invoke') -Headers $h -ContentType 'application/json' -Body $body -TimeoutSec 20;return [pscustomobject]@{tool=$Tool;http=200;ok=if($null-ne$r.ok){[bool]$r.ok}else{$true};error=''}}
  catch{$s=-1;try{$s=[int]$_.Exception.Response.StatusCode}catch{};return [pscustomobject]@{tool=$Tool;http=$s;ok=$false;error=$_.Exception.GetType().Name}}
}
if($Phase -eq 'Run'){
  if(Test-Path $Root){Remove-Item $Root -Recurse -Force};New-Item -ItemType Directory -Force -Path $Root|Out-Null
  $r1=Invoke-Probe 'session_status' @{}
  $r2=Invoke-Probe 'write' @{path=$ProbeFile.Replace('\','/');content='WRITE_PROBE=057X'}
  $r3=Invoke-Probe 'fs_write' @{path=$ProbeFile.Replace('\','/');content='FS_WRITE_PROBE=057X'}
  $fileExists=Test-Path $ProbeFile;$fileContent=if($fileExists){(Get-Content $ProbeFile -Raw).Trim()}else{''}
  [ordered]@{schemaVersion=1;session_status=$r1;write=$r2;fs_write=$r3;probeFileExists=$fileExists;probeFileContent=$fileContent;secretLogged=$false;configChanged=$false;testedAt=(Get-Date).ToString('o')}|ConvertTo-Json -Depth 6|Set-Content $Evidence -Encoding UTF8
  Write-Output ('V458_057X_SESSION_STATUS_HTTP='+$r1.http+';OK='+$r1.ok)
  Write-Output ('V458_057X_WRITE_HTTP='+$r2.http+';OK='+$r2.ok)
  Write-Output ('V458_057X_FS_WRITE_HTTP='+$r3.http+';OK='+$r3.ok)
  Write-Output ('V458_057X_FILE_EXISTS='+$fileExists+';CONTENT='+$fileContent)
}
if($Phase -eq 'Test'){
  if(-not(Test-Path $Evidence)){throw '057X_EVIDENCE_MISSING'}
  $e=Get-Content $Evidence -Raw|ConvertFrom-Json
  if([int]$e.session_status.http -ne 200){throw ('057X_ENDPOINT_OR_AUTH_NOT_VERIFIED_'+$e.session_status.http)}
  if([bool]$e.configChanged){throw '057X_CONFIG_WAS_CHANGED'}
  Write-Output ('V458_057X_TEST=PASS;ENDPOINT_AUTH=PASS;WRITE_HTTP='+$e.write.http+';FS_WRITE_HTTP='+$e.fs_write.http+';FILE_EXISTS='+$e.probeFileExists)
}
