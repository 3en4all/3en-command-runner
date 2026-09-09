param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Backup','Execute','Test','Rollback')]
    [string]$Phase
)
$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent\workbench\admin-057v'
$Config=Join-Path $Root 'service-config.json'
$Original=Join-Path $Root 'service-config.original.json'
$Payload=Join-Path $Root 'payload.json'
$Manifest=Join-Path $Root 'job-manifest.json'
$Trigger=Join-Path $Root 'openclaw-trigger.txt'
$AgentRaw=Join-Path $Root 'openclaw-trigger-raw.txt'
$Health=Join-Path $Root 'health-test.ps1'
$Hashes=Join-Path $Root 'immutable-hashes.json'
$Verification=Join-Path $Root 'independent-verification.json'
$JobId='057V_STAGED_WRITE_V1'
$TriggerText='EXECUTE_JOB=057V_STAGED_WRITE_V1'

function Get-Sha([string]$Path){(Get-FileHash $Path -Algorithm SHA256).Hash}

switch($Phase){
'Backup'{
    if(Test-Path $Root){Remove-Item $Root -Recurse -Force}
    New-Item -ItemType Directory -Force -Path $Root|Out-Null

    ([ordered]@{service='3EN-DemoCollector';listenPort=8088;expectedPort=8099;enabled=$true;drill='v456-staged-executor'}|ConvertTo-Json) | Set-Content $Config -Encoding UTF8
    Copy-Item $Config $Original -Force
    ([ordered]@{service='3EN-DemoCollector';listenPort=8099;expectedPort=8099;enabled=$true;drill='v456-staged-executor'}|ConvertTo-Json) | Set-Content $Payload -Encoding UTF8

    @(
        '$ErrorActionPreference=''Stop''',
        '$c=Get-Content (Join-Path $PSScriptRoot ''service-config.json'') -Raw|ConvertFrom-Json',
        'if(-not [bool]$c.enabled){Write-Output ''HEALTH=FAIL disabled'';exit 43}',
        'if([int]$c.listenPort -ne [int]$c.expectedPort){Write-Output (''HEALTH=FAIL listenPort=''+$c.listenPort+'' expectedPort=''+$c.expectedPort);exit 42}',
        'Write-Output (''HEALTH=PASS port=''+$c.listenPort);exit 0'
    ) | Set-Content $Health -Encoding UTF8

    [ordered]@{
        schemaVersion=1
        jobId=$JobId
        operation='staged-replace'
        target=$Config
        payload=$Payload
        expectedPayloadSha256=(Get-Sha $Payload)
        requiredTrigger=$TriggerText
        allowedRoot=$Root
    } | ConvertTo-Json | Set-Content $Manifest -Encoding UTF8

    [ordered]@{
        original=(Get-Sha $Original)
        payload=(Get-Sha $Payload)
        manifest=(Get-Sha $Manifest)
        health=(Get-Sha $Health)
    } | ConvertTo-Json | Set-Content $Hashes -Encoding UTF8

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Health
    $ec=$LASTEXITCODE
    if($ec -ne 42){throw ('057V_BASELINE_EXPECTED_42_ACTUAL_'+$ec)}
    Write-Output ('V456_057V_BACKUP=PASS;BASELINE_HEALTH=42;PAYLOAD_SHA256='+(Get-Sha $Payload))
}
'Execute'{
    foreach($p in @($Config,$Original,$Payload,$Manifest,$Health,$Hashes)){if(-not(Test-Path $p)){throw ('057V_PRECONDITION_MISSING_'+$p)}}
    Remove-Item $Trigger,$AgentRaw -Force -ErrorAction SilentlyContinue
    $h=Get-Content $Hashes -Raw|ConvertFrom-Json
    if((Get-Sha $Original) -ne [string]$h.original){throw '057V_ORIGINAL_HASH_CHANGED'}
    if((Get-Sha $Payload) -ne [string]$h.payload){throw '057V_PAYLOAD_HASH_CHANGED'}
    if((Get-Sha $Manifest) -ne [string]$h.manifest){throw '057V_MANIFEST_HASH_CHANGED'}
    if((Get-Sha $Health) -ne [string]$h.health){throw '057V_HEALTH_HASH_CHANGED'}

    $rawAll=@()
    $triggerOk=$false
    for($attempt=1;$attempt -le 3;$attempt++){
        Remove-Item $Trigger -Force -ErrorAction SilentlyContinue
        $session='3en-057v-trigger-'+$attempt+'-'+[guid]::NewGuid().ToString('N')
        $prompt='Use the write tool to create exactly C:/3EN-Agent/workbench/admin-057v/openclaw-trigger.txt containing exactly one line: EXECUTE_JOB=057V_STAGED_WRITE_V1 . You must actually invoke the write tool. After success reply exactly TRIGGER_057V_DONE.'
        $raw=@(& openclaw.cmd agent --session-key $session --message $prompt --json --timeout 180 2>&1)
        $ec=$LASTEXITCODE
        $rawAll += ('=== ATTEMPT '+$attempt+' EXIT '+$ec+' SESSION '+$session+' ===')
        $rawAll += ($raw|ForEach-Object{[string]$_})
        if($ec -eq 0 -and (Test-Path $Trigger)){
            $actual=(Get-Content $Trigger -Raw).Trim()
            if($actual -eq $TriggerText){$triggerOk=$true;Write-Output ('V456_057V_TRIGGER=PASS;ATTEMPT='+$attempt);break}
            Write-Output ('V456_057V_TRIGGER=BAD_CONTENT;ATTEMPT='+$attempt+';ACTUAL='+$actual)
        }else{
            Write-Output ('V456_057V_TRIGGER=FAIL;ATTEMPT='+$attempt+';EXIT='+$ec)
        }
    }
    $rawAll | Set-Content $AgentRaw -Encoding UTF8
    if(-not $triggerOk){throw '057V_OPENCLAW_TRIGGER_NOT_VERIFIED'}

    # Deterministic executor applies only a pre-staged, hash-verified payload after the OpenClaw trigger is proven on disk.
    $m=Get-Content $Manifest -Raw|ConvertFrom-Json
    if([string]$m.jobId -ne $JobId -or [string]$m.operation -ne 'staged-replace'){throw '057V_MANIFEST_BAD'}
    if([string]$m.target -ne $Config -or [string]$m.payload -ne $Payload){throw '057V_PATH_CONTRACT_BAD'}
    if(-not ([string]$m.target).StartsWith($Root,[System.StringComparison]::OrdinalIgnoreCase)){throw '057V_TARGET_OUTSIDE_ALLOWED_ROOT'}
    if((Get-Sha $Payload) -ne [string]$m.expectedPayloadSha256){throw '057V_PAYLOAD_SHA_MISMATCH'}
    if((Get-Content $Trigger -Raw).Trim() -ne [string]$m.requiredTrigger){throw '057V_TRIGGER_CONTRACT_MISMATCH'}

    $tmp=$Config+'.057v.tmp'
    Copy-Item $Payload $tmp -Force
    if((Get-Sha $tmp) -ne [string]$m.expectedPayloadSha256){Remove-Item $tmp -Force;throw '057V_TEMP_SHA_MISMATCH'}
    Move-Item $tmp $Config -Force
    if((Get-Sha $Config) -ne [string]$m.expectedPayloadSha256){throw '057V_TARGET_SHA_MISMATCH_AFTER_APPLY'}
    Write-Output 'V456_057V_APPLY=PASS;MODE=OPENCLAW_VERIFIED_TRIGGER_PLUS_DETERMINISTIC_STAGED_PAYLOAD'
}
'Test'{
    foreach($p in @($Config,$Original,$Payload,$Manifest,$Trigger,$AgentRaw,$Health,$Hashes)){if(-not(Test-Path $p)){throw ('057V_REQUIRED_MISSING_'+$p)}}
    $h=Get-Content $Hashes -Raw|ConvertFrom-Json
    if((Get-Sha $Original) -ne [string]$h.original){throw '057V_BACKUP_MODIFIED'}
    if((Get-Sha $Payload) -ne [string]$h.payload){throw '057V_PAYLOAD_MODIFIED'}
    if((Get-Sha $Manifest) -ne [string]$h.manifest){throw '057V_MANIFEST_MODIFIED'}
    if((Get-Sha $Health) -ne [string]$h.health){throw '057V_VERIFIER_MODIFIED'}
    if((Get-Content $Trigger -Raw).Trim() -ne $TriggerText){throw '057V_TRIGGER_INVALID'}
    if((Get-Sha $Config) -ne [string]$h.payload){throw '057V_FINAL_HASH_NOT_PAYLOAD'}

    $old=Get-Content $Original -Raw|ConvertFrom-Json
    $new=Get-Content $Config -Raw|ConvertFrom-Json
    if([int]$old.listenPort -ne 8088 -or [int]$old.expectedPort -ne 8099){throw '057V_BACKUP_CONTENT_BAD'}
    if([int]$new.listenPort -ne 8099 -or [int]$new.expectedPort -ne 8099 -or -not [bool]$new.enabled){throw '057V_FINAL_CONTENT_BAD'}

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Health
    $ec=$LASTEXITCODE
    if($ec -ne 0){throw ('057V_HEALTH_EXIT_'+$ec)}

    [ordered]@{
        schemaVersion=1
        status='PASS'
        architecture='ASSISTANT_STAGES_PAYLOAD_OPENCLAW_TRIGGERS_DETERMINISTIC_EXECUTOR_VERIFIER_DECIDES'
        modelDiagnosisUsed=$false
        modelPayloadTransportUsed=$false
        openClawPhysicalTriggerWriteVerified=$true
        stagedPayloadHashVerified=$true
        targetHashVerified=$true
        backupVerified=$true
        independentHealthVerified=$true
        finalHealthExit=$ec
        verifiedAt=(Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content $Verification -Encoding UTF8
    Write-Output 'V456_057V_TEST=PASS;OPENCLAW_TRIGGER=PASS;PAYLOAD_HASH=PASS;TARGET_HASH=PASS;BACKUP=PASS;HEALTH=PASS;MODEL_DIAGNOSIS=false;MODEL_PAYLOAD_TRANSPORT=false'
}
'Rollback'{
    if(Test-Path $Original){
        Copy-Item $Original $Config -Force
        if((Get-Sha $Config) -eq (Get-Sha $Original)){Write-Output 'V456_057V_ROLLBACK=PASS'}else{Write-Output 'V456_057V_ROLLBACK=FAIL';exit 51}
    }else{Write-Output 'V456_057V_ROLLBACK=NO_ORIGINAL';exit 52}
}
}
