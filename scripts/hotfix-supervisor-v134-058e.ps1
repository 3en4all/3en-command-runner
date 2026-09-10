param([Parameter(Mandatory=$true)][ValidateSet('Patch','Test')][string]$Phase)
$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent'
$File=Join-Path $Root '3en-multiproject-supervisor-v1.3.4.ps1'
$Backup=Join-Path $Root 'backups\supervisor-v134-pre-hotfix-058e.ps1'
$Restart=Join-Path $Root 'restart-supervisor-v134-058e.ps1'
function Parse-Check([string]$p){$tok=$null;$err=$null;[System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$tok,[ref]$err)|Out-Null;if(@($err).Count-ne0){throw ('058E_SYNTAX_ERRORS_'+@($err).Count)}}
if($Phase-eq'Patch'){
  if(-not(Test-Path $File)){throw '058E_V134_LOCAL_MISSING'}
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Backup)|Out-Null
  Copy-Item $File $Backup -Force
  $s=Get-Content $File -Raw
  $oldKill='function Kill-Tree([int]$pid){if($pid -le 0){return};try{& taskkill.exe /PID $pid /T /F 2>&1|Out-Null}catch{}}'
  $newKill='function Kill-Tree([int]$processId){if($processId -le 0){return};try{& taskkill.exe /PID $processId /T /F 2>&1|Out-Null}catch{}}'
  if(-not$s.Contains($oldKill)){if(-not$s.Contains($newKill)){throw '058E_KILL_PATTERN_NOT_FOUND'}}else{$s=$s.Replace($oldKill,$newKill)}
  $oldPtr="$uri=$RepoApi+'/contents/inbox/lanes/'+$lane+'.json?ref=main';try{"
  $newPtr="$ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();$uri=$RepoApi+'/contents/inbox/lanes/'+$lane+'.json?ref=main&ts='+$ts;try{"
  if($s.Contains($oldPtr)){$s=$s.Replace($oldPtr,$newPtr)}
  $oldSync="$uri=$RepoApi+'/contents/'+$repoPath.Replace('\\','/')+'?ref=main';try{"
  $newSync="$ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();$uri=$RepoApi+'/contents/'+$repoPath.Replace('\\','/')+'?ref=main&ts='+$ts;try{"
  if($s.Contains($oldSync)){$s=$s.Replace($oldSync,$newSync)}
  Set-Content $File -Value $s -Encoding UTF8
  Parse-Check $File
  $verify=Get-Content $File -Raw
  if($verify -notmatch 'Kill-Tree\(\[int\]\$processId\)'){throw '058E_PROCESSID_PATCH_MISSING'}
  @'
$ErrorActionPreference='SilentlyContinue'
$Root='C:\3EN-Agent'
Start-Sleep -Seconds 15
$old=@(Get-CimInstance Win32_Process|Where-Object{$_.Name -in @('powershell.exe','pwsh.exe') -and $_.CommandLine -and $_.CommandLine -match '3en-multiproject-supervisor-v1\.3\.4\.ps1'})
foreach($p in $old|Sort-Object ProcessId -Descending){try{Stop-Process -Id ([int]$p.ProcessId) -Force}catch{}}
Start-Sleep -Seconds 3
Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',(Join-Path $Root '3en-multiproject-supervisor-v1.3.4.ps1'),'-Root',$Root,'-PollSeconds','15','-PublishSeconds','30','-RunnerTimeoutSeconds','180') -WorkingDirectory $Root|Out-Null
'@|Set-Content $Restart -Encoding UTF8
  Parse-Check $Restart
  Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$Restart) -WorkingDirectory $Root|Out-Null
  Write-Output 'V465_058E_PATCH=PASS;BACKUP=PASS;PROCESSID_FIX=PASS;RESTART_SCHEDULED=true'
}
if($Phase-eq'Test'){
  if(-not(Test-Path $File)){throw '058E_TEST_FILE_MISSING'};Parse-Check $File;$s=Get-Content $File -Raw
  if($s -notmatch 'Kill-Tree\(\[int\]\$processId\)'){throw '058E_TEST_PROCESSID_FIX_MISSING'}
  if($s -match 'Kill-Tree\(\[int\]\$pid\)'){throw '058E_TEST_READONLY_PID_REMAINS'}
  Write-Output 'V465_058E_TEST=PASS;SYNTAX=PASS;TIMEOUT_KILL_FIX=PASS'
}
