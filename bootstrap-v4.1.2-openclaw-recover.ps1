$ErrorActionPreference = 'Stop'
$root = 'C:\3EN-Agent'
$runner = Join-Path $root '3en-agent-runner-v4.0.2.ps1'
$log = Join-Path $root 'bootstrap-v4.1.2-openclaw.log'
New-Item -ItemType Directory -Force -Path $root | Out-Null

function Write-BootLog {
    param([string]$Message,[string]$Level='INFO')
    $line = '[{0}][{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message
    Add-Content -LiteralPath $log -Encoding UTF8 -Value $line
}

function Publish-Diagnostic {
    param([string]$Message)
    try {
        $token = $env:THREEEN_GH_TOKEN
        if ([string]::IsNullOrWhiteSpace($token)) { $token = [Environment]::GetEnvironmentVariable('THREEEN_GH_TOKEN','User') }
        if ([string]::IsNullOrWhiteSpace($token)) { return }
        $headers = @{
            Authorization = 'Bearer ' + $token
            Accept = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
            'User-Agent' = '3EN-Bootstrap-v4.1.2'
        }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $path = 'results/bootstrap-v4.1.2-' + $stamp + '.diagnostic.txt'
        $uri = 'https://api.github.com/repos/3en4all/3en-command-runner/contents/' + $path
        $text = "3EN v4.1.2 recovery diagnostic`r`n" + $Message + "`r`n"
        if (Test-Path -LiteralPath $log) { $text += "`r`n--- LOCAL LOG ---`r`n" + (Get-Content -LiteralPath $log -Raw -Encoding UTF8) }
        $body = @{message='Publish v4.1.2 recovery diagnostic';content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text));branch='main'} | ConvertTo-Json -Compress
        Invoke-RestMethod -Method Put -Uri $uri -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 20 | Out-Null
    } catch {}
}

function Stop-ProcessTree {
    param([int]$RootProcessId,[int]$ProtectProcessId)
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $children = @{}
    foreach ($p in $all) {
        $parentId = [int]$p.ParentProcessId
        if (-not $children.ContainsKey($parentId)) { $children[$parentId] = New-Object System.Collections.Generic.List[int] }
        [void]$children[$parentId].Add([int]$p.ProcessId)
    }
    $order = New-Object System.Collections.Generic.List[int]
    function Walk-ProcessTree([int]$ProcessIdToWalk) {
        if ($children.ContainsKey($ProcessIdToWalk)) {
            foreach ($childId in $children[$ProcessIdToWalk]) { Walk-ProcessTree $childId }
        }
        [void]$order.Add($ProcessIdToWalk)
    }
    Walk-ProcessTree $RootProcessId
    foreach ($processIdToStop in $order) {
        if ($processIdToStop -eq $ProtectProcessId) { continue }
        try { Stop-Process -Id $processIdToStop -Force -ErrorAction Stop; Write-BootLog ('Stopped PID=' + $processIdToStop) } catch {}
    }
}

try {
    Write-BootLog 'RECOVERY START'
    $me = $PID
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)

    $onboard = @($all | Where-Object {
        ($_.CommandLine -match 'openclaw') -and ($_.CommandLine -match '\bonboard\b')
    })

    foreach ($oc in $onboard) {
        $parent = $all | Where-Object { $_.ProcessId -eq $oc.ParentProcessId } | Select-Object -First 1
        Write-BootLog ('Found stuck OpenClaw onboarding PID=' + $oc.ProcessId + ' parent=' + $oc.ParentProcessId)
        if ($null -ne $parent -and $parent.ProcessId -ne $me -and ($parent.Name -eq 'powershell.exe' -or $parent.Name -eq 'pwsh.exe' -or $parent.Name -eq 'cmd.exe')) {
            Stop-ProcessTree -RootProcessId ([int]$parent.ProcessId) -ProtectProcessId $me
        } else {
            Stop-ProcessTree -RootProcessId ([int]$oc.ProcessId) -ProtectProcessId $me
        }
    }

    if ($onboard.Count -gt 0) { Start-Sleep -Seconds 2 }

    $all2 = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    foreach ($p in $all2) {
        if ($p.ProcessId -ne $me -and ($p.Name -eq 'powershell.exe' -or $p.Name -eq 'pwsh.exe') -and $p.CommandLine -match '3en-agent-runner-v4\.0\.2\.ps1') {
            Stop-ProcessTree -RootProcessId ([int]$p.ProcessId) -ProtectProcessId $me
        }
    }
    Start-Sleep -Seconds 1

    $uri = 'https://raw.githubusercontent.com/3en4all/3en-command-runner/main/3en-agent-runner-v4.0.2.ps1?ts=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $runner
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors) | Out-Null
    if (@($errors).Count -gt 0) { throw ('RUNNER_SYNTAX_FAILED count=' + @($errors).Count) }

    $probe = New-Object Threading.Mutex($false,'Global\3EN-Agent-Project-v402')
    $owned = $false
    try {
        $owned = $probe.WaitOne(0)
        if (-not $owned) {
            Publish-Diagnostic 'MUTEX_STILL_OWNED_AFTER_PROCESS_TREE_RECOVERY'
            Write-Host '3EN v4.1.2 NEEDS AUTOMATIC REPAIR' -ForegroundColor Yellow
            return
        }
    } finally {
        if ($owned) { try { $probe.ReleaseMutex() } catch {} }
        $probe.Dispose()
    }

    Write-Host '3EN v4.1.2 OPENCLAW RECOVERY START' -ForegroundColor Cyan
    Write-BootLog 'Mutex free; resuming project from persisted state'

    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,'-ProjectPath','project-v4.1-openclaw-bridge.json')
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Wait -PassThru -NoNewWindow
    $code = $proc.ExitCode
    Write-BootLog ('Runner returned code=' + $code)

    if ($code -eq 0) {
        Write-Host '3EN v4.1.2 OPENCLAW BRIDGE ACCEPTED' -ForegroundColor Green
        return
    }

    Publish-Diagnostic ('RUNNER_RETURNED_NONZERO code=' + $code)
    Write-Host '3EN v4.1.2 NEEDS AUTOMATIC REPAIR' -ForegroundColor Yellow
}
catch {
    Write-BootLog ($_ | Out-String) 'ERROR'
    Publish-Diagnostic ('RECOVERY_EXCEPTION=' + $_.Exception.Message)
    Write-Host '3EN v4.1.2 NEEDS AUTOMATIC REPAIR' -ForegroundColor Yellow
}
