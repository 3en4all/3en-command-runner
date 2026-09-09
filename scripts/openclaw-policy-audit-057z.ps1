$ErrorActionPreference='Stop'
$cfgPath=Join-Path $env:USERPROFILE '.openclaw\openclaw.json'
if(-not(Test-Path $cfgPath)){throw '057Z_OPENCLAW_CONFIG_MISSING'}
$c=Get-Content $cfgPath -Raw|ConvertFrom-Json
function Arr($v){if($null-eq$v){return @()};return @($v|ForEach-Object{[string]$_})}
$global=[ordered]@{profile='';allow=@();deny=@();execMode='';execHost=''}
if($null-ne$c.tools){
  if($null-ne$c.tools.profile){$global.profile=[string]$c.tools.profile}
  $global.allow=Arr $c.tools.allow
  $global.deny=Arr $c.tools.deny
  if($null-ne$c.tools.exec){if($null-ne$c.tools.exec.mode){$global.execMode=[string]$c.tools.exec.mode};if($null-ne$c.tools.exec.host){$global.execHost=[string]$c.tools.exec.host}}
}
$agents=@()
if($null-ne$c.agents -and $null-ne$c.agents.list){
  foreach($a in @($c.agents.list)){
    $row=[ordered]@{id=[string]$a.id;profile='';allow=@();deny=@()}
    if($null-ne$a.tools){if($null-ne$a.tools.profile){$row.profile=[string]$a.tools.profile};$row.allow=Arr $a.tools.allow;$row.deny=Arr $a.tools.deny}
    $agents+=[pscustomobject]$row
  }
}
$out=[ordered]@{schemaVersion=1;global=$global;agents=$agents;secretFieldsEmitted=$false;configPath=$cfgPath;auditedAt=(Get-Date).ToString('o')}
$out|ConvertTo-Json -Depth 8|Set-Content 'C:\3EN-Agent\openclaw-policy-audit-057z.json' -Encoding UTF8
Write-Output ('V460_057Z_GLOBAL_PROFILE='+$global.profile)
Write-Output ('V460_057Z_GLOBAL_ALLOW='+($global.allow -join ','))
Write-Output ('V460_057Z_GLOBAL_DENY='+($global.deny -join ','))
Write-Output ('V460_057Z_EXEC_MODE='+$global.execMode+';HOST='+$global.execHost)
foreach($a in $agents){Write-Output ('V460_057Z_AGENT='+$a.id+';PROFILE='+$a.profile+';ALLOW='+($a.allow -join ',')+';DENY='+($a.deny -join ','))}
Write-Output 'V460_057Z_AUDIT=PASS;SECRETS_EMITTED=false'
