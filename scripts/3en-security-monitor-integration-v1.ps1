# 3EN Security Monitor Integration v1
# Windows PowerShell 5.1
param([ValidateSet('Discover','Deploy','Test','Final','Rollback')][string]$Phase)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent'
$Work=Join-Path $Root 'security-monitor-integration'
$State=Join-Path $Work 'state.json'
$Bridge=Join-Path $Work '3en-security-monitor-bridge-v1.py'
$Source='https://raw.githubusercontent.com/3en4all/3en-command-runner/main/scripts/3en-security-monitor-bridge-v1.py'
$Url='http://127.0.0.1:8766'
$TaskName='3EN Security Monitor Bridge'
$Router='192.168.1.2'
$RouterKey='C:\Users\wi3lk\.ssh\3en002_agent_ed25519'
New-Item -ItemType Directory -Force -Path $Work|Out-Null
function Save($o){$o.updatedUtc=(Get-Date).ToUniversalTime().ToString('o');$o|ConvertTo-Json -Depth 20|Set-Content $State -Encoding UTF8}
function Load{if(-not(Test-Path $State)){throw 'integration state missing'};Get-Content $State -Raw|ConvertFrom-Json}
function Find-Python{
  foreach($p in @((Get-Command python.exe -ErrorAction SilentlyContinue).Source,(Get-Command py.exe -ErrorAction SilentlyContinue).Source)){
    if($p){try{$v=& $p --version 2>&1|Out-String;if($LASTEXITCODE-eq0 -and $v-match 'Python 3\.'){return $p}}catch{}}
  }
  $c=Get-ChildItem "$env:LOCALAPPDATA\Programs\Python" -Filter python.exe -Recurse -ErrorAction SilentlyContinue|Select-Object -Expand FullName
  foreach($p in $c){try{$v=& $p --version 2>&1|Out-String;if($LASTEXITCODE-eq0 -and $v-match 'Python 3\.'){return $p}}catch{}}
  throw 'Python 3 not found'
}
function RouterProbe{
  if(-not(Test-Path $RouterKey)){throw 'router SSH key missing'}
  $o=& ssh.exe -i $RouterKey -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new root@$Router "printf 3EN_ROUTER_OK" 2>&1|Out-String
  if($LASTEXITCODE-ne0 -or $o -notmatch '3EN_ROUTER_OK'){throw 'router SSH probe failed'}
}
function Discover-LocalSource{
  $roots=@('C:\3EN-Agent','E:\skrypty',"$env:USERPROFILE\Desktop","$env:USERPROFILE\Documents")|Where-Object{Test-Path $_}
  $hits=New-Object System.Collections.Generic.List[string]
  foreach($r in $roots){
    Get-ChildItem $r -File -Recurse -ErrorAction SilentlyContinue|Where-Object{$_.Name -ieq '3en-threats.json' -or ($_.Extension -eq '.json' -and $_.Name -match '(?i)(threat|security)')}|ForEach-Object{[void]$hits.Add($_.FullName)}
  }
  return @($hits|Select-Object -Unique)
}
function Do-Discover{
  $py=Find-Python;RouterProbe;$hits=@(Discover-LocalSource)
  $s=[pscustomobject][ordered]@{updatedUtc=$null;python=$py;routerSsh=$true;router=$Router;routerKey=$RouterKey;sourceCandidates=$hits;sourceCount=$hits.Count;bridge=$Bridge;url=$Url;backup=$null;deployed=$false}
  Save $s
  Write-Host ('SEC_MON_DISCOVERY=PASS;ROUTER_SSH=True;SOURCE_CANDIDATES='+$hits.Count)
}
function Do-Deploy{
  if(-not(Test-Path $State)){Do-Discover};$s=Load
  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$bk=Join-Path $Work ('backup-'+$stamp);New-Item -ItemType Directory -Force -Path $bk|Out-Null
  if(Test-Path $Bridge){Copy-Item $Bridge $bk -Force}
  $old=Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue;if($old){Export-ScheduledTask -TaskName $TaskName|Set-Content (Join-Path $bk 'scheduled-task.xml') -Encoding UTF8}
  Invoke-WebRequest -UseBasicParsing -Uri $Source -OutFile $Bridge
  & $s.python -m py_compile $Bridge
  if($LASTEXITCODE-ne0){throw 'bridge syntax check failed'}
  $action=New-ScheduledTaskAction -Execute ([string]$s.python) -Argument ('"'+$Bridge+'"')
  $trigger=New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 3650)
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description '3EN Security Monitor integration bridge' -Force|Out-Null
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine -and $_.CommandLine -like '*3en-security-monitor-bridge-v1.py*'}|ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}
  Start-Process -FilePath ([string]$s.python) -ArgumentList @($Bridge) -WindowStyle Hidden
  Start-Sleep 3
  $s.backup=$bk;$s.deployed=$true;Save $s
  Write-Host ('SEC_MON_DEPLOY=PASS;URL='+$Url)
}
function Do-Test{
  $s=Load
  $r=Invoke-RestMethod ($Url+'/api/status') -TimeoutSec 12
  if(-not $r.routerSsh){throw 'bridge reports router SSH unavailable'}
  $h=Invoke-WebRequest -UseBasicParsing $Url -TimeoutSec 10
  if($h.Content -notmatch '3EN Threat Control'){throw 'bridge HTML validation failed'}
  $t=Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop;if($t.State -eq 'Disabled'){throw 'bridge scheduled task disabled'}
  Write-Host ('SEC_MON_TEST=PASS;THREATS='+@($r.items).Count+';BLOCKED='+$r.blockedCount+';SOURCE='+$r.source)
}
function Do-Final{
  Do-Test
  $r=Invoke-RestMethod ($Url+'/api/status') -TimeoutSec 12
  $report=@('3EN SECURITY MONITOR INTEGRATION FINAL','UTC='+((Get-Date).ToUniversalTime().ToString('o')),'URL='+$Url,'ROUTER_SSH='+$r.routerSsh,'SOURCE='+$r.source,'THREATS='+@($r.items).Count,'BLOCKED='+$r.blockedCount,'AUDIT='+$r.audit,'FINAL_STATUS=SUCCESS')
  $report|Set-Content (Join-Path $Work 'FINAL-REPORT.txt') -Encoding UTF8;$report|ForEach-Object{Write-Host $_}
}
function Do-Rollback{
  if(Test-Path $State){$s=Load}else{$s=$null}
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine -and $_.CommandLine -like '*3en-security-monitor-bridge-v1.py*'}|ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}
  if($s -and $s.backup -and (Test-Path (Join-Path $s.backup '3en-security-monitor-bridge-v1.py'))){Copy-Item (Join-Path $s.backup '3en-security-monitor-bridge-v1.py') $Bridge -Force}
  Write-Host 'SEC_MON_ROLLBACK=PASS;ROUTER_BLOCKLIST_PRESERVED'
}
switch($Phase){'Discover'{Do-Discover};'Deploy'{Do-Deploy};'Test'{Do-Test};'Final'{Do-Final};'Rollback'{Do-Rollback}}
