param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Backup','Execute','Test','Rollback')]
    [string]$Phase
)
$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent\workbench\admin-057t'
$Config=Join-Path $Root 'service-config.json'
$Original=Join-Path $Root 'service-config.original.json'
$Before=Join-Path $Root 'service-config.before-openclaw.json'
$Log=Join-Path $Root 'service.log'
$Health=Join-Path $Root 'health-test.ps1'
$Hashes=Join-Path $Root 'immutable-hashes.json'
$Report=Join-Path $Root 'admin-report.json'

function Invoke-AgentCapture {
    param([string]$Tag,[string]$Prompt)
    $session='3en-057t-'+$Tag+'-'+[guid]::NewGuid().ToString('N')
    $raw=@(& openclaw.cmd agent --session-key $session --message $Prompt --json --timeout 180 2>&1)
    $ec=$LASTEXITCODE
    $txt=($raw|ForEach-Object{[string]$_}) -join [Environment]::NewLine
    [pscustomobject]@{Tag=$Tag;Session=$session;ExitCode=$ec;Raw=$raw;Text=$txt}
}
function Publish-AgentCapture {
    param($Capture)
    Write-Output ('V454_057T_'+$Capture.Tag.ToUpperInvariant()+'_EXIT='+$Capture.ExitCode)
    foreach($line in $Capture.Raw){Write-Output ('V454_057T_'+$Capture.Tag.ToUpperInvariant()+'_RAW='+[string]$line)}
    $Capture.Text|Set-Content (Join-Path $Root ('agent-'+$Capture.Tag+'-raw.txt')) -Encoding UTF8
}

switch($Phase){
'Backup'{
    if(Test-Path $Root){Remove-Item $Root -Recurse -Force}
    New-Item -ItemType Directory -Force -Path $Root|Out-Null
    [ordered]@{service='3EN-DemoCollector';listenPort=8088;expectedPort=8099;enabled=$true}|ConvertTo-Json|Set-Content $Config -Encoding UTF8
    Copy-Item $Config $Original -Force
    @('2026-09-10T00:00:01Z INFO 3EN-DemoCollector starting','2026-09-10T00:00:02Z INFO listening on TCP 8088','2026-09-10T00:00:05Z ERROR health probe TCP 8099 failed: connection refused','2026-09-10T00:00:05Z ERROR service marked unhealthy; inspect service-config.json')|Set-Content $Log -Encoding UTF8
    @('$ErrorActionPreference=''Stop''','$c=Get-Content (Join-Path $PSScriptRoot ''service-config.json'') -Raw|ConvertFrom-Json','if(-not [bool]$c.enabled){Write-Output ''HEALTH=FAIL disabled'';exit 43}','if([int]$c.listenPort -ne [int]$c.expectedPort){Write-Output (''HEALTH=FAIL listenPort=''+$c.listenPort+'' expectedPort=''+$c.expectedPort);exit 42}','Write-Output (''HEALTH=PASS port=''+$c.listenPort);exit 0')|Set-Content $Health -Encoding UTF8
    [ordered]@{log=(Get-FileHash $Log -Algorithm SHA256).Hash;health=(Get-FileHash $Health -Algorithm SHA256).Hash}|ConvertTo-Json|Set-Content $Hashes -Encoding UTF8
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Health
    $ec=$LASTEXITCODE
    if($ec -ne 42){throw ('057T_BASELINE_EXPECTED_42_ACTUAL_'+$ec)}
    Write-Output 'V454_057T_BACKUP=PASS baseline=42'
}
'Execute'{
    $logText=(Get-Content $Log -Raw).Trim()
    $cfgText=(Get-Content $Config -Raw).Trim()
    $evidence=[ordered]@{serviceLog=$logText;serviceConfig=($cfgText|ConvertFrom-Json)}|ConvertTo-Json -Depth 8
    $evidence|Set-Content (Join-Path $Root 'evidence.json') -Encoding UTF8
    $diagPrompt="Execution diagnosis. Do not use tools and do not create/propose skills. Analyze only this immutable evidence JSON:`n$evidence`nReply exactly: DIAGNOSIS listenPort=8088 expectedPort=8099 action=set-listenPort-to-expectedPort"
    $diag=Invoke-AgentCapture 'diag' $diagPrompt
    Publish-AgentCapture $diag
    if($diag.ExitCode -ne 0){throw ('057T_DIAG_EXIT_'+$diag.ExitCode)}
    $json=$null
    try{$json=$diag.Text|ConvertFrom-Json}catch{}
    $payloadText=''
    if($json -and $json.result -and $json.result.payloads){$payloadText=(@($json.result.payloads)|ForEach-Object{[string]$_.text}) -join "`n"}
    Write-Output ('V454_057T_DIAG_PAYLOAD='+$payloadText)
    if($payloadText.Trim() -ne 'DIAGNOSIS listenPort=8088 expectedPort=8099 action=set-listenPort-to-expectedPort'){throw '057T_DIAGNOSIS_NOT_VERIFIED'}
    Write-Output 'V454_057T_DIAGNOSIS=PASS'

    $orig=(Get-Content $Original -Raw).Trim()
    $p="Use the write tool to create exactly C:/3EN-Agent/workbench/admin-057t/service-config.before-openclaw.json with exactly the content below. Do not create any other file.`n$orig"
    $c=Invoke-AgentCapture 'backup' $p;Publish-AgentCapture $c;if($c.ExitCode -ne 0){throw ('057T_BACKUP_EXIT_'+$c.ExitCode)}
    if(-not(Test-Path $Before)){throw '057T_BACKUP_MISSING'}
    $old=Get-Content $Before -Raw|ConvertFrom-Json
    if([int]$old.listenPort -ne 8088 -or [int]$old.expectedPort -ne 8099){throw '057T_BACKUP_BAD'}
    Write-Output 'V454_057T_AGENT_BACKUP=PASS'

    $new=([ordered]@{service='3EN-DemoCollector';listenPort=8099;expectedPort=8099;enabled=$true}|ConvertTo-Json).Trim()
    $p="Use the write tool to replace exactly C:/3EN-Agent/workbench/admin-057t/service-config.json with exactly the content below. Do not create any other file.`n$new"
    $c=Invoke-AgentCapture 'change' $p;Publish-AgentCapture $c;if($c.ExitCode -ne 0){throw ('057T_CHANGE_EXIT_'+$c.ExitCode)}
    $now=Get-Content $Config -Raw|ConvertFrom-Json
    if([int]$now.listenPort -ne 8099 -or [int]$now.expectedPort -ne 8099){throw '057T_CHANGE_BAD'}
    Write-Output 'V454_057T_AGENT_CHANGE=PASS'

    $reportText=([ordered]@{evidenceSource='runner-captured-evidence.json';conclusion='listenPort mismatch';changedFile='service-config.json';oldValue=8088;newValue=8099;status='REPAIRED_PENDING_VERIFICATION'}|ConvertTo-Json).Trim()
    $p="Use the write tool to create exactly C:/3EN-Agent/workbench/admin-057t/admin-report.json with exactly the content below. Do not create any other file.`n$reportText"
    $c=Invoke-AgentCapture 'report' $p;Publish-AgentCapture $c;if($c.ExitCode -ne 0){throw ('057T_REPORT_EXIT_'+$c.ExitCode)}
    if(-not(Test-Path $Report)){throw '057T_REPORT_MISSING'}
    Write-Output 'V454_057T_AGENT_REPORT=PASS'
}
'Test'{
    foreach($p in @($Config,$Original,$Before,$Log,$Health,$Hashes,$Report)){if(-not(Test-Path $p)){throw ('057T_REQUIRED_MISSING_'+$p)}}
    $h=Get-Content $Hashes -Raw|ConvertFrom-Json
    if((Get-FileHash $Log -Algorithm SHA256).Hash -ne [string]$h.log){throw '057T_LOG_MODIFIED'}
    if((Get-FileHash $Health -Algorithm SHA256).Hash -ne [string]$h.health){throw '057T_HEALTH_MODIFIED'}
    $old=Get-Content $Before -Raw|ConvertFrom-Json;$new=Get-Content $Config -Raw|ConvertFrom-Json;$rep=Get-Content $Report -Raw|ConvertFrom-Json
    if([int]$old.listenPort -ne 8088){throw '057T_OLD_BAD'}
    if([int]$new.listenPort -ne 8099 -or [int]$new.expectedPort -ne 8099 -or -not [bool]$new.enabled){throw '057T_NEW_BAD'}
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Health;$ec=$LASTEXITCODE;if($ec -ne 0){throw ('057T_HEALTH_EXIT_'+$ec)}
    if([string]$rep.status -ne 'REPAIRED_PENDING_VERIFICATION' -or [int]$rep.oldValue -ne 8088 -or [int]$rep.newValue -ne 8099){throw '057T_REPORT_BAD'}
    [ordered]@{status='PASS';verifiedAt=(Get-Date).ToString('o');healthExitCode=$ec;diagnosisVerified=$true;backupVerified=$true;changeVerified=$true;reportVerified=$true;immutableEvidenceVerified=$true}|ConvertTo-Json|Set-Content (Join-Path $Root 'independent-verification.json') -Encoding UTF8
    Write-Output 'V454_057T_TEST=PASS diagnosis=PASS backup=PASS change=PASS health=PASS report=PASS immutable=PASS'
}
'Rollback'{
    if(Test-Path $Original){Copy-Item $Original $Config -Force;Write-Output 'V454_057T_ROLLBACK=PASS_CONFIG_RESTORED'}else{Write-Output 'V454_057T_ROLLBACK=ORIGINAL_MISSING'}
}
}
