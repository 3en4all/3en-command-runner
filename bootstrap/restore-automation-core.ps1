# 3EN one-time automation core recovery bootstrap
# Windows PowerShell 5.1+, run as Administrator
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent'
$Repo='https://raw.githubusercontent.com/3en4all/3en-command-runner/main'
$Backup=Join-Path $Root ('backups\automation-core-recovery\'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Backup|Out-Null
foreach($f in @('3en-project-inbox.ps1','3en-project-inbox.state.json','3en-project-inbox.log')){
  $p=Join-Path $Root $f
  if(Test-Path $p){Copy-Item $p $Backup -Force}
}
Write-Host ('BACKUP='+$Backup)

$Runner=Join-Path $Root '3en-agent-runner-v4.0.3.ps1'
if(-not(Test-Path $Runner)){throw 'RUNNER403_MISSING'}
$Inbox=Join-Path $Root '3en-project-inbox.ps1'
Invoke-WebRequest -UseBasicParsing -Uri ($Repo+'/automation/3en-project-inbox.ps1?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -OutFile $Inbox
$tok=$null;$err=$null
[System.Management.Automation.Language.Parser]::ParseFile($Inbox,[ref]$tok,[ref]$err)|Out-Null
if(@($err).Count -gt 0){throw ('PROJECT_INBOX_SYNTAX_ERRORS='+@($err).Count)}

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object{$_.CommandLine -and $_.CommandLine -match '3en-project-inbox\.ps1'} |
  ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}

$StartupDir=Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
New-Item -ItemType Directory -Force -Path $StartupDir|Out-Null
$Startup=Join-Path $StartupDir '3EN-Project-Inbox.cmd'
$Line='@echo off'+[Environment]::NewLine+'start "3EN Project Inbox" /min powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$Inbox+'"'
Set-Content -LiteralPath $Startup -Value $Line -Encoding ASCII

Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$Inbox) -WorkingDirectory $Root | Out-Null
Start-Sleep 4
$p=Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object{$_.CommandLine -and $_.CommandLine -match '3en-project-inbox\.ps1'}
if(-not $p){throw 'PROJECT_INBOX_PROCESS_NOT_RUNNING'}
$log=Join-Path $Root '3en-project-inbox.log'
if(-not(Test-Path $log)){throw 'PROJECT_INBOX_LOG_MISSING'}
Write-Host 'PROJECT_INBOX_PROCESS=PASS'

$ptr=Invoke-RestMethod -UseBasicParsing -Uri ($Repo+'/inbox/current-project.json?ts='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
Write-Host ('POINTER_REVISION='+$ptr.revision)
Write-Host ('POINTER_PROJECT='+$ptr.projectPath)
Write-Host 'AUTOMATION_CORE_RECOVERY=SUCCESS'
