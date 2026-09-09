$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent\workbench\plugin-discovery-057y'
$Out=Join-Path $Root 'discovery.json'
if(Test-Path $Root){Remove-Item $Root -Recurse -Force}
New-Item -ItemType Directory -Force -Path $Root|Out-Null
function Run([string[]]$Cmd){
  $text=@(& $Cmd[0] $Cmd[1..($Cmd.Count-1)] 2>&1);$ec=$LASTEXITCODE
  [pscustomobject]@{exit=$ec;text=(($text|ForEach-Object{[string]$_}) -join "`n")}
}
$ver=Run @('openclaw.cmd','--version')
$help=Run @('openclaw.cmd','plugins','--help')
$list=Run @('openclaw.cmd','plugins','list','--json')
$cfgPath=Join-Path $env:USERPROFILE '.openclaw\openclaw.json'
$gateway=[ordered]@{configExists=(Test-Path $cfgPath);port=$null;bind=$null;authMode=$null;toolsAllow=@();toolsDeny=@()}
if(Test-Path $cfgPath){
  $c=Get-Content $cfgPath -Raw|ConvertFrom-Json
  if($c.gateway){
    $gateway.port=$c.gateway.port;$gateway.bind=$c.gateway.bind
    if($c.gateway.auth){$gateway.authMode=$c.gateway.auth.mode}
    if($c.gateway.tools){$gateway.toolsAllow=@($c.gateway.tools.allow);$gateway.toolsDeny=@($c.gateway.tools.deny)}
  }
}
[ordered]@{
 schemaVersion=1
 openclawVersion=$ver.text.Trim()
 versionExit=$ver.exit
 pluginsHelpExit=$help.exit
 pluginsListExit=$list.exit
 pluginsHelp=$help.text
 pluginsList=$list.text
 gateway=$gateway
 secretsCaptured=$false
 discoveredAt=(Get-Date).ToString('o')
}|ConvertTo-Json -Depth 8|Set-Content $Out -Encoding UTF8
Write-Output ('V459_057Y_VERSION='+$ver.text.Trim()+';EXIT='+$ver.exit)
Write-Output ('V459_057Y_PLUGINS_HELP_EXIT='+$help.exit+';LIST_EXIT='+$list.exit)
Write-Output ('V459_057Y_GATEWAY_PORT='+$gateway.port+';BIND='+$gateway.bind+';AUTH='+$gateway.authMode)
Write-Output ('V459_057Y_GATEWAY_ALLOW='+(@($gateway.toolsAllow)-join ','))
if($ver.exit -ne 0 -or $help.exit -ne 0){throw '057Y_OPENCLAW_OR_PLUGIN_CLI_NOT_READY'}
Write-Output 'V459_057Y_DISCOVERY=PASS;SECRETS_CAPTURED=false'
