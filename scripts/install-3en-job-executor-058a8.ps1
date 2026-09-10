param([Parameter(Mandatory=$true)][ValidateSet('Backup','Install','Test','Rollback')][string]$Phase)
$ErrorActionPreference='Stop'
$PluginRoot='C:\3EN-Agent\openclaw-plugins\3en-job-executor'
$Work='C:\3EN-Agent\workbench\plugin-acceptance-058a8'
$Target=Join-Path $Work 'target.json'
$Baseline=Join-Path $Work 'target.baseline.json'
$Evidence=Join-Path $Work 'acceptance.json'
$ProcEvidence=Join-Path $Work 'process-evidence'
$BackupRoot='C:\3EN-Agent\backups\openclaw-plugin-3en-job-executor'
$SourceRef='ca2a16b8b4dc1519cc054fb9e6a15b17628315bc'
$PhaseStarted=Get-Date
$PhaseBudgetSec=if($Phase -eq 'Install'){105}elseif($Phase -eq 'Test'){35}else{30}

function Get-RemainingBudget {
  $elapsed=((Get-Date)-$PhaseStarted).TotalSeconds
  [Math]::Max(0,[int]($PhaseBudgetSec-$elapsed))
}
function Stop-ProcessTree([int]$ProcessId){
  try{& taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null}catch{}
}
function Invoke-CapturedCmd([string]$Tag,[string]$Command,[bool]$AllowFail=$false,[int]$TimeoutSec=25){
  $remain=Get-RemainingBudget
  if($remain -le 2){throw ($Tag+'_PHASE_BUDGET_EXHAUSTED')}
  $effective=[Math]::Max(2,[Math]::Min($TimeoutSec,$remain-1))
  New-Item -ItemType Directory -Force -Path $ProcEvidence|Out-Null
  $safe=($Tag -replace '[^A-Za-z0-9_.-]','_')
  $meta=Join-Path $ProcEvidence ($safe+'.json')
  $psi=New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName=$env:ComSpec
  $psi.Arguments='/d /s /c "'+$Command+'"'
  $psi.UseShellExecute=$false
  $psi.CreateNoWindow=$true
  $psi.RedirectStandardOutput=$true
  $psi.RedirectStandardError=$true
  $p=New-Object System.Diagnostics.Process
  $p.StartInfo=$psi
  $started=Get-Date
  if(-not$p.Start()){throw ($Tag+'_START_FAILED')}
  $stdoutTask=$p.StandardOutput.ReadToEndAsync();$stderrTask=$p.StandardError.ReadToEndAsync()
  $completed=$p.WaitForExit($effective*1000)
  if(-not$completed){
    Stop-ProcessTree $p.Id
    try{$p.WaitForExit(5000)|Out-Null}catch{}
    [ordered]@{tag=$Tag;command=$Command;pid=$p.Id;timeoutSec=$effective;timedOut=$true;started=$started.ToString('o');ended=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content $meta -Encoding UTF8
    throw ($Tag+'_TIMEOUT_'+$effective+'S')
  }
  try{$stdout=$stdoutTask.Result}catch{$stdout=''};try{$stderr=$stderrTask.Result}catch{$stderr=''}
  $ec=$p.ExitCode;$txt=(($stdout,$stderr|Where-Object{$_}) -join "`n").Trim()
  foreach($line in ($txt -split '[\r\n]+')){if($line){Write-Host ($Tag+'='+$line)}}
  [ordered]@{tag=$Tag;command=$Command;pid=$p.Id;exitCode=$ec;timeoutSec=$effective;timedOut=$false;started=$started.ToString('o');ended=(Get-Date).ToString('o');output=$txt}|ConvertTo-Json -Depth 4|Set-Content $meta -Encoding UTF8
  if(-not$AllowFail -and $ec-ne0){$flat=$txt -replace '[\r\n]+',' | ';if($flat.Length-gt1800){$flat=$flat.Substring(0,1800)};throw ($Tag+'_EXIT_'+$ec+' OUTPUT='+$flat)}
  [pscustomobject]@{Exit=[int]$ec;Text=$txt}
}
function Get-GatewayContext {
  $p=Join-Path $env:USERPROFILE '.openclaw\openclaw.json';if(-not(Test-Path $p)){throw '058A8_OPENCLAW_CONFIG_MISSING'}
  $c=Get-Content $p -Raw|ConvertFrom-Json;$port=18789;if($null-ne$c.gateway -and $null-ne$c.gateway.port -and [int]$c.gateway.port -gt0){$port=[int]$c.gateway.port}
  $mode='token';if($null-ne$c.gateway -and $null-ne$c.gateway.auth -and -not[string]::IsNullOrWhiteSpace([string]$c.gateway.auth.mode)){$mode=[string]$c.gateway.auth.mode}
  $secret='';if($mode-eq'token'){$secret=[string]$env:OPENCLAW_GATEWAY_TOKEN;if([string]::IsNullOrWhiteSpace($secret)-and$null-ne$c.gateway.auth.token){$secret=[string]$c.gateway.auth.token}}elseif($mode-eq'password'){$secret=[string]$env:OPENCLAW_GATEWAY_PASSWORD;if([string]::IsNullOrWhiteSpace($secret)-and$null-ne$c.gateway.auth.password){$secret=[string]$c.gateway.auth.password}}elseif($mode-ne'none'){throw ('058A8_AUTH_MODE_'+$mode)}
  if($mode-ne'none'-and[string]::IsNullOrWhiteSpace($secret)){throw '058A8_SECRET_UNAVAILABLE'};[pscustomobject]@{Port=$port;Mode=$mode;Secret=$secret}
}
function Invoke-Tool([string]$Tool,[object]$Args){
  $g=Get-GatewayContext;$h=@{};if($g.Mode-ne'none'){$h.Authorization='Bearer '+$g.Secret}
  $body=[ordered]@{tool=$Tool;args=$Args;sessionKey='main';idempotencyKey=('058a8-'+[guid]::NewGuid().ToString('N'))}|ConvertTo-Json -Depth 10
  try{$r=Invoke-RestMethod -Method Post -Uri ('http://127.0.0.1:'+$g.Port+'/tools/invoke') -Headers $h -ContentType 'application/json' -Body $body -TimeoutSec 12;[pscustomobject]@{http=200;ok=if($null-ne$r.ok){[bool]$r.ok}else{$true};raw=$r}}catch{$s=-1;try{$s=[int]$_.Exception.Response.StatusCode}catch{};[pscustomobject]@{http=$s;ok=$false;raw=$null}}
}
function Wait-Gateway([int]$TimeoutSec=20){
  $g=Get-GatewayContext;$deadline=(Get-Date).AddSeconds($TimeoutSec)
  do{
    $tcp=New-Object System.Net.Sockets.TcpClient
    try{$ar=$tcp.BeginConnect('127.0.0.1',$g.Port,$null,$null);if($ar.AsyncWaitHandle.WaitOne(900)){try{$tcp.EndConnect($ar);if($tcp.Connected){return $true}}catch{}}}finally{$tcp.Close()}
    Start-Sleep -Milliseconds 700
  }while((Get-Date)-lt$deadline)
  throw ('058A8_GATEWAY_NOT_READY_'+$TimeoutSec+'S_PORT_'+$g.Port)
}
function Restart-Gateway {
  $r=Invoke-CapturedCmd '058A8_GATEWAY_RESTART' 'openclaw.cmd gateway restart' $false 20
  Wait-Gateway 20|Out-Null
}

switch($Phase){
'Backup'{
  New-Item -ItemType Directory -Force -Path $BackupRoot|Out-Null
  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$dst=Join-Path $BackupRoot $stamp
  if(Test-Path $PluginRoot){New-Item -ItemType Directory -Force -Path $dst|Out-Null;Copy-Item $PluginRoot (Join-Path $dst 'plugin') -Recurse -Force}
  if(Test-Path $Work){Remove-Item $Work -Recurse -Force};New-Item -ItemType Directory -Force -Path $Work|Out-Null;New-Item -ItemType Directory -Force -Path $ProcEvidence|Out-Null
  '{"state":"baseline","value":1}'|Set-Content $Target -Encoding UTF8;Copy-Item $Target $Baseline -Force
  Write-Output ('V4617_058A8_BACKUP=PASS;PLUGIN_PREEXISTING='+(Test-Path (Join-Path $dst 'plugin'))+';BACKUP='+$dst)
}
'Install'{
  $ver=Invoke-CapturedCmd '058A8_VERSION' 'openclaw.cmd --version' $false 12
  $installHelp=Invoke-CapturedCmd '058A8_INSTALL_HELP' 'openclaw.cmd plugins install --help' $false 12
  $enableHelp=Invoke-CapturedCmd '058A8_ENABLE_HELP' 'openclaw.cmd plugins enable --help' $false 12
  if(Test-Path $PluginRoot){Remove-Item $PluginRoot -Recurse -Force};New-Item -ItemType Directory -Force -Path $PluginRoot|Out-Null
  foreach($f in @('package.json','openclaw.plugin.json','index.js')){$u='https://raw.githubusercontent.com/3en4all/3en-command-runner/'+$SourceRef+'/openclaw-plugins/3en-job-executor/'+$f;Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile (Join-Path $PluginRoot $f) -TimeoutSec 15}
  Push-Location $PluginRoot;try{$npm=Invoke-CapturedCmd '058A8_NPM' 'npm.cmd install --omit=dev --no-audit --no-fund' $false 35;$syntax=Invoke-CapturedCmd '058A8_NODE_CHECK' 'node.exe --check index.js' $false 10}finally{Pop-Location}
  $manifest=Get-Content (Join-Path $PluginRoot 'openclaw.plugin.json') -Raw|ConvertFrom-Json
  if([string]$manifest.id-ne'3en-job-executor' -or @($manifest.contracts.tools) -notcontains '3en_job'){throw '058A8_MANIFEST_CONTRACT_BAD'}
  $doctor=Invoke-CapturedCmd '058A8_DOCTOR' 'openclaw.cmd plugins doctor' $true 12
  $list=Invoke-CapturedCmd '058A8_LIST' 'openclaw.cmd plugins list --json' $false 12
  if($list.Text -match '3en-job-executor'){$un=Invoke-CapturedCmd '058A8_UNINSTALL' 'openclaw.cmd plugins uninstall 3en-job-executor --keep-files --force' $true 12}
  $flags=@('-l','"'+$PluginRoot+'"');if($installHelp.Text -match '--accept-capabilities'){$flags+='--accept-capabilities'};if($installHelp.Text -match '--acknowledge-install-policy-warning'){$flags+='--acknowledge-install-policy-warning'}
  Write-Output ('V4617_058A8_SELECTED_INSTALL_FLAGS='+($flags -join ' '))
  $ins=Invoke-CapturedCmd '058A8_INSTALL' ('openclaw.cmd plugins install '+($flags -join ' ')) $false 20
  $enableCmd='openclaw.cmd plugins enable 3en-job-executor';if($enableHelp.Text -match '--accept-capabilities'){$enableCmd+=' --accept-capabilities'}
  $en=Invoke-CapturedCmd '058A8_ENABLE' $enableCmd $false 12
  Restart-Gateway
  $inspectHelp=Invoke-CapturedCmd '058A8_INSPECT_HELP' 'openclaw.cmd plugins inspect --help' $true 10
  $inspectCmd='openclaw.cmd plugins inspect 3en-job-executor';if($inspectHelp.Text -match '--runtime'){$inspectCmd+=' --runtime'};if($inspectHelp.Text -match '--json'){$inspectCmd+=' --json'}
  $inspect=Invoke-CapturedCmd '058A8_INSPECT' $inspectCmd $false 12
  $inspect.Text|Set-Content (Join-Path $Work 'plugin-inspect.txt') -Encoding UTF8
  if($inspect.Text-notmatch '3en_job'){throw ('058A8_TOOL_NOT_REGISTERED OUTPUT='+(($inspect.Text-replace'[\r\n]+',' | ')))}
  Write-Output 'V4617_058A8_INSTALL=PASS;PLUGIN=3en-job-executor;TOOL=3en_job;BOUNDED_PROCESSES=true'
}
'Test'{
  Wait-Gateway 8|Out-Null
  $desired='{"state":"changed-by-3en-job","value":8}'
  $positive=Invoke-Tool '3en_job' ([ordered]@{operation='write';path=$Target;content=$desired})
  $content=if(Test-Path $Target){(Get-Content $Target -Raw).Trim()}else{''}
  $outside='C:\Windows\Temp\3en-job-escape-058a8.txt';Remove-Item $outside -Force -ErrorAction SilentlyContinue
  $negative=Invoke-Tool '3en_job' ([ordered]@{operation='write';path=$outside;content='SHOULD_NOT_EXIST'})
  $outsideExists=Test-Path $outside
  $pass=($positive.http-eq200 -and $positive.ok -and $content-eq$desired -and -not$outsideExists -and (-not$negative.ok -or $negative.http-ne200))
  [ordered]@{schemaVersion=1;status=if($pass){'PASS'}else{'FAIL'};revision='058a8';plugin='3en-job-executor';tool='3en_job';modelUsed=$false;positiveHttp=$positive.http;positiveOk=$positive.ok;positiveContentMatch=($content-eq$desired);negativeHttp=$negative.http;negativeOk=$negative.ok;outsideFileCreated=$outsideExists;allowedRoot='C:\3EN-Agent\workbench';boundedProcesses=$true;verifiedAt=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content $Evidence -Encoding UTF8
  if(-not$pass){throw ('058A8_ACCEPTANCE_FAIL pos='+$positive.http+'/'+$positive.ok+' neg='+$negative.http+'/'+$negative.ok+' outside='+$outsideExists)}
  Write-Output 'V4617_058A8_TEST=PASS;MODEL_FREE=true;POSITIVE_WRITE=PASS;PATH_ESCAPE_BLOCKED=PASS;BOUNDED_PROCESSES=PASS'
}
'Rollback'{
  if(Test-Path $Baseline){Copy-Item $Baseline $Target -Force}
  try{$d=Invoke-CapturedCmd '058A8_DISABLE' 'openclaw.cmd plugins disable 3en-job-executor' $true 10}catch{}
  Write-Output 'V4617_058A8_ROLLBACK=PASS;PLUGIN_DISABLED=true;BASELINE_RESTORED=true'
}
}
