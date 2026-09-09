Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent'
$Repo='https://raw.githubusercontent.com/3en4all/3en-command-runner/main'
$Installer=Join-Path $Root '3en-multiproject-supervisor-install-v1.3.ps1'
$ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
Invoke-WebRequest -UseBasicParsing -Uri ($Repo+'/scripts/3en-multiproject-supervisor-install-v1.3.ps1?ts='+$ts) -OutFile $Installer -TimeoutSec 30
$tok=$null;$err=$null
[System.Management.Automation.Language.Parser]::ParseFile($Installer,[ref]$tok,[ref]$err)|Out-Null
if(@($err).Count -gt 0){throw ('V13_INSTALLER_SYNTAX_ERRORS='+@($err).Count)}
Write-Host 'V13_BOOTSTRAP_INSTALLER_SYNTAX=PASS'
& $Installer -Phase Install
& $Installer -Phase Test
Write-Host 'V13_BOOTSTRAP=PASS'
