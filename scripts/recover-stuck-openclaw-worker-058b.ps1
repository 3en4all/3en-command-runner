$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent'
$State=Join-Path $Root 'supervisor-state-v133\openclaw.json'
$Out=Join-Path $Root 'workbench\admin-recovery-058b.json'
if(-not(Test-Path $State)){throw '058B_OPENCLAW_STATE_MISSING'}
$s=Get-Content $State -Raw|ConvertFrom-Json
if([string]$s.lane-ne'openclaw'){throw '058B_WRONG_LANE_STATE'}
if([string]$s.status-ne'RUNNING'){Write-Output ('V462_058B_NO_RECOVERY_NEEDED;STATUS='+[string]$s.status);[ordered]@{status='NO_RECOVERY_NEEDED';oldWorkerPid=$s.workerPid;observedStatus=$s.status;at=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content $Out -Encoding UTF8;exit 0}
$updated=[datetime]::Parse([string]$s.updatedUtc).ToUniversalTime()
$age=((Get-Date).ToUniversalTime()-$updated).TotalSeconds
if($age-lt90){throw ('058B_STATE_NOT_STALE_AGE_'+[int]$age)}
$old=[int]$s.workerPid
if($old-le0){throw '058B_WORKER_PID_INVALID'}
$all=@(Get-CimInstance Win32_Process -ErrorAction Stop)
$map=@{};foreach($p in $all){$pp=[int]$p.ParentProcessId;if(-not$map.ContainsKey($pp)){$map[$pp]=@()};$map[$pp]+=$p}
$desc=New-Object System.Collections.Generic.List[object]
function Add-Desc([int]$pid){if($map.ContainsKey($pid)){foreach($c in @($map[$pid])){$desc.Add($c);Add-Desc ([int]$c.ProcessId)}}}
Add-Desc $old
$killed=@()
foreach($p in @($desc|Sort-Object ProcessId -Descending)){try{Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop;$killed+=[int]$p.ProcessId}catch{}}
try{Stop-Process -Id $old -Force -ErrorAction Stop;$killed+=$old}catch{throw ('058B_WORKER_KILL_FAILED_'+$old)}
Start-Sleep -Seconds 20
$new=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.Name -in @('powershell.exe','pwsh.exe') -and $_.CommandLine -and $_.CommandLine -match '3en-multiproject-supervisor-v1\.3\.3\.ps1' -and $_.CommandLine -match '-WorkerLane\s+openclaw'})
if($new.Count-lt1){throw '058B_OPENCLAW_WORKER_NOT_RESTARTED'}
$newPid=[int]$new[0].ProcessId
if($newPid-eq$old){throw '058B_WORKER_PID_NOT_CHANGED'}
[ordered]@{status='PASS';oldWorkerPid=$old;newWorkerPid=$newPid;killedPids=$killed;staleAgeSeconds=[int]$age;coordinatorRestartVerified=$true;at=(Get-Date).ToString('o')}|ConvertTo-Json -Depth 5|Set-Content $Out -Encoding UTF8
Write-Output ('V462_058B_RECOVERY=PASS;OLD_WORKER='+$old+';NEW_WORKER='+$newPid+';KILLED='+($killed -join ','))
