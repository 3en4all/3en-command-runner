$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root='C:\3EN-Agent'
$repo='https://raw.githubusercontent.com/3en4all/3en-command-runner/main'
$installer=Join-Path $root '3en-multiproject-supervisor-install-v1.3.2.ps1'
$ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
Invoke-WebRequest -UseBasicParsing -Uri ($repo+'/scripts/3en-multiproject-supervisor-install-v1.3.2.ps1?ts='+$ts) -OutFile $installer -TimeoutSec 30
$tok=$null;$err=$null
[System.Management.Automation.Language.Parser]::ParseFile($installer,[ref]$tok,[ref]$err)|Out-Null
if(@($err).Count -gt 0){throw ('V132_INSTALLER_SYNTAX_ERRORS='+@($err).Count)}
Write-Host 'V132_INSTALLER_SYNTAX=PASS'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Phase Install
if($LASTEXITCODE -ne 0){throw ('V132_INSTALL_EXIT='+$LASTEXITCODE)}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Phase Test
if($LASTEXITCODE -ne 0){throw ('V132_TEST_EXIT='+$LASTEXITCODE)}
Write-Host 'V132_BOOTSTRAP=PASS'
