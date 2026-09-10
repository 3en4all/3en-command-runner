param([Parameter(Mandatory=$true)][ValidateSet('Prepare','Verify')][string]$Phase)
$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent'
$Local=Join-Path $Root '3en-multiproject-supervisor-v1.3.4.ps1'
$Switch=Join-Path $Root 'switch-to-supervisor-v134-delayed.ps1'
$Evidence=Join-Path $Root 'workbench\supervisor-v134-migration.json'
$Source='https://raw.githubusercontent.com/3en4all/3en-command-runner/61ce795098b6905744db4abeeec22018e6172e73/automation/3en-multiproject-supervisor-v1.3.4.ps1'
if($Phase-eq'Prepare'){
  Invoke-WebRequest -UseBasicParsing -Uri $Source -OutFile $Local
  $tok=$null;$err=$null;[System.Management.Automation.Language.Parser]::ParseFile($Local,[ref]$tok,[ref]$err)|Out-Null
  if(@($err).Count-ne0){throw ('058C_V134_SYNTAX_ERRORS_'+@($err).Count)}
  @'
$ErrorActionPreference='SilentlyContinue'
$Root='C:\3EN-Agent'
$Old='3en-multiproject-supervisor-v1.3.3.ps1'
$New=Join-Path $Root '3en-multiproject-supervisor-v1.3.4.ps1'
$Evidence=Join-Path $Root 'workbench\supervisor-v134-migration.json'
Start-Sleep -Seconds 15
$oldProcs=@(Get-CimInstance Win32_Process | Where-Object { $_.Name -in @('powershell.exe','pwsh.exe') -and $_.CommandLine -and $_.CommandLine -match [regex]::Escape($Old) })
$oldPids=@($oldProcs|ForEach-Object{[int]$_.ProcessId})
foreach($p in $oldProcs|Sort-Object ProcessId -Descending){try{Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop}catch{}}
Start-Sleep -Seconds 3
$p=Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$New,'-Root',$Root,'-PollSeconds','15','-PublishSeconds','30','-RunnerTimeoutSeconds','180') -WorkingDirectory $Root -PassThru
Start-Sleep -Seconds 8
$new=@(Get-CimInstance Win32_Process | Where-Object { $_.Name -in @('powershell.exe','pwsh.exe') -and $_.CommandLine -and $_.CommandLine -match '3en-multiproject-supervisor-v1\.3\.4\.ps1' })
$status=if($new.Count-ge1){'PASS'}else{'FAIL'}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Evidence)|Out-Null
[ordered]@{schemaVersion=1;status=$status;oldPids=$oldPids;newCoordinatorPid=$p.Id;newProcessCount=$new.Count;switchedAt=(Get-Date).ToString('o')}|ConvertTo-Json -Depth 5|Set-Content $Evidence -Encoding UTF8
'@ | Set-Content $Switch -Encoding UTF8
  $tok2=$null;$err2=$null;[System.Management.Automation.Language.Parser]::ParseFile($Switch,[ref]$tok2,[ref]$err2)|Out-Null
  if(@($err2).Count-ne0){throw ('058C_SWITCH_SYNTAX_ERRORS_'+@($err2).Count)}
  Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$Switch) -WorkingDirectory $Root|Out-Null
  Write-Output 'V463_058C_PREPARE=PASS;V134_SYNTAX=PASS;DELAYED_SWITCH_SCHEDULED=true'
}
if($Phase-eq'Verify'){
  if(-not(Test-Path $Local)){throw '058C_V134_LOCAL_MISSING'}
  $tok=$null;$err=$null;[System.Management.Automation.Language.Parser]::ParseFile($Local,[ref]$tok,[ref]$err)|Out-Null
  if(@($err).Count-ne0){throw ('058C_VERIFY_SYNTAX_ERRORS_'+@($err).Count)}
  Write-Output 'V463_058C_TEST=PASS;V134_LOCAL=PASS;SWITCH_SCRIPT_SCHEDULED=true'
}
