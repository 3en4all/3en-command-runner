# ONE-TIME BOOTSTRAP: restore 3EN Multi-Project Supervisor v1.1 when no queue consumer is alive
# Windows PowerShell 5.1+, Administrator recommended
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent'
$Repo='https://raw.githubusercontent.com/3en4all/3en-command-runner/main'
$Installer=Join-Path $Root '3en-multiproject-supervisor-install-v1.1.ps1'
$ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
Invoke-WebRequest -UseBasicParsing -Uri ($Repo+'/scripts/3en-multiproject-supervisor-install-v1.1.ps1?ts='+$ts) -OutFile $Installer -TimeoutSec 30
$tok=$null;$err=$null
[System.Management.Automation.Language.Parser]::ParseFile($Installer,[ref]$tok,[ref]$err)|Out-Null
if(@($err).Count -gt 0){throw ('SUPERVISOR_V11_INSTALLER_SYNTAX_ERRORS='+@($err).Count)}
& $Installer -Phase Install
& $Installer -Phase Test
$health=Get-Content (Join-Path $Root '3en-multiproject-supervisor.health.json') -Raw|ConvertFrom-Json
if($health.status -notin @('IDLE','RUNNING')){throw ('SUPERVISOR_HEALTH_BAD='+$health.status)}
Write-Host ('ONE_TIME_SUPERVISOR_V11_RECOVERY=SUCCESS;STATUS='+$health.status+';LANES='+@($health.lanes).Count)
Write-Host 'AUTOMATION_RESUMED=TRUE'
