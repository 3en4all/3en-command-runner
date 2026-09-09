# 3EN Network/Privacy Autopilot v1
# Persistent supervisor: Router/Pi-hole phases -> Privacy Stack
# Windows PowerShell 5.1
param([switch]$Once)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent'
$Work=Join-Path $Root 'network-autopilot'
$StatePath=Join-Path $Work 'state.json'
$LogPath=Join-Path $Work 'autopilot.log'
$Finalizer=Join-Path $Root 'router-pihole-finalize-v1.ps1'
$Runner=Join-Path $Root '3en-agent-runner-v3.10.1.ps1'
$Repo='3en4all/3en-command-runner'
$ControlRaw='https://raw.githubusercontent.com/3en4all/3en-command-runner/main/autopilot/router-pihole-control.json'
New-Item -ItemType Directory -Force -Path $Work|Out-Null

function Log([string]$m,[string]$l='INFO'){
  $x='[{0}][{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$l,$m
  $x|Tee-Object -FilePath $LogPath -Append|Write-Host
}
function Save($s){$s.updatedUtc=(Get-Date).ToUniversalTime().ToString('o');$s|ConvertTo-Json -Depth 20|Set-Content $StatePath -Encoding UTF8}
function Load{
  if(Test-Path $StatePath){try{return Get-Content $StatePath -Raw|ConvertFrom-Json}catch{}}
  return [pscustomobject][ordered]@{schema=1;generation=0;stage='DISCOVERY';status='READY';lastError='';lastTranscript='';privacyStarted=$false;updatedUtc=$null}
}
function Control{
  $u=$ControlRaw+'?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  return Invoke-RestMethod -UseBasicParsing -Uri $u -TimeoutSec 20
}
function Download-Finalizer($c){
  $rev=[string]$c.finalizerRevision
  if([string]::IsNullOrWhiteSpace($rev)){throw 'control finalizerRevision missing'}
  $u='https://raw.githubusercontent.com/'+$Repo+'/'+$rev+'/scripts/router-pihole-finalize-v1.ps1'
  Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $Finalizer -TimeoutSec 30
  $t=$null;$e=$null;[System.Management.Automation.Language.Parser]::ParseFile($Finalizer,[ref]$t,[ref]$e)|Out-Null
  if(@($e).Count -gt 0){throw ('finalizer syntax errors='+@($e).Count)}
}
function Publish-Diagnostic($s){
  try{
    $tok=$env:THREEEN_GH_TOKEN
    if([string]::IsNullOrWhiteSpace($tok)){$tok=[Environment]::GetEnvironmentVariable('THREEEN_GH_TOKEN','User')}
    if([string]::IsNullOrWhiteSpace($tok)){return}
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    $remote='results/autopilot-network-'+$stamp+'.json'
    $uri='https://api.github.com/repos/'+$Repo+'/contents/'+$remote
    $body=@{message='network autopilot diagnostic '+$stamp;branch='main';content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($s|ConvertTo-Json -Depth 20)))}|ConvertTo-Json -Compress
    $h=@{Authorization='Bearer '+$tok;Accept='application/vnd.github+json';'X-GitHub-Api-Version'='2022-11-28';'User-Agent'='3EN-Network-Autopilot'}
    Invoke-RestMethod -Method Put -Uri $uri -Headers $h -ContentType 'application/json' -Body $body -TimeoutSec 20|Out-Null
  }catch{Log ('diagnostic publish failed: '+$_.Exception.Message) 'WARN'}
}
function Run-Step([string]$name,[scriptblock]$code,$s){
  $tr=Join-Path $Work (('{0}-{1}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'),$name))
  try{
    Log ($name+' START')
    $o=& $code *>&1
    if($null-ne$o){$o|Out-String|Set-Content $tr -Encoding UTF8}
    $s.lastTranscript=$tr;$s.lastError='';$s.status='SUCCESS';Save $s
    Log ($name+' PASS')
    return $true
  }catch{
    ($_|Out-String)|Set-Content $tr -Encoding UTF8
    $s.lastTranscript=$tr;$s.lastError=$_.Exception.Message;$s.status='FAILED_WAITING_FOR_REPAIR';Save $s
    Log ($name+' FAILED: '+$_.Exception.Message) 'ERROR'
    Publish-Diagnostic $s
    return $false
  }
}
function Start-Privacy($c,$s){
  if($s.privacyStarted){return $true}
  $project=[string]$c.privacyProjectPath
  if([string]::IsNullOrWhiteSpace($project)){throw 'privacyProjectPath missing'}
  if(-not(Test-Path $Runner)){Invoke-WebRequest -UseBasicParsing -Uri ('https://raw.githubusercontent.com/'+$Repo+'/main/3en-agent-runner-v3.10.1.ps1') -OutFile $Runner}
  Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Runner,'-ProjectPath',$project) -WorkingDirectory $Root|Out-Null
  $s.privacyStarted=$true;$s.stage='PRIVACY';$s.status='STARTED';Save $s
  Log ('PRIVACY STARTED project='+$project)
  return $true
}

$mutex=New-Object Threading.Mutex($false,'Global\3EN-Network-Autopilot-v1')
if(-not $mutex.WaitOne(0)){Log 'Another autopilot instance already running';exit 2}
try{
  Log '3EN Network/Privacy Autopilot v1 started'
  while($true){
    $s=Load
    try{$c=Control}catch{Log ('control read failed: '+$_.Exception.Message) 'WARN';if($Once){break};Start-Sleep 15;continue}
    if(-not [bool]$c.enabled){$s.status='PAUSED_BY_CONTROL';Save $s;Log 'Paused by control';if($Once){break};Start-Sleep ([int]$c.pollSeconds);continue}
    $gen=[int]$c.generation
    if($s.status -eq 'FAILED_WAITING_FOR_REPAIR' -and $gen -le [int]$s.generation){
      Log ('Waiting for repair generation > '+$s.generation+'; stage='+$s.stage)
      if($Once){break};Start-Sleep ([Math]::Max(5,[int]$c.pollSeconds));continue
    }
    if($gen -gt [int]$s.generation){$s.generation=$gen;$s.status='RETRY_AFTER_CONTROL_UPDATE';Save $s;Log ('Control generation accepted='+$gen)}
    try{Download-Finalizer $c}catch{
      $s.lastError=$_.Exception.Message;$s.status='FAILED_WAITING_FOR_REPAIR';Save $s;Publish-Diagnostic $s
      if($Once){break};Start-Sleep ([Math]::Max(5,[int]$c.pollSeconds));continue
    }

    $ok=$true
    switch([string]$s.stage){
      'DISCOVERY' {
        $ok=Run-Step 'DISCOVERY' {& $Finalizer -Phase Discovery} $s
        if($ok){$s=Load;$s.stage='BACKUP';$s.status='READY';Save $s}
      }
      'BACKUP' {
        $ok=Run-Step 'BACKUP' {& $Finalizer -Phase Backup} $s
        if($ok){$s=Load;$s.stage='DNS';$s.status='READY';Save $s}
      }
      'DNS' {
        $ok=Run-Step 'DNS' {& $Finalizer -Phase ApplyDns;& $Finalizer -Phase TestDns} $s
        if($ok){$s=Load;$s.stage='LOGGING';$s.status='READY';Save $s}
      }
      'LOGGING' {
        $ok=Run-Step 'LOGGING' {& $Finalizer -Phase ApplyLogging;& $Finalizer -Phase TestLogging} $s
        if($ok){$s=Load;$s.stage='FINAL';$s.status='READY';Save $s}
      }
      'FINAL' {
        $ok=Run-Step 'FINAL' {& $Finalizer -Phase Final} $s
        if($ok){$s=Load;$s.stage='HANDOVER';$s.status='READY';Save $s}
      }
      'HANDOVER' {
        try{[void](Start-Privacy $c $s);$s=Load;$s.status='ROUTER_PIHOLE_SUCCESS_PRIVACY_STARTED';Save $s;Publish-Diagnostic $s}
        catch{$s.lastError=$_.Exception.Message;$s.status='FAILED_WAITING_FOR_REPAIR';Save $s;Publish-Diagnostic $s;$ok=$false}
      }
      'PRIVACY' {Log 'Router/Pi-hole finished; Privacy project already launched';$ok=$true}
      default {$s.stage='DISCOVERY';$s.status='READY';Save $s}
    }
    if($Once){break}
    if([string](Load).stage -eq 'PRIVACY'){Start-Sleep 60}else{Start-Sleep 2}
  }
}finally{try{$mutex.ReleaseMutex()}catch{};$mutex.Dispose()}
