# 3EN Security & Privacy Stack deployer v1
# Windows PowerShell 5.1
param([ValidateSet('Discover','Deploy','Test','Filters','Final','Rollback')][string]$Phase)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent'
$Work=Join-Path $Root 'security-privacy-stack'
$State=Join-Path $Work 'deploy-state.json'
$UiPy=Join-Path $Work '3en-security-privacy-web.py'
$UiUrl='http://127.0.0.1:8765'
$SourceUrl='https://raw.githubusercontent.com/3en4all/3en-command-runner/main/scripts/3en-security-privacy-web.py'
$TaskName='3EN Security Privacy UI'
New-Item -ItemType Directory -Force -Path $Work|Out-Null
function Save($o){$o.updatedUtc=(Get-Date).ToUniversalTime().ToString('o');$o|ConvertTo-Json -Depth 20|Set-Content $State -Encoding UTF8}
function Load{if(-not(Test-Path $State)){throw 'deploy state missing'};Get-Content $State -Raw|ConvertFrom-Json}
function Find-Python{
  $c=@();foreach($cmd in @('python.exe','py.exe')){try{$x=Get-Command $cmd -ErrorAction Stop;if($x.Source){$c+=$x.Source}}catch{}}
  $c+=@(Get-ChildItem "$env:LOCALAPPDATA\Programs\Python" -Filter python.exe -Recurse -ErrorAction SilentlyContinue|Select-Object -Expand FullName)
  foreach($p in $c|Select-Object -Unique){try{$v=& $p --version 2>&1|Out-String;if($LASTEXITCODE-eq0 -and $v-match 'Python 3\.'){return $p}}catch{}}
  return $null
}
function Discover-Monitor{
  $roots=@('C:\3EN-Agent','E:\skrypty',"$env:USERPROFILE\Desktop","$env:USERPROFILE\Documents")|Where-Object{Test-Path $_}
  $hits=New-Object System.Collections.Generic.List[string]
  foreach($r in $roots){Get-ChildItem $r -File -Recurse -ErrorAction SilentlyContinue|Where-Object{$_.Name -match '(?i)3en.*(security|threat|monitor)|(security|threat).*3en' -and $_.Extension -in @('.ps1','.py','.exe','.json')}|Select-Object -First 50|ForEach-Object{[void]$hits.Add($_.FullName)}}
  return @($hits|Select-Object -Unique)
}
function Do-Discover{
  $py=Find-Python;if(-not $py){throw 'Python 3 not found after local environment audit'}
  $rp='C:\3EN-Agent\router-pihole-final\state.json';$rpok=$false;if(Test-Path $rp){try{$x=Get-Content $rp -Raw|ConvertFrom-Json;$rpok=[bool]$x.piholeDns}catch{}}
  $s=[pscustomobject][ordered]@{updatedUtc=$null;python=$py;monitorCandidates=@(Discover-Monitor);routerPiState=$rp;routerPiReady=$rpok;ui=$UiUrl;backup=$null;deployed=$false;filtersApplied=$false;taskCreated=$false}
  Save $s;Write-Host ('PRIVACY_DISCOVERY=PASS;PYTHON='+$py+';MONITOR_CANDIDATES='+@($s.monitorCandidates).Count+';ROUTER_PI_READY='+$rpok)
}
function Do-Deploy{
  if(-not(Test-Path $State)){Do-Discover};$s=Load
  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$bk=Join-Path $Work ('backup-'+$stamp);New-Item -ItemType Directory -Force -Path $bk|Out-Null
  if(Test-Path $UiPy){Copy-Item $UiPy $bk -Force}
  $existing=Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue;if($existing){Export-ScheduledTask -TaskName $TaskName|Set-Content (Join-Path $bk 'scheduled-task.xml') -Encoding UTF8}
  Invoke-WebRequest -UseBasicParsing -Uri $SourceUrl -OutFile $UiPy
  $check=& $s.python -m py_compile $UiPy 2>&1|Out-String;if($LASTEXITCODE-ne0){throw ('GUI Python syntax validation failed: '+$check)}
  $action=New-ScheduledTaskAction -Execute ([string]$s.python) -Argument ('"'+$UiPy+'"')
  $trigger=New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 3650)
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description 'Local 3EN Security & Privacy management UI' -Force|Out-Null
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine -and $_.CommandLine -like '*3en-security-privacy-web.py*'}|ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}
  Start-Process -FilePath ([string]$s.python) -ArgumentList @($UiPy) -WindowStyle Hidden
  Start-Sleep 3
  $s.backup=$bk;$s.deployed=$true;$s.taskCreated=$true;Save $s;Write-Host ('PRIVACY_GUI_DEPLOY=PASS;URL='+$UiUrl)
}
function Do-Test{
  $s=Load
  $r=Invoke-RestMethod -Uri ($UiUrl+'/api/status') -TimeoutSec 12
  if(-not $r.router.ok){throw 'GUI reports router offline'}
  if(-not $r.pihole.dns){throw 'GUI reports Pi-hole DNS unhealthy'}
  $h=Invoke-WebRequest -UseBasicParsing -Uri $UiUrl -TimeoutSec 10
  if($h.Content -notmatch '3EN Security'){throw 'GUI HTML validation failed'}
  $t=Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop;if($t.State -eq 'Disabled'){throw 'GUI scheduled task disabled'}
  Write-Host ('PRIVACY_GUI_TEST=PASS;SEC_EVENTS='+$r.security.total+';GRAVITY='+$r.pihole.gravity)
}
function Do-Filters{
  $s=Load
  if(-not $s.deployed){Do-Deploy;$s=Load}
  $before=Invoke-RestMethod -Uri ($UiUrl+'/api/status') -TimeoutSec 12
  $body=@{action='apply_policy'}|ConvertTo-Json
  Invoke-RestMethod -Method Post -Uri ($UiUrl+'/api/action') -ContentType 'application/json' -Body $body -TimeoutSec 240|Out-Null
  Start-Sleep 2
  $after=Invoke-RestMethod -Uri ($UiUrl+'/api/status') -TimeoutSec 12
  if(-not $after.pihole.blocking){throw 'Pi-hole filtering not enabled after policy application'}
  if([int64]$after.pihole.gravity -lt 10000){throw ('gravity unexpectedly small: '+$after.pihole.gravity)}
  $lists=Invoke-RestMethod -Uri ($UiUrl+'/api/adlists') -TimeoutSec 12
  $urls=@($lists.items|Select-Object -Expand address)
  if($urls -notcontains 'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/pro.txt'){throw 'HaGeZi Pro missing'}
  if($urls -notcontains 'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/tif.txt'){throw 'HaGeZi TIF missing'}
  $s.filtersApplied=$true;Save $s;Write-Host ('PRIVACY_FILTER_POLICY=PASS;GRAVITY='+$after.pihole.gravity+';ADLISTS='+$after.pihole.adlists)
}
function Do-Final{
  Do-Test;$s=Load
  $st=Invoke-RestMethod -Uri ($UiUrl+'/api/status') -TimeoutSec 12
  if(-not $s.filtersApplied){throw 'recommended filter policy not applied'}
  $report=@('3EN SECURITY & PRIVACY STACK FINAL','UTC='+((Get-Date).ToUniversalTime().ToString('o')),'UI='+$UiUrl,'ROUTER='+$st.router.ok,'PIHOLE_DNS='+$st.pihole.dns,'FILTERING='+$st.pihole.blocking,'GRAVITY='+$st.pihole.gravity,'ADLISTS='+$st.pihole.adlists,'SECURITY_EVENTS='+$st.security.total,'FINAL_STATUS=SUCCESS')
  $report|Set-Content (Join-Path $Work 'FINAL-REPORT.txt') -Encoding UTF8;$report|ForEach-Object{Write-Host $_}
}
function Do-Rollback{
  if(-not(Test-Path $State)){Write-Host 'PRIVACY_ROLLBACK_NO_STATE';return};$s=Load
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine -and $_.CommandLine -like '*3en-security-privacy-web.py*'}|ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}
  if($s.backup -and (Test-Path (Join-Path $s.backup '3en-security-privacy-web.py'))){Copy-Item (Join-Path $s.backup '3en-security-privacy-web.py') $UiPy -Force}
  Write-Host 'PRIVACY_GUI_ROLLBACK=PASS;PIHOLE_REMOTE_BACKUPS_PRESERVED'
}
switch($Phase){'Discover'{Do-Discover};'Deploy'{Do-Deploy};'Test'{Do-Test};'Filters'{Do-Filters};'Final'{Do-Final};'Rollback'{Do-Rollback}}
