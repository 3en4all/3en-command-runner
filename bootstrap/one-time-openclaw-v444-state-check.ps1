$ErrorActionPreference='Stop'
$root='C:\3EN-Agent'
$health=Join-Path $root '3en-multiproject-supervisor.health.json'
$state=Join-Path $root 'supervisor-state\openclaw.json'
$log=Join-Path $root '3en-multiproject-supervisor.log'
Write-Host '=== OPENCLAW V444 STATE CHECK ===' -ForegroundColor Cyan
if(Test-Path $health){Write-Host '--- HEALTH ---';Get-Content $health -Raw}else{Write-Host 'HEALTH_MISSING'}
if(Test-Path $state){Write-Host '--- OPENCLAW STATE ---';Get-Content $state -Raw}else{Write-Host 'OPENCLAW_STATE_MISSING'}
if(Test-Path $log){Write-Host '--- SUPERVISOR LOG (LAST 120) ---';Get-Content $log -Tail 120}else{Write-Host 'SUPERVISOR_LOG_MISSING'}
Write-Host 'OPENCLAW_V444_STATE_CHECK=COMPLETE'
