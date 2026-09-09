param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Backup','Execute','Test','Rollback')]
    [string]$Phase
)
$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent\workbench\admin-057w'
$Config=Join-Path $Root 'service-config.json'
$Original=Join-Path $Root 'service-config.original.json'
$Health=Join-Path $Root 'health-test.ps1'
$Hashes=Join-Path $Root 'immutable-hashes.json'
$ApiEvidence=Join-Path $Root 'tools-invoke-evidence.json'
$Verification=Join-Path $Root 'independent-verification.json'
$Desired='{"service":"3EN-DemoCollector","listenPort":8099,"expectedPort":8099,"enabled":true,"drill":"v457-direct-tool-api"}'

function Get-Sha([string]$Path){(Get-FileHash $Path -Algorithm SHA256).Hash}
function Get-GatewayContext {
    $cfgPath=Join-Path $env:USERPROFILE '.openclaw\openclaw.json'
    if(-not(Test-Path $cfgPath)){throw '057W_OPENCLAW_CONFIG_MISSING'}
    $cfg=Get-Content $cfgPath -Raw|ConvertFrom-Json
    $port=18789
    if($null -ne $cfg.gateway -and $null -ne $cfg.gateway.port -and [int]$cfg.gateway.port -gt 0){$port=[int]$cfg.gateway.port}
    $mode='token'
    if($null -ne $cfg.gateway -and $null -ne $cfg.gateway.auth -and -not [string]::IsNullOrWhiteSpace([string]$cfg.gateway.auth.mode)){$mode=[string]$cfg.gateway.auth.mode}
    $secret=''
    if($mode -eq 'token'){
        $secret=[string]$env:OPENCLAW_GATEWAY_TOKEN
        if([string]::IsNullOrWhiteSpace($secret) -and $null -ne $cfg.gateway.auth.token){$secret=[string]$cfg.gateway.auth.token}
    }elseif($mode -eq 'password'){
        $secret=[string]$env:OPENCLAW_GATEWAY_PASSWORD
        if([string]::IsNullOrWhiteSpace($secret) -and $null -ne $cfg.gateway.auth.password){$secret=[string]$cfg.gateway.auth.password}
    }elseif($mode -ne 'none'){
        throw ('057W_UNSUPPORTED_GATEWAY_AUTH_MODE_'+$mode)
    }
    if($mode -ne 'none' -and [string]::IsNullOrWhiteSpace($secret)){throw '057W_GATEWAY_SECRET_UNAVAILABLE'}
    return [pscustomobject]@{Port=$port;Mode=$mode;Secret=$secret}
}

switch($Phase){
'Backup'{
    if(Test-Path $Root){Remove-Item $Root -Recurse -Force}
    New-Item -ItemType Directory -Force -Path $Root|Out-Null
    ([ordered]@{service='3EN-DemoCollector';listenPort=8088;expectedPort=8099;enabled=$true;drill='v457-direct-tool-api'}|ConvertTo-Json) | Set-Content $Config -Encoding UTF8
    Copy-Item $Config $Original -Force
    @(
        '$ErrorActionPreference=''Stop''',
        '$c=Get-Content (Join-Path $PSScriptRoot ''service-config.json'') -Raw|ConvertFrom-Json',
        'if(-not [bool]$c.enabled){Write-Output ''HEALTH=FAIL disabled'';exit 43}',
        'if([int]$c.listenPort -ne [int]$c.expectedPort){Write-Output (''HEALTH=FAIL listenPort=''+$c.listenPort+'' expectedPort=''+$c.expectedPort);exit 42}',
        'Write-Output (''HEALTH=PASS port=''+$c.listenPort);exit 0'
    ) | Set-Content $Health -Encoding UTF8
    [ordered]@{original=(Get-Sha $Original);health=(Get-Sha $Health)}|ConvertTo-Json|Set-Content $Hashes -Encoding UTF8
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Health
    $ec=$LASTEXITCODE
    if($ec -ne 42){throw ('057W_BASELINE_EXPECTED_42_ACTUAL_'+$ec)}
    Write-Output 'V457_057W_BACKUP=PASS;BASELINE_HEALTH=42'
}
'Execute'{
    foreach($p in @($Config,$Original,$Health,$Hashes)){if(-not(Test-Path $p)){throw ('057W_PRECONDITION_MISSING_'+$p)}}
    $h=Get-Content $Hashes -Raw|ConvertFrom-Json
    if((Get-Sha $Original) -ne [string]$h.original){throw '057W_BACKUP_HASH_CHANGED'}
    if((Get-Sha $Health) -ne [string]$h.health){throw '057W_HEALTH_HASH_CHANGED'}
    $g=Get-GatewayContext
    $uri='http://127.0.0.1:'+$g.Port+'/tools/invoke'
    $headers=@{}
    if($g.Mode -ne 'none'){$headers.Authorization='Bearer '+$g.Secret}
    $target=$Config.Replace('\','/')
    $body=[ordered]@{tool='write';args=[ordered]@{path=$target;content=$Desired};sessionKey='main';idempotencyKey=('3en-057w-'+[guid]::NewGuid().ToString('N'))}|ConvertTo-Json -Depth 8
    try{
        $r=Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 30
    }catch{
        $status='UNKNOWN'
        try{$status=[int]$_.Exception.Response.StatusCode}catch{}
        [ordered]@{schemaVersion=1;status='HTTP_FAIL';httpStatus=$status;gatewayPort=$g.Port;authMode=$g.Mode;secretLogged=$false;modelUsed=$false;errorClass=$_.Exception.GetType().Name}|ConvertTo-Json|Set-Content $ApiEvidence -Encoding UTF8
        throw ('057W_TOOLS_INVOKE_HTTP_'+$status)
    }
    $ok=$false
    if($null -ne $r -and $null -ne $r.ok){$ok=[bool]$r.ok}
    [ordered]@{schemaVersion=1;status=if($ok){'PASS'}else{'API_REJECT'};gatewayPort=$g.Port;authMode=$g.Mode;secretLogged=$false;modelUsed=$false;tool='write';target=$target}|ConvertTo-Json|Set-Content $ApiEvidence -Encoding UTF8
    if(-not $ok){throw '057W_TOOLS_INVOKE_OK_FALSE'}
    if(-not(Test-Path $Config)){throw '057W_TARGET_MISSING_AFTER_DIRECT_WRITE'}
    if((Get-Content $Config -Raw).Trim() -ne $Desired){throw '057W_DIRECT_WRITE_CONTENT_MISMATCH'}
    Write-Output 'V457_057W_DIRECT_TOOL_WRITE=PASS;MODEL_USED=false;ENDPOINT=loopback;TOOL=write'
}
'Test'{
    foreach($p in @($Config,$Original,$Health,$Hashes,$ApiEvidence)){if(-not(Test-Path $p)){throw ('057W_REQUIRED_MISSING_'+$p)}}
    $h=Get-Content $Hashes -Raw|ConvertFrom-Json
    if((Get-Sha $Original) -ne [string]$h.original){throw '057W_BACKUP_MODIFIED'}
    if((Get-Sha $Health) -ne [string]$h.health){throw '057W_VERIFIER_MODIFIED'}
    $api=Get-Content $ApiEvidence -Raw|ConvertFrom-Json
    if([string]$api.status -ne 'PASS' -or [bool]$api.modelUsed){throw '057W_API_EVIDENCE_BAD'}
    if((Get-Content $Config -Raw).Trim() -ne $Desired){throw '057W_FINAL_BYTES_BAD'}
    $new=Get-Content $Config -Raw|ConvertFrom-Json
    if([int]$new.listenPort -ne 8099 -or [int]$new.expectedPort -ne 8099 -or -not [bool]$new.enabled){throw '057W_FINAL_CONTENT_BAD'}
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Health
    $ec=$LASTEXITCODE
    if($ec -ne 0){throw ('057W_HEALTH_EXIT_'+$ec)}
    [ordered]@{schemaVersion=1;status='PASS';architecture='ASSISTANT_TO_OPENCLAW_DIRECT_TOOL_API_TO_INDEPENDENT_VERIFIER';modelUsed=$false;gatewayLoopback=$true;directWriteVerified=$true;backupVerified=$true;independentHealthVerified=$true;finalHealthExit=$ec;verifiedAt=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content $Verification -Encoding UTF8
    Write-Output 'V457_057W_TEST=PASS;DIRECT_OPENCLAW_TOOL=PASS;MODEL_USED=false;BACKUP=PASS;HEALTH=PASS'
}
'Rollback'{
    if(Test-Path $Original){Copy-Item $Original $Config -Force;if((Get-Sha $Config) -eq (Get-Sha $Original)){Write-Output 'V457_057W_ROLLBACK=PASS'}else{Write-Output 'V457_057W_ROLLBACK=FAIL';exit 51}}else{Write-Output 'V457_057W_ROLLBACK=NO_ORIGINAL';exit 52}
}
}
