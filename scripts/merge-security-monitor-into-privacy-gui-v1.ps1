param([ValidateSet('Apply','Test','Rollback')][string]$Phase='Apply')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent'
$Work=Join-Path $Root 'security-privacy-stack'
$Ui=Join-Path $Work '3en-security-privacy-web.py'
$BridgeUrl='http://127.0.0.1:8766'
$UiUrl='http://127.0.0.1:8765'
$TaskName='3EN Security Privacy UI'
$State=Join-Path $Work 'security-monitor-merge-state.json'
function Save-State($o){$o|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $State -Encoding UTF8}
function Load-State{if(-not(Test-Path $State)){throw 'merge state missing'};Get-Content $State -Raw|ConvertFrom-Json}
function Get-Python{
  $d=Join-Path $Work 'deploy-state.json'
  if(Test-Path $d){try{$x=Get-Content $d -Raw|ConvertFrom-Json;if($x.python -and (Test-Path ([string]$x.python))){return [string]$x.python}}catch{}}
  foreach($n in @('python.exe','py.exe')){try{$c=Get-Command $n -ErrorAction Stop;if($c.Source){return $c.Source}}catch{}}
  throw 'Python not found'
}
function Restart-Ui{
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine -and $_.CommandLine -like '*3en-security-privacy-web.py*'}|ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}
  Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
  Start-Sleep -Seconds 3
}
function Apply{
  if(-not(Test-Path $Ui)){throw 'Privacy GUI source missing'}
  $bridge=Invoke-RestMethod -Uri ($BridgeUrl+'/api/status') -TimeoutSec 10
  if(-not $bridge.routerSsh){throw 'Security Monitor bridge reports router SSH unavailable'}
  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$bk=Join-Path $Work ('backup-security-monitor-merge-'+$stamp);New-Item -ItemType Directory -Force -Path $bk|Out-Null
  Copy-Item $Ui (Join-Path $bk '3en-security-privacy-web.py') -Force
  $src=Get-Content $Ui -Raw -Encoding UTF8
  if($src -notmatch 'data-tab="threats"'){
    $needle='<button class="active" data-tab="overview">Overview</button><button data-tab="privacy">Privacy / DNS</button><button data-tab="domains">Allow / Deny</button><button data-tab="security">Security Events</button><button data-tab="system">System</button>'
    $repl='<button class="active" data-tab="overview">Overview</button><button data-tab="privacy">Privacy / DNS</button><button data-tab="domains">Allow / Deny</button><button data-tab="security">Security Events</button><button data-tab="threats">Threat Control</button><button data-tab="system">System</button>'
    if(-not $src.Contains($needle)){throw 'Privacy GUI navigation anchor not found'}
    $src=$src.Replace($needle,$repl)
    $anchor='<section id="system" class="tab hidden">'
    $section='<section id="threats" class="tab hidden"><div class="section"><h2>Threat Control</h2><div class="notice">Live threat evidence and persistent manual Block / Unblock on 3EN002. Actions are audited by 3EN Security Monitor bridge.</div><iframe title="3EN Threat Control" src="http://127.0.0.1:8766" style="width:100%;height:68vh;min-height:560px;border:1px solid var(--line);border-radius:14px;background:#0b0f14"></iframe></div></section>'
    if(-not $src.Contains($anchor)){throw 'Privacy GUI system-section anchor not found'}
    $src=$src.Replace($anchor,$section+$anchor)
    Set-Content -LiteralPath $Ui -Value $src -Encoding UTF8
  }
  $py=Get-Python;$o=& $py -m py_compile $Ui 2>&1|Out-String;if($LASTEXITCODE-ne0){Copy-Item (Join-Path $bk '3en-security-privacy-web.py') $Ui -Force;throw ('merged GUI syntax failed: '+$o)}
  Restart-Ui
  Save-State ([pscustomobject]@{schemaVersion=1;backup=$bk;ui=$UiUrl;bridge=$BridgeUrl;threats=[int]@($bridge.items).Count;appliedAt=(Get-Date).ToString('o')})
  Write-Host ('SEC_PRIVACY_MERGE=PASS;UI='+$UiUrl+';THREATS='+@($bridge.items).Count+';BACKUP='+$bk)
}
function Test{
  $h=Invoke-WebRequest -UseBasicParsing -Uri $UiUrl -TimeoutSec 12
  if($h.Content -notmatch 'data-tab="threats"'){throw 'Threat Control nav missing from Privacy GUI'}
  if($h.Content -notmatch 'http://127\.0\.0\.1:8766'){throw 'Threat Control backend not embedded'}
  $b=Invoke-RestMethod -Uri ($BridgeUrl+'/api/status') -TimeoutSec 12
  if(-not $b.routerSsh){throw 'bridge router SSH unhealthy'}
  if(@($b.items).Count -lt 1){throw 'bridge returned no threat evidence'}
  $t=Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop;if($t.State -eq 'Disabled'){throw 'Privacy GUI scheduled task disabled'}
  Write-Host ('SEC_PRIVACY_MERGE_TEST=PASS;ONE_UI='+$UiUrl+';THREATS='+@($b.items).Count+';BRIDGE_BACKEND=HEALTHY')
}
function Rollback{
  $s=Load-State
  if(-not $s.backup -or -not(Test-Path (Join-Path ([string]$s.backup) '3en-security-privacy-web.py'))){throw 'merge backup unavailable'}
  Copy-Item (Join-Path ([string]$s.backup) '3en-security-privacy-web.py') $Ui -Force
  Restart-Ui
  Write-Host 'SEC_PRIVACY_MERGE_ROLLBACK=PASS'
}
switch($Phase){'Apply'{Apply};'Test'{Test};'Rollback'{Rollback}}
