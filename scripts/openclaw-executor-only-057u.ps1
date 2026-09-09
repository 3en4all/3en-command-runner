param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Backup','Execute','Test','Rollback')]
    [string]$Phase
)
$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent\workbench\admin-057u'
$Config=Join-Path $Root 'service-config.json'
$Original=Join-Path $Root 'service-config.original.json'
$Log=Join-Path $Root 'service.log'
$Health=Join-Path $Root 'health-test.ps1'
$Hashes=Join-Path $Root 'immutable-hashes.json'
$AgentRaw=Join-Path $Root 'openclaw-write-raw.txt'
$Verification=Join-Path $Root 'independent-verification.json'

function Test-DesiredConfig {
    param([string]$Path)
    try {
        $c=Get-Content $Path -Raw | ConvertFrom-Json
        return ([string]$c.service -eq '3EN-DemoCollector' -and [int]$c.listenPort -eq 8099 -and [int]$c.expectedPort -eq 8099 -and [bool]$c.enabled -and [string]$c.drill -eq 'v455-executor-only')
    } catch { return $false }
}

function Invoke-OpenClawWrite {
    param([string]$ExactContent)
    $allRaw=@()
    for($attempt=1;$attempt -le 3;$attempt++){
        $session='3en-057u-write-'+$attempt+'-'+[guid]::NewGuid().ToString('N')
        if($attempt -eq 1){
            $prompt='EXECUTOR ONLY. Use the write tool exactly once. Replace the entire file C:/3EN-Agent/workbench/admin-057u/service-config.json with this exact single-line JSON and nothing else: '+$ExactContent
        } elseif($attempt -eq 2){
            $prompt='NO ANALYSIS. NO PLACEHOLDERS. WRITE TOOL ONLY. Target: C:/3EN-Agent/workbench/admin-057u/service-config.json. The COMPLETE literal file content is exactly: '+$ExactContent+' Do not write words such as CONTENT, BEGIN, END, ellipsis, markdown, or explanation.'
        } else {
            $prompt='Perform one filesystem write. Path C:/3EN-Agent/workbench/admin-057u/service-config.json. Exact bytes as UTF-8 text: '+$ExactContent
        }
        $raw=@(& openclaw.cmd agent --session-key $session --message $prompt --json --timeout 180 2>&1)
        $ec=$LASTEXITCODE
        $rawText=($raw|ForEach-Object{[string]$_}) -join [Environment]::NewLine
        $allRaw += ('=== ATTEMPT '+$attempt+' SESSION '+$session+' EXIT '+$ec+' ===')
        $allRaw += $rawText
        Write-Output ('V455_057U_OPENCLAW_ATTEMPT='+$attempt+';EXIT='+$ec+';SESSION='+$session)
        if($ec -eq 0 -and (Test-DesiredConfig -Path $Config)){
            $allRaw|Set-Content $AgentRaw -Encoding UTF8
            Write-Output ('V455_057U_OPENCLAW_WRITE_VERIFIED=PASS;ATTEMPT='+$attempt)
            return
        }
        Write-Output ('V455_057U_OPENCLAW_WRITE_VERIFIED=FAIL;ATTEMPT='+$attempt+';AUTO_REPAIR=RETRY_EXACT_WRITE')
    }
    $allRaw|Set-Content $AgentRaw -Encoding UTF8
    throw '057U_OPENCLAW_EXACT_WRITE_FAILED_AFTER_3_ATTEMPTS'
}

switch($Phase){
'Backup'{
    if(Test-Path $Root){Remove-Item $Root -Recurse -Force}
    New-Item -ItemType Directory -Force -Path $Root|Out-Null

    $baseline=([ordered]@{
        service='3EN-DemoCollector'
        listenPort=8088
        expectedPort=8099
        enabled=$true
        drill='v455-executor-only'
    }|ConvertTo-Json).Trim()
    $baseline|Set-Content $Config -Encoding UTF8
    Copy-Item $Config $Original -Force

    @(
        '2026-09-10T00:00:01Z INFO 3EN-DemoCollector starting',
        '2026-09-10T00:00:02Z INFO listening on TCP 8088',
        '2026-09-10T00:00:05Z ERROR health probe TCP 8099 failed: connection refused'
    )|Set-Content $Log -Encoding UTF8

    @(
        '$ErrorActionPreference=''Stop''',
        '$c=Get-Content (Join-Path $PSScriptRoot ''service-config.json'') -Raw|ConvertFrom-Json',
        'if(-not [bool]$c.enabled){Write-Output ''HEALTH=FAIL disabled'';exit 43}',
        'if([int]$c.listenPort -ne [int]$c.expectedPort){Write-Output (''HEALTH=FAIL listenPort=''+$c.listenPort+'' expectedPort=''+$c.expectedPort);exit 42}',
        'Write-Output (''HEALTH=PASS port=''+$c.listenPort);exit 0'
    )|Set-Content $Health -Encoding UTF8

    [ordered]@{
        original=(Get-FileHash $Original -Algorithm SHA256).Hash
        log=(Get-FileHash $Log -Algorithm SHA256).Hash
        health=(Get-FileHash $Health -Algorithm SHA256).Hash
    }|ConvertTo-Json|Set-Content $Hashes -Encoding UTF8

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Health
    $ec=$LASTEXITCODE
    if($ec -ne 42){throw ('057U_BASELINE_EXPECTED_42_ACTUAL_'+$ec)}
    Write-Output 'V455_057U_READ_EVIDENCE=PASS listenPort=8088 expectedPort=8099 healthExit=42'
    Write-Output 'V455_057U_BACKUP=PASS original=service-config.original.json'
}
'Execute'{
    foreach($p in @($Config,$Original,$Log,$Health,$Hashes)){if(-not(Test-Path $p)){throw ('057U_PRECONDITION_MISSING_'+$p)}}
    $before=Get-Content $Config -Raw|ConvertFrom-Json
    if([int]$before.listenPort -ne 8088 -or [int]$before.expectedPort -ne 8099){throw '057U_UNEXPECTED_BASELINE'}

    # Upstream assistant/job contract already made the decision.
    # OpenClaw receives only exact deterministic WRITE instructions.
    $desired='{"service":"3EN-DemoCollector","listenPort":8099,"expectedPort":8099,"enabled":true,"drill":"v455-executor-only"}'
    Invoke-OpenClawWrite -ExactContent $desired

    if(-not(Test-DesiredConfig -Path $Config){throw '057U_EXECUTOR_WRITE_NOT_OBSERVED'})
    Write-Output 'V455_057U_EXECUTOR_WRITE=PASS physicalFileStateObserved=true'
}
'Test'{
    foreach($p in @($Config,$Original,$Log,$Health,$Hashes,$AgentRaw)){if(-not(Test-Path $p)){throw ('057U_REQUIRED_MISSING_'+$p)}}
    $h=Get-Content $Hashes -Raw|ConvertFrom-Json
    if((Get-FileHash $Original -Algorithm SHA256).Hash -ne [string]$h.original){throw '057U_BACKUP_MODIFIED'}
    if((Get-FileHash $Log -Algorithm SHA256).Hash -ne [string]$h.log){throw '057U_LOG_MODIFIED'}
    if((Get-FileHash $Health -Algorithm SHA256).Hash -ne [string]$h.health){throw '057U_HEALTH_TEST_MODIFIED'}

    $old=Get-Content $Original -Raw|ConvertFrom-Json
    $new=Get-Content $Config -Raw|ConvertFrom-Json
    if([int]$old.listenPort -ne 8088 -or [int]$old.expectedPort -ne 8099){throw '057U_BACKUP_CONTENT_BAD'}
    if([int]$new.listenPort -ne 8099 -or [int]$new.expectedPort -ne 8099 -or -not [bool]$new.enabled){throw '057U_NEW_CONTENT_BAD'}

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Health
    $ec=$LASTEXITCODE
    if($ec -ne 0){throw ('057U_INDEPENDENT_HEALTH_EXIT_'+$ec)}

    [ordered]@{
        schemaVersion=1
        status='PASS'
        architecture='ASSISTANT_DECIDES_OPENCLAW_EXECUTES_VERIFIER_DECIDES_SUCCESS'
        modelDiagnosisUsed=$false
        backupVerified=$true
        executorWriteObserved=$true
        independentHealthVerified=$true
        immutableEvidenceVerified=$true
        baselineHealthExit=42
        finalHealthExit=$ec
        verifiedAt=(Get-Date).ToString('o')
    }|ConvertTo-Json|Set-Content $Verification -Encoding UTF8

    Write-Output 'V455_057U_TEST=PASS modelDiagnosisUsed=false backup=PASS executorWrite=PASS independentHealth=PASS immutableEvidence=PASS'
    Write-Output 'V455_057U_ARCHITECTURE=PASS ASSISTANT_DECIDES_OPENCLAW_EXECUTES_VERIFIER_DECIDES_SUCCESS'
}
'Rollback'{
    if(Test-Path $Original){
        Copy-Item $Original $Config -Force
        $restored=Get-Content $Config -Raw|ConvertFrom-Json
        if([int]$restored.listenPort -eq 8088 -and [int]$restored.expectedPort -eq 8099){
            Write-Output 'V455_057U_ROLLBACK=PASS baselineRestored=true'
        }else{
            Write-Output 'V455_057U_ROLLBACK=FAIL baselineRestored=false'
            exit 51
        }
    }else{
        Write-Output 'V455_057U_ROLLBACK=NO_ORIGINAL'
        exit 52
    }
}
}
