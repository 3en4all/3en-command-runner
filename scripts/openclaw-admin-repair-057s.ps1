param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Backup','Execute','Test','Rollback')]
    [string]$Phase
)

$ErrorActionPreference = 'Stop'
$Root = 'C:\3EN-Agent\workbench\admin-057s'
$Config = Join-Path $Root 'service-config.json'
$Original = Join-Path $Root 'service-config.original.json'
$Before = Join-Path $Root 'service-config.before-openclaw.json'
$Log = Join-Path $Root 'service.log'
$HealthTest = Join-Path $Root 'health-test.ps1'
$Hashes = Join-Path $Root 'immutable-hashes.json'
$Report = Join-Path $Root 'admin-report.json'

function Invoke-OpenClaw {
    param(
        [Parameter(Mandatory=$true)][string]$Tag,
        [Parameter(Mandatory=$true)][string]$Prompt
    )

    $session = '3en-057s-' + $Tag + '-' + [guid]::NewGuid().ToString('N')
    $raw = @(& openclaw.cmd agent --session-key $session --message $Prompt --json --timeout 180 2>&1)
    $exitCode = $LASTEXITCODE
    foreach ($line in $raw) {
        Write-Output ('V453_057S_' + $Tag.ToUpperInvariant() + '_RAW=' + [string]$line)
    }
    $text = ($raw | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    $text | Set-Content (Join-Path $Root ('agent-' + $Tag + '-raw.txt')) -Encoding UTF8
    Write-Output ('V453_057S_' + $Tag.ToUpperInvariant() + '_EXIT=' + $exitCode)
    if ($exitCode -ne 0) {
        throw ('057S_' + $Tag.ToUpperInvariant() + '_EXIT_' + $exitCode)
    }
    return $text
}

switch ($Phase) {
    'Backup' {
        if (Test-Path $Root) { Remove-Item $Root -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $Root | Out-Null

        [ordered]@{
            service = '3EN-DemoCollector'
            listenPort = 8088
            expectedPort = 8099
            enabled = $true
        } | ConvertTo-Json | Set-Content $Config -Encoding UTF8
        Copy-Item $Config $Original -Force

        @(
            '2026-09-10T00:00:01Z INFO 3EN-DemoCollector starting',
            '2026-09-10T00:00:02Z INFO listening on TCP 8088',
            '2026-09-10T00:00:05Z ERROR health probe TCP 8099 failed: connection refused',
            '2026-09-10T00:00:05Z ERROR service marked unhealthy; inspect service-config.json'
        ) | Set-Content $Log -Encoding UTF8

        @(
            '$ErrorActionPreference=''Stop''',
            '$c=Get-Content (Join-Path $PSScriptRoot ''service-config.json'') -Raw|ConvertFrom-Json',
            'if(-not [bool]$c.enabled){Write-Output ''HEALTH=FAIL disabled'';exit 43}',
            'if([int]$c.listenPort -ne [int]$c.expectedPort){Write-Output (''HEALTH=FAIL listenPort=''+$c.listenPort+'' expectedPort=''+$c.expectedPort);exit 42}',
            'Write-Output (''HEALTH=PASS port=''+$c.listenPort);exit 0'
        ) | Set-Content $HealthTest -Encoding UTF8

        [ordered]@{
            log = (Get-FileHash $Log -Algorithm SHA256).Hash
            test = (Get-FileHash $HealthTest -Algorithm SHA256).Hash
        } | ConvertTo-Json | Set-Content $Hashes -Encoding UTF8

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $HealthTest
        $baseline = $LASTEXITCODE
        if ($baseline -ne 42) { throw ('057S_BASELINE_EXPECTED_42_ACTUAL_' + $baseline) }
        Write-Output ('V453_057S_BACKUP=PASS baselineExit=' + $baseline)
    }

    'Execute' {
        foreach ($required in @($Config,$Original,$Log,$HealthTest,$Hashes)) {
            if (-not (Test-Path $required)) { throw ('057S_REQUIRED_MISSING_' + $required) }
        }

        $readPrompt = @'
Read exactly these two files using the existing read/file-reading tool:
C:/3EN-Agent/workbench/admin-057s/service.log
C:/3EN-Agent/workbench/admin-057s/service-config.json
Do not modify anything. Do not create or propose skills.
After reading them, reply exactly:
DIAGNOSIS listenPort=8088 expectedPort=8099
'@
        $readText = Invoke-OpenClaw -Tag 'read' -Prompt $readPrompt
        if ($readText -notmatch 'DIAGNOSIS\s+listenPort=8088\s+expectedPort=8099') {
            throw '057S_DIAGNOSIS_NOT_VERIFIED'
        }
        Write-Output 'V453_057S_DIAGNOSIS=PASS'

        $originalText = (Get-Content $Original -Raw).Trim()
        $backupPrompt = "Use the write tool to create exactly C:/3EN-Agent/workbench/admin-057s/service-config.before-openclaw.json with exactly the JSON content below. Do not write any other file.`n$originalText"
        [void](Invoke-OpenClaw -Tag 'backup' -Prompt $backupPrompt)
        if (-not (Test-Path $Before)) { throw '057S_OPENCLAW_BACKUP_MISSING' }
        $old = Get-Content $Before -Raw | ConvertFrom-Json
        if ([string]$old.service -ne '3EN-DemoCollector' -or [int]$old.listenPort -ne 8088 -or [int]$old.expectedPort -ne 8099 -or -not [bool]$old.enabled) {
            throw '057S_OPENCLAW_BACKUP_INVALID'
        }
        Write-Output 'V453_057S_AGENT_BACKUP=PASS'

        $newText = ([ordered]@{
            service = '3EN-DemoCollector'
            listenPort = 8099
            expectedPort = 8099
            enabled = $true
        } | ConvertTo-Json).Trim()
        $changePrompt = "Use the write tool to replace exactly C:/3EN-Agent/workbench/admin-057s/service-config.json with exactly the JSON content below. Do not write any other file.`n$newText"
        [void](Invoke-OpenClaw -Tag 'change' -Prompt $changePrompt)
        $new = Get-Content $Config -Raw | ConvertFrom-Json
        if ([string]$new.service -ne '3EN-DemoCollector' -or [int]$new.listenPort -ne 8099 -or [int]$new.expectedPort -ne 8099 -or -not [bool]$new.enabled) {
            throw '057S_OPENCLAW_CHANGE_INVALID'
        }
        Write-Output 'V453_057S_AGENT_CHANGE=PASS'

        $reportText = ([ordered]@{
            evidence = @('service.log shows listener 8088','service-config expectedPort is 8099')
            conclusion = 'listenPort mismatch causes failed health probe'
            changedFile = 'service-config.json'
            oldValue = 8088
            newValue = 8099
            status = 'REPAIRED_PENDING_VERIFICATION'
        } | ConvertTo-Json -Depth 5).Trim()
        $reportPrompt = "Use the write tool to create exactly C:/3EN-Agent/workbench/admin-057s/admin-report.json with exactly the JSON content below. Do not write any other file.`n$reportText"
        [void](Invoke-OpenClaw -Tag 'report' -Prompt $reportPrompt)
        if (-not (Test-Path $Report)) { throw '057S_REPORT_MISSING' }
        Write-Output 'V453_057S_AGENT_REPORT=PASS'
    }

    'Test' {
        foreach ($required in @($Config,$Original,$Before,$Log,$HealthTest,$Hashes,$Report)) {
            if (-not (Test-Path $required)) { throw ('057S_TEST_REQUIRED_MISSING_' + $required) }
        }

        $old = Get-Content $Before -Raw | ConvertFrom-Json
        $new = Get-Content $Config -Raw | ConvertFrom-Json
        $reportObj = Get-Content $Report -Raw | ConvertFrom-Json
        $hashObj = Get-Content $Hashes -Raw | ConvertFrom-Json

        if ([int]$old.listenPort -ne 8088 -or [int]$old.expectedPort -ne 8099) { throw '057S_OLD_CONFIG_BAD' }
        if ([string]$new.service -ne '3EN-DemoCollector' -or [int]$new.listenPort -ne 8099 -or [int]$new.expectedPort -ne 8099 -or -not [bool]$new.enabled) { throw '057S_NEW_CONFIG_BAD' }
        if ((Get-FileHash $Log -Algorithm SHA256).Hash -ne [string]$hashObj.log) { throw '057S_LOG_MODIFIED' }
        if ((Get-FileHash $HealthTest -Algorithm SHA256).Hash -ne [string]$hashObj.test) { throw '057S_HEALTH_TEST_MODIFIED' }

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $HealthTest
        $healthExit = $LASTEXITCODE
        if ($healthExit -ne 0) { throw ('057S_HEALTH_EXIT_' + $healthExit) }

        if ([string]$reportObj.status -ne 'REPAIRED_PENDING_VERIFICATION') { throw '057S_REPORT_STATUS_BAD' }
        if ([int]$reportObj.oldValue -ne 8088 -or [int]$reportObj.newValue -ne 8099) { throw '057S_REPORT_VALUES_BAD' }

        [ordered]@{
            verifiedAt = (Get-Date).ToString('o')
            status = 'PASS'
            healthExitCode = $healthExit
            diagnosisVerified = $true
            backupVerified = $true
            changeVerified = $true
            immutableEvidence = $true
            reportVerified = $true
        } | ConvertTo-Json | Set-Content (Join-Path $Root 'independent-verification.json') -Encoding UTF8

        Write-Output 'V453_057S_TEST=PASS diagnosis=PASS backup=PASS change=PASS health=PASS report=PASS immutable=PASS'
    }

    'Rollback' {
        if (Test-Path $Original) {
            Copy-Item $Original $Config -Force
            Write-Output 'V453_057S_ROLLBACK=PASS_CONFIG_RESTORED'
        }
        else {
            Write-Output 'V453_057S_ROLLBACK=ORIGINAL_MISSING'
        }
    }
}
