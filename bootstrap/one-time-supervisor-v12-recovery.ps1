# ONE-TIME BOOTSTRAP: upgrade to 3EN Multi-Project Supervisor v1.2 when lane consumption is stalled
# Windows PowerShell 5.1+
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent'
$Repo='https://raw.githubusercontent.com/3en4all/3en-command-runner/main'
$Installer=Join-Path $Root '3en-multiproject-supervisor-install-v1.2.ps1'
$ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
Invoke-WebRequest -UseBasicParsing -Uri ($Repo+'/scripts/3en-multiproject-supervisor-install-v1.2.ps1?ts='+$ts) -OutFile $Installer -TimeoutSec 30
$tok=$null;$err=$null
[System.Management.Automation.Language.Parser]::ParseFile($Installer,[ref]$tok,[ref]$err)|Out-Null
if(@($err).Count -gt 0){throw ('SUPERVISOR_V12_INSTALLER_SYNTAX_ERRORS='+@($err).Count)}
& $Installer -Phase Install
& $Installer -Phase Test
$health=Get-Content (Join-Path $Root '3en-multiproject-supervisor-v12.health.json') -Raw|ConvertFrom-Json
if([string]$health.version -ne '1.2'){throw 'SUPERVISOR_V12_HEALTH_VERSION_INVALID'}
Write-Host ('ONE_TIME_SUPERVISOR_V12_RECOVERY=SUCCESS;STATUS='+$health.status+';LANES='+@($health.lanes).Count+';TOKEN='+$health.tokenAvailable)
Write-Host 'AUTOMATION_RESUMED=TRUE'
