param([Parameter(Mandatory=$true)][ValidateSet('Run','Test')][string]$Phase)
$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent\workbench\diag-057x2'
$Evidence=Join-Path $Root 'http-tool-surface.json'
$ProbeFile=Join-Path $Root 'probe.txt'
function Get-GatewayContext {
  $p=Join-Path $env:USERPROFILE '.openclaw\openclaw.json'
  if(-not(Test-Path $p)){throw '057X2_OPENCLAW_CONFIG_MISSING'}
  $c=Get-Content $p -Raw|ConvertFrom-Json
  $port=18789;if($null-ne$c.gateway -and $c.gateway.port){$port=[int]$c.gateway.port}
  $mode='token';if($null-ne$c.gateway -and $null-ne$c.gateway.auth -and $c.gateway.auth.mode){$mode=[string]$c.gateway.auth.mode}
  $secret=''
  if($mode -eq 'token'){$secret=[string]$env:OPENCLAW_GATEWAY_TOKEN;if([string]::IsNullOrWhiteSpace($secret)){$secret=[string]$c.gateway.auth.token}}
  elseif($mode -eq 'password'){$secret=[string]$env:OPENCLAW_GATEWAY_PASSWORD;if([string]::IsNullOrWhiteSpace($secret)){$secret=[string]$c.gateway.auth.password}}
  elseif($mode -ne 'none'){throw ('057X2_AUTH_MODE_'+$mode)}
  if($mode -ne 'none' -and [string]::IsNullOrWhiteSpace($secret)){throw '057X2_SECRET_UNAVAILABLE'}
  [pscustomobject]@{Port=$port;Mode=$mode;Secret=$secret}
}
function Invoke-Probe {
  param([Parameter(Mandatory=$true)][string]$Tool,[Parameter(Mandatory=$true)][hashtable]$ToolArgs)
  $g=Get-GatewayContext;$h=@{};if($g.Mode -ne 'none'){$h.Authorization='Bearer '+$g.Secret}
  $body=[ordered]@{tool=$Tool;args=$ToolArgs;sessionKey='main';idempotencyKey=('057x2-'+$Tool+'-'+[guid]::NewGuid().ToString('N'))}|ConvertTo-Json -Depth 8
  try{$r=Invoke-RestMethod -Method Post -Uri ('http://127.0.0.1:'+$g.Port+'/tools/invoke') -Headers $h -ContentType 'application/json' -Body $body -TimeoutSec 20;return [pscustomobject]@{tool=$Tool;http=200;ok=if($null-ne$r.ok){[bool]$r.ok}else{$true};error=''}}
  catch{$s=-1;try{$s=[int]$_.Exception.Response.StatusCode}catch{};return [pscustomobject]@{tool=$Tool;http=$s;ok=$false;error=$_.Exception.GetType().Name}}
}
if($Phase -eq 'Run'){
  if(Test-Path $Root){Remove-Item $Root -Recurse -Force};New-Item -ItemType Directory -Force -Path $Root|Out-Null
  $r1=Invoke-Probe -Tool 'session_status' -ToolArgs ([hashtable]@{})
  $r2=Invoke-Probe -Tool 'write' -ToolArgs ([hashtable]@{path=$ProbeFile.Replace('\','/');content='WRITE_PROBE=057X2'})
  $r3=Invoke-Probe -Tool 'fs_write' -ToolArgs ([hashtable]@{path=$ProbeFile.Replace('\','/');content='FS_WRITE_PROBE=057X2'})
  $fileExists=Test-Path $ProbeFile;$fileContent=if($fileExists){(Get-Content $ProbeFile -Raw).Trim()}else{''}
  [ordered]@{schemaVersion=1;session_status=$r1;write=$r2;fs_write=$r3;probeFileExists=$fileExists;probeFileContent=$fileContent;secretLogged=$false;configChanged=$false;testedAt=(Get-Date).ToString('o')}|ConvertTo-Json -Depth 6|Set-Content $Evidence -Encoding UTF8
  Write-Output ('V458_057X2_SESSION_STATUS_HTTP='+$r1.http+';OK='+$r1.ok)
  Write-Output ('V458_057X2_WRITE_HTTP='+$r2.http+';OK='+$r2.ok)
  Write-Output ('V458_057X2_FS_WRITE_HTTP='+$r3.http+';OK='+$r3.ok)
  Write-Output ('V458_057X2_FILE_EXISTS='+$fileExists+';CONTENT='+$fileContent)
}
if($Phase -eq 'Test'){
  if(-not(Test-Path $Evidence)){throw '057X2_EVIDENCE_MISSING'}
  $e=Get-Content $Evidence -Raw|ConvertFrom-Json
  if([int]$e.session_status.http -ne 200){throw ('057X2_ENDPOINT_OR_AUTH_NOT_VERIFIED_'+$e.session_status.http)}
  if([bool]$e.configChanged){throw '057X2_CONFIG_WAS_CHANGED'}
  Write-Output ('V458_057X2_TEST=PASS;ENDPOINT_AUTH=PASS;WRITE_HTTP='+$e.write.http+';FS_WRITE_HTTP='+$e.fs_write.http+';FILE_EXISTS='+$e.probeFileExists)
}
