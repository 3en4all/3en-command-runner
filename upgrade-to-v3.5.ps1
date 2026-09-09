$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent'
$Source=Join-Path $Root '3en-agent-runner-v3.4.ps1'
$Target=Join-Path $Root '3en-agent-runner-v3.5.ps1'
$Backup=Join-Path $Root ('3en-agent-runner-v3.4.backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.ps1')
$ApiTaskUrl='https://api.github.com/repos/3en4all/3en-command-runner/contents/task.json?ref=main'

if(-not(Test-Path -LiteralPath $Source)){throw "Missing source runner: $Source"}
Copy-Item -LiteralPath $Source -Destination $Backup -Force
Write-Host "BACKUP=$Backup"

$raw=Get-Content -LiteralPath $Source -Raw -Encoding UTF8
$old=@'
function Fetch-Task([string]$Url) {
    $ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $u=if($Url.Contains('?')){"${Url}&ts=$ts"}else{"${Url}?ts=$ts"}
    Log 'Fetching task...'
    $r=Invoke-WebRequest -Uri $u -Headers @{'Cache-Control'='no-cache';Pragma='no-cache';'User-Agent'='3EN-Agent-v3.4'} -TimeoutSec 20
    Log "FETCH OK HTTP=$($r.StatusCode)"
    $t=[string]$r.Content | ConvertFrom-Json
    Log "PARSE OK ID=$($t.id)"
    foreach($req in @('id','title','description','script')){
        if(-not $t.PSObject.Properties.Name.Contains($req) -or [string]::IsNullOrWhiteSpace([string]$t.$req)){throw "Task JSON missing field: $req"}
    }
    return $t
}
'@
$new=@'
function Fetch-Task([string]$Url) {
    Log 'Fetching task...'
    $headers=@{
        Accept='application/vnd.github+json'
        'X-GitHub-Api-Version'='2022-11-28'
        'User-Agent'='3EN-Agent-v3.5'
        'Cache-Control'='no-cache'
    }
    $token=$env:THREEEN_GH_TOKEN
    if([string]::IsNullOrWhiteSpace($token)){$token=[Environment]::GetEnvironmentVariable('THREEEN_GH_TOKEN','User')}
    if(-not [string]::IsNullOrWhiteSpace($token)){$headers.Authorization="Bearer $token"}
    $r=Invoke-RestMethod -Method Get -Uri $Url -Headers $headers -TimeoutSec 20
    if(-not $r.content){throw 'GitHub Contents API response missing content field'}
    $b64=([string]$r.content -replace '\s','')
    $json=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
    Log 'FETCH OK API=GitHubContents'
    $t=$json | ConvertFrom-Json
    Log "PARSE OK ID=$($t.id)"
    foreach($req in @('id','title','description','script')){
        if(-not $t.PSObject.Properties.Name.Contains($req) -or [string]::IsNullOrWhiteSpace([string]$t.$req)){throw "Task JSON missing field: $req"}
    }
    return $t
}
'@

if(-not $raw.Contains($old)){throw 'Expected v3.4 Fetch-Task block not found. No changes made.'}
$raw=$raw.Replace($old,$new)
$raw=$raw.Replace('3EN Agent Runner v3.4','3EN Agent Runner v3.5')
$raw=$raw.Replace('3EN AGENT v3.4 - NEW TASK','3EN AGENT v3.5 - NEW TASK')
$raw=$raw.Replace("'User-Agent'='3EN-Agent-v3.4'","'User-Agent'='3EN-Agent-v3.5'")
Set-Content -LiteralPath $Target -Value $raw -Encoding UTF8
Write-Host "CREATED=$Target"

$tokens=$null;$errors=$null
[System.Management.Automation.Language.Parser]::ParseFile($Target,[ref]$tokens,[ref]$errors)|Out-Null
if($errors.Count -gt 0){$errors | ForEach-Object { Write-Host $_.Message -ForegroundColor Red }; throw 'v3.5 syntax validation failed'}
Write-Host 'SYNTAX=PASS'

$headers=@{Accept='application/vnd.github+json';'X-GitHub-Api-Version'='2022-11-28';'User-Agent'='3EN-Agent-v3.5-test'}
$token=$env:THREEEN_GH_TOKEN
if([string]::IsNullOrWhiteSpace($token)){$token=[Environment]::GetEnvironmentVariable('THREEEN_GH_TOKEN','User')}
if(-not [string]::IsNullOrWhiteSpace($token)){$headers.Authorization="Bearer $token"}
$r=Invoke-RestMethod -Uri $ApiTaskUrl -Headers $headers -TimeoutSec 20
$json=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([string]$r.content -replace '\s','')))
$t=$json|ConvertFrom-Json
Write-Host ('API_TASK_ID='+$t.id)
Write-Host ('API_TASK_TITLE='+$t.title)
if($t.id -ne '2026-09-09-010'){throw "Expected task 010, got $($t.id)"}
Write-Host 'API_FETCH_TEST=PASS'
Write-Host ''
Write-Host 'Stop the currently running v3.4 window with Ctrl+C, then run:' -ForegroundColor Yellow
Write-Host ('powershell -ExecutionPolicy Bypass -File "'+$Target+'" -TaskUrl "'+$ApiTaskUrl+'" -PollSeconds 15') -ForegroundColor Cyan
