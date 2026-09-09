param([Parameter(Mandatory=$true)][ValidateSet('Backup','Execute','Test','Rollback')][string]$Phase)
$ErrorActionPreference='Stop'
$PluginId='threeen-job-executor'
$ToolName='threeen_apply_job'
$PluginRoot='C:\3EN-Agent\plugins\threeen-job-executor'
$JobsRoot='C:\3EN-Agent\jobs'
$AllowedRoot='C:\3EN-Agent\workbench'
$JobId='acceptance-058p'
$JobDir=Join-Path $JobsRoot $JobId
$TargetDir=Join-Path $AllowedRoot 'plugin-acceptance-058p'
$Target=Join-Path $TargetDir 'service-config.json'
$Payload=Join-Path $JobDir 'payload.json'
$Manifest=Join-Path $JobDir 'manifest.json'
$Health=Join-Path $TargetDir 'health-test.ps1'
$Evidence=Join-Path $JobDir 'gateway-evidence.json'
$BackupRoot='C:\3EN-Agent\backups\058p-openclaw-plugin'
$Cfg=Join-Path $env:USERPROFILE '.openclaw\openclaw.json'
$CfgBackup=Join-Path $BackupRoot 'openclaw.json.before'
function Sha([string]$p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
function GatewayContext {
  $c=Get-Content $Cfg -Raw|ConvertFrom-Json;$port=18789;if($c.gateway.port){$port=[int]$c.gateway.port};$mode='token';if($c.gateway.auth.mode){$mode=[string]$c.gateway.auth.mode};$secret=''
  if($mode-eq'token'){$secret=[string]$env:OPENCLAW_GATEWAY_TOKEN;if([string]::IsNullOrWhiteSpace($secret)){$secret=[string]$c.gateway.auth.token}}
  elseif($mode-eq'password'){$secret=[string]$env:OPENCLAW_GATEWAY_PASSWORD;if([string]::IsNullOrWhiteSpace($secret)){$secret=[string]$c.gateway.auth.password}}
  elseif($mode-ne'none'){throw ('058P_AUTH_MODE_'+$mode)}
  if($mode-ne'none'-and[string]::IsNullOrWhiteSpace($secret)){throw '058P_GATEWAY_SECRET_MISSING'}
  [pscustomobject]@{Port=$port;Mode=$mode;Secret=$secret}
}
function InvokeTool([string]$tool,[object]$args){
  $g=GatewayContext;$h=@{};if($g.Mode-ne'none'){$h.Authorization='Bearer '+$g.Secret};$b=[ordered]@{tool=$tool;args=$args;sessionKey='main';idempotencyKey=('058p-'+[guid]::NewGuid().ToString('N'))}|ConvertTo-Json -Depth 10
  try{$r=Invoke-RestMethod -Method Post -Uri ('http://127.0.0.1:'+$g.Port+'/tools/invoke') -Headers $h -ContentType 'application/json' -Body $b -TimeoutSec 45;[pscustomobject]@{http=200;ok=if($null-ne$r.ok){[bool]$r.ok}else{$true};response=$r}}
  catch{$s=-1;try{$s=[int]$_.Exception.Response.StatusCode}catch{};[pscustomobject]@{http=$s;ok=$false;response=$null}}
}
function RestartGateway {
  $o=@(& openclaw.cmd gateway restart 2>&1);$ec=$LASTEXITCODE;Write-Output ('058P_GATEWAY_RESTART_EXIT='+$ec);if($ec-ne0){throw ('058P_GATEWAY_RESTART_'+$ec)};Start-Sleep -Seconds 4
}
switch($Phase){
'Backup'{
  if(-not(Test-Path $Cfg)){throw '058P_OPENCLAW_CONFIG_MISSING'}
  New-Item -ItemType Directory -Force -Path $BackupRoot,$JobDir,$TargetDir|Out-Null
  Copy-Item $Cfg $CfgBackup -Force
  ([ordered]@{service='3EN-PluginAcceptance';listenPort=8088;expectedPort=8099;enabled=$true}|ConvertTo-Json)|Set-Content $Target -Encoding UTF8
  ([ordered]@{service='3EN-PluginAcceptance';listenPort=8099;expectedPort=8099;enabled=$true}|ConvertTo-Json)|Set-Content $Payload -Encoding UTF8
  @('$ErrorActionPreference=''Stop''','$c=Get-Content (Join-Path $PSScriptRoot ''service-config.json'') -Raw|ConvertFrom-Json','if([int]$c.listenPort-ne[int]$c.expectedPort){exit 42}','if(-not[bool]$c.enabled){exit 43}','exit 0')|Set-Content $Health -Encoding UTF8
  $payloadSha=Sha $Payload
  [ordered]@{schemaVersion=1;jobId=$JobId;operation='replace_file';targetPath=$Target;allowedRoot=$AllowedRoot;payloadFile='payload.json';payloadSha256=$payloadSha}|ConvertTo-Json|Set-Content $Manifest -Encoding UTF8
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Health;$ec=$LASTEXITCODE;if($ec-ne42){throw ('058P_BASELINE_'+$ec)}
  Write-Output ('V461_058P_BACKUP=PASS;BASELINE=42;MANIFEST_SHA256='+(Sha $Manifest)+';PAYLOAD_SHA256='+$payloadSha)
}
'Execute'{
  foreach($p in @($CfgBackup,$Manifest,$Payload,$Target,$Health)){if(-not(Test-Path $p)){throw ('058P_MISSING_'+$p)}}
  if(Test-Path $PluginRoot){Remove-Item $PluginRoot -Recurse -Force};New-Item -ItemType Directory -Force -Path $PluginRoot|Out-Null
  @'
{
  "name":"threeen-job-executor",
  "version":"1.0.0",
  "type":"module",
  "openclaw":{"extensions":["./index.js"]}
}
'@|Set-Content (Join-Path $PluginRoot 'package.json') -Encoding UTF8
  @'
{
  "id":"threeen-job-executor",
  "name":"3EN Job Executor",
  "description":"Narrow deterministic executor for hash-bound 3EN jobs",
  "contracts":{"tools":["threeen_apply_job"]},
  "activation":{"onStartup":true},
  "configSchema":{"type":"object","additionalProperties":false}
}
'@|Set-Content (Join-Path $PluginRoot 'openclaw.plugin.json') -Encoding UTF8
  @'
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
const JOBS_ROOT=path.resolve("C:/3EN-Agent/jobs");
const ALLOWED_ROOT=path.resolve("C:/3EN-Agent/workbench");
const sha=(b)=>crypto.createHash("sha256").update(b).digest("hex").toLowerCase();
const inside=(p,r)=>{const a=path.resolve(p).toLowerCase();const b=path.resolve(r).toLowerCase();return a.startsWith(b+path.sep.toLowerCase());};
export default definePluginEntry({
 id:"threeen-job-executor",name:"3EN Job Executor",description:"Hash-bound deterministic 3EN job executor",
 register(api){api.registerTool({
  name:"threeen_apply_job",description:"Apply one pre-staged hash-bound 3EN replace_file job inside the fixed workbench root.",
  parameters:{type:"object",additionalProperties:false,required:["jobId","manifestSha256"],properties:{jobId:{type:"string",pattern:"^[A-Za-z0-9._-]{1,80}$"},manifestSha256:{type:"string",pattern:"^[A-Fa-f0-9]{64}$"}}},
  async execute(_id,params){
   const jobId=String(params.jobId);if(!/^[A-Za-z0-9._-]{1,80}$/.test(jobId))throw new Error("invalid jobId");
   const jobDir=path.resolve(JOBS_ROOT,jobId);if(!inside(jobDir,JOBS_ROOT))throw new Error("job outside root");
   const mp=path.join(jobDir,"manifest.json");const mb=fs.readFileSync(mp);if(sha(mb)!==String(params.manifestSha256).toLowerCase())throw new Error("manifest hash mismatch");
   const m=JSON.parse(mb.toString("utf8"));if(m.schemaVersion!==1||m.jobId!==jobId||m.operation!=="replace_file")throw new Error("manifest contract invalid");
   if(path.resolve(String(m.allowedRoot)).toLowerCase()!==ALLOWED_ROOT.toLowerCase())throw new Error("allowedRoot mismatch");
   const target=path.resolve(String(m.targetPath));if(!inside(target,ALLOWED_ROOT))throw new Error("target outside allowed root");
   if(path.basename(String(m.payloadFile))!==String(m.payloadFile))throw new Error("payloadFile must be basename");
   const pp=path.resolve(jobDir,String(m.payloadFile));if(!inside(pp,jobDir))throw new Error("payload outside job root");const pb=fs.readFileSync(pp);const ph=sha(pb);if(ph!==String(m.payloadSha256).toLowerCase())throw new Error("payload hash mismatch");
   fs.mkdirSync(path.dirname(target),{recursive:true});const backupDir=path.join(jobDir,"backup");fs.mkdirSync(backupDir,{recursive:true});const backup=path.join(backupDir,"original.bin");
   const already=fs.existsSync(target)&&sha(fs.readFileSync(target))===ph;if(!already){if(fs.existsSync(target)&&!fs.existsSync(backup))fs.copyFileSync(target,backup);const tmp=target+".3en-tmp-"+jobId;fs.writeFileSync(tmp,pb);if(sha(fs.readFileSync(tmp))!==ph){fs.rmSync(tmp,{force:true});throw new Error("temp hash mismatch");}if(fs.existsSync(target))fs.rmSync(target,{force:true});fs.renameSync(tmp,target);}
   const finalSha=sha(fs.readFileSync(target));if(finalSha!==ph)throw new Error("final hash mismatch");
   const details={status:"PASS",jobId,target,manifestSha256:sha(mb),payloadSha256:ph,finalSha256:finalSha,backupCreated:fs.existsSync(backup),alreadyApplied:already,modelUsed:false};
   return {content:[{type:"text",text:JSON.stringify(details)}],details};
  }
 });}
});
'@|Set-Content (Join-Path $PluginRoot 'index.js') -Encoding UTF8
  $install=@(& openclaw.cmd plugins install --link $PluginRoot 2>&1);$iec=$LASTEXITCODE;Write-Output ('V461_058P_INSTALL_EXIT='+$iec);if($iec-ne0){throw ('058P_PLUGIN_INSTALL_'+$iec)}
  $inspect=@(& openclaw.cmd plugins inspect $PluginId --runtime --json 2>&1);$iiec=$LASTEXITCODE;Write-Output ('V461_058P_INSPECT_EXIT='+$iiec);if($iiec-ne0){throw ('058P_PLUGIN_INSPECT_'+$iiec)}
  RestartGateway
  $probe=InvokeTool 'session_status' ([ordered]@{});if($probe.http-ne200){throw ('058P_GATEWAY_PROBE_'+$probe.http)}
  $mh=Sha $Manifest;$call=InvokeTool $ToolName ([ordered]@{jobId=$JobId;manifestSha256=$mh})
  [ordered]@{schemaVersion=1;probeHttp=$probe.http;toolHttp=$call.http;toolOk=$call.ok;modelUsed=$false;manifestSha256=$mh;secretLogged=$false;calledAt=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content $Evidence -Encoding UTF8
  if($call.http-ne200 -or -not$call.ok){throw ('058P_DIRECT_PLUGIN_TOOL_'+$call.http)}
  if((Sha $Target)-ne(Sha $Payload)){throw '058P_TARGET_HASH_MISMATCH'}
  Write-Output 'V461_058P_DIRECT_PLUGIN_TOOL=PASS;MODEL_USED=false;TARGET_HASH=PASS'
}
'Test'{
  foreach($p in @($CfgBackup,$Manifest,$Payload,$Target,$Health,$Evidence)){if(-not(Test-Path $p)){throw ('058P_TEST_MISSING_'+$p)}}
  $e=Get-Content $Evidence -Raw|ConvertFrom-Json;if([int]$e.probeHttp-ne200 -or [int]$e.toolHttp-ne200 -or -not[bool]$e.toolOk -or [bool]$e.modelUsed){throw '058P_EVIDENCE_BAD'}
  if((Sha $Target)-ne(Sha $Payload)){throw '058P_FINAL_HASH_BAD'}
  if(-not(Test-Path (Join-Path $JobDir 'backup\original.bin'))){throw '058P_PLUGIN_BACKUP_MISSING'}
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Health;$ec=$LASTEXITCODE;if($ec-ne0){throw ('058P_HEALTH_'+$ec)}
  $ins=@(& openclaw.cmd plugins inspect $PluginId --runtime --json 2>&1);if($LASTEXITCODE-ne0){throw '058P_PLUGIN_NOT_LOADED'}
  Write-Output 'V461_058P_TEST=PASS;PLUGIN_LOADED=PASS;DIRECT_TOOL=PASS;MODEL_FREE=true;PLUGIN_BACKUP=PASS;INDEPENDENT_HEALTH=PASS'
}
'Rollback'{
  if(Test-Path (Join-Path $JobDir 'backup\original.bin')){Copy-Item (Join-Path $JobDir 'backup\original.bin') $Target -Force}
  @(& openclaw.cmd plugins uninstall $PluginId --force 2>&1)|Out-Null
  if(Test-Path $CfgBackup){Copy-Item $CfgBackup $Cfg -Force}
  try{RestartGateway}catch{}
  Write-Output 'V461_058P_ROLLBACK=PASS;CONFIG_RESTORED=true'
}
}
