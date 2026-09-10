$ErrorActionPreference='Continue'
Write-Host '=== NP_BRIDGE_LOCAL_EVIDENCE_START ==='
Write-Host ('TIME='+[DateTimeOffset]::Now.ToString('o'))
$port=8766
try{
  $ls=Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop
  Write-Host ('LISTEN_COUNT='+@($ls).Count)
  foreach($x in @($ls)){
    Write-Host ('LISTEN_PID='+$x.OwningProcess+';ADDR='+$x.LocalAddress)
    try{$p=Get-CimInstance Win32_Process -Filter ('ProcessId='+$x.OwningProcess);Write-Host ('PROCESS='+$p.Name+';CMD='+$p.CommandLine)}catch{Write-Host ('PROCESS_LOOKUP_FAIL='+$_.Exception.Message)}
  }
}catch{Write-Host ('LISTEN_COUNT=0;ERROR='+$_.Exception.Message)}
try{
  $client=[System.Net.Http.HttpClient]::new();$client.Timeout=[TimeSpan]::FromSeconds(3)
  $sw=[Diagnostics.Stopwatch]::StartNew();$resp=$client.GetAsync('http://127.0.0.1:8766/api/status').GetAwaiter().GetResult();$body=$resp.Content.ReadAsStringAsync().GetAwaiter().GetResult();$sw.Stop()
  Write-Host ('HTTP_STATUS='+[int]$resp.StatusCode+';MS='+$sw.ElapsedMilliseconds+';BODY='+($body -replace '[\r\n]+',' '))
}catch{Write-Host ('HTTP_FAIL='+$_.Exception.GetType().FullName+';ERROR='+$_.Exception.Message)}finally{if($client){$client.Dispose()}}
try{
  Get-ScheduledTask -ErrorAction SilentlyContinue|Where-Object{$_.TaskName -match '3EN|Security|Threat|Privacy'}|ForEach-Object{
    $info=$_|Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
    Write-Host ('TASK='+$_.TaskName+';STATE='+$_.State+';LASTRESULT='+$info.LastTaskResult+';LASTRUN='+$info.LastRunTime)
    foreach($a in $_.Actions){Write-Host ('TASK_ACTION='+$_.TaskName+';EXEC='+$a.Execute+';ARGS='+$a.Arguments)}
  }
}catch{Write-Host ('TASK_ENUM_FAIL='+$_.Exception.Message)}
try{
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine -and ($_.CommandLine -match '8766|security.monitor|threat|bridge')}|ForEach-Object{Write-Host ('MATCH_PROCESS_PID='+$_.ProcessId+';NAME='+$_.Name+';CMD='+$_.CommandLine)}
}catch{}
$roots=@('C:\3EN-Agent\security-privacy-stack','C:\3EN-Agent')
$seen=@{}
foreach($r in $roots){if(Test-Path $r){Get-ChildItem $r -File -ErrorAction SilentlyContinue|Where-Object{$_.Extension -in '.py','.ps1','.json','.txt','.log'}|ForEach-Object{if(-not$seen.ContainsKey($_.FullName)){$seen[$_.FullName]=$true;try{$m=Select-String -LiteralPath $_.FullName -Pattern '8766','api/status','routerSsh' -SimpleMatch -ErrorAction Stop|Select-Object -First 8;if($m){Write-Host ('SOURCE='+$_.FullName);foreach($h in $m){Write-Host ($h.LineNumber.ToString()+': '+$h.Line)}}}catch{}}}}}
Write-Host '=== NP_BRIDGE_LOCAL_EVIDENCE_END ==='
