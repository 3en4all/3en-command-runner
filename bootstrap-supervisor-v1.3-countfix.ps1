$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root='C:\3EN-Agent'
$repo='https://raw.githubusercontent.com/3en4all/3en-command-runner/main'
$installer=Join-Path $root '3en-multiproject-supervisor-install-v1.3-countfix.ps1'
$ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
Invoke-WebRequest -UseBasicParsing -Uri ($repo+'/scripts/3en-multiproject-supervisor-install-v1.3.ps1?ts='+$ts) -OutFile $installer -TimeoutSec 30
$raw=Get-Content $installer -Raw
$raw=$raw.Replace("function Get-ProcByScript([string]`$name){`$pat=[regex]::Escape(`$name);@(Get-CimInstance","function Get-ProcByScript([string]`$name){`$pat=[regex]::Escape(`$name);,@(Get-CimInstance")
$needle="    `$ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();Invoke-WebRequest -UseBasicParsing -Uri (`$Repo+'/automation/3en-multiproject-supervisor-v1.3.ps1?ts='+`$ts) -OutFile `$Sup13 -TimeoutSec 30"
$inject=$needle+[Environment]::NewLine+"    `$core=Get-Content `$Sup13 -Raw;`$core=`$core.Replace('function Get-ProcByLane([string]`$lane){`$selfPat=[regex]::Escape(''3en-multiproject-supervisor-v1.3.ps1'');`$lanePat=[regex]::Escape(''-WorkerLane ''+`$lane);@(Get-CimInstance','function Get-ProcByLane([string]`$lane){`$selfPat=[regex]::Escape(''3en-multiproject-supervisor-v1.3.ps1'');`$lanePat=[regex]::Escape(''-WorkerLane ''+`$lane);,@(Get-CimInstance');Set-Content -LiteralPath `$Sup13 -Value `$core -Encoding UTF8"
if($raw -notlike ('*'+$needle+'*')){throw 'V13_COUNTFIX_CORE_DOWNLOAD_MARKER_MISSING'}
$raw=$raw.Replace($needle,$inject)
Set-Content -LiteralPath $installer -Value $raw -Encoding UTF8
$tok=$null;$err=$null
[System.Management.Automation.Language.Parser]::ParseFile($installer,[ref]$tok,[ref]$err)|Out-Null
if(@($err).Count -gt 0){throw ('V13_COUNTFIX_INSTALLER_SYNTAX_ERRORS='+@($err).Count)}
Write-Host 'V13_COUNTFIX_INSTALLER_SYNTAX=PASS'
try{
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Phase Install
  if($LASTEXITCODE -ne 0){throw ('V13_COUNTFIX_INSTALL_EXIT='+$LASTEXITCODE)}
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Phase Test
  if($LASTEXITCODE -ne 0){throw ('V13_COUNTFIX_TEST_EXIT='+$LASTEXITCODE)}
  Write-Host 'V13_COUNTFIX_BOOTSTRAP=PASS'
}catch{
  Write-Host ('V13_COUNTFIX_BOOTSTRAP=FAIL;ERROR='+$_.Exception.Message)
  throw
}
