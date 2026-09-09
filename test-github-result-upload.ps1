# 3EN Agent - isolated GitHub result upload diagnostic
# Run in Windows PowerShell / PowerShell 7. Does not modify the runner.

$ErrorActionPreference = 'Stop'
$Repo = '3en4all/3en-command-runner'
$Branch = 'main'

Write-Host '=== 3EN GITHUB RESULT UPLOAD TEST ===' -ForegroundColor Cyan

$token = [Environment]::GetEnvironmentVariable('THREEEN_GH_TOKEN','User')
if ([string]::IsNullOrWhiteSpace($token)) { $token = $env:THREEEN_GH_TOKEN }

if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Host 'TOKEN: MISSING' -ForegroundColor Red
    throw 'THREEEN_GH_TOKEN is not configured.'
}

Write-Host ('TOKEN: PRESENT ({0} chars)' -f $token.Length) -ForegroundColor Green

$headers = @{
    Authorization = "Bearer $token"
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent' = '3EN-Agent-upload-test'
}

Write-Host 'STEP 1/3: GET repository metadata...' -ForegroundColor Yellow
$repoUri = "https://api.github.com/repos/$Repo"
$repoInfo = Invoke-RestMethod -Method Get -Uri $repoUri -Headers $headers -TimeoutSec 15
Write-Host ("GET OK: {0} / default branch={1}" -f $repoInfo.full_name,$repoInfo.default_branch) -ForegroundColor Green

Write-Host 'STEP 2/3: Preparing tiny result payload...' -ForegroundColor Yellow
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$remotePath = "results/upload-test-$stamp.json"
$payload = [ordered]@{
    test = '3EN GitHub result upload'
    computer = $env:COMPUTERNAME
    user = $env:USERNAME
    timestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    status = 'OK'
} | ConvertTo-Json -Depth 5

$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
$body = @{
    message = "3EN upload test $stamp"
    content = $b64
    branch = $Branch
} | ConvertTo-Json -Depth 5

Write-Host ("STEP 3/3: PUT {0} ..." -f $remotePath) -ForegroundColor Yellow
$putUri = "https://api.github.com/repos/$Repo/contents/$remotePath"

$sw = [Diagnostics.Stopwatch]::StartNew()
try {
    $result = Invoke-RestMethod -Method Put -Uri $putUri -Headers $headers -Body $body -ContentType 'application/json' -TimeoutSec 20
    $sw.Stop()
    Write-Host ("PUT OK in {0:N1}s" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    Write-Host ("REMOTE PATH: {0}" -f $remotePath)
    Write-Host ("COMMIT SHA: {0}" -f $result.commit.sha)
    Write-Host 'UPLOAD TEST PASS' -ForegroundColor Green
}
catch {
    $sw.Stop()
    Write-Host ("PUT FAILED after {0:N1}s" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Red
    Write-Host ("ERROR TYPE: {0}" -f $_.Exception.GetType().FullName)
    Write-Host ("ERROR: {0}" -f $_.Exception.Message)
    if ($_.ErrorDetails.Message) {
        Write-Host 'GITHUB RESPONSE:' -ForegroundColor Yellow
        Write-Host $_.ErrorDetails.Message
    }
    throw
}
