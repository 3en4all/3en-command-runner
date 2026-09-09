$ErrorActionPreference='Stop'
$root='C:/3EN-Agent/openclaw-bridge'
New-Item -ItemType Directory -Force -Path $root | Out-Null

$ports=New-Object System.Collections.Generic.HashSet[int]
[void]$ports.Add(11434)
try {
  Get-NetTCPConnection -State Listen -ErrorAction Stop |
    Where-Object { $_.LocalAddress -in @('127.0.0.1','0.0.0.0','::1','::') } |
    ForEach-Object { [void]$ports.Add([int]$_.LocalPort) }
} catch {}

$candidates=@()
foreach($p in $ports) {
  if($p -lt 1024 -or $p -gt 65535){ continue }
  try {
    $r=Invoke-RestMethod -Uri ('http://127.0.0.1:'+$p+'/api/tags') -TimeoutSec 2 -ErrorAction Stop
    $names=@($r.models | ForEach-Object { $_.name })
    if($names.Count -gt 0) {
      $candidates += [pscustomobject]@{ baseUrl=('http://127.0.0.1:'+$p); port=$p; models=$names }
    }
  } catch {}
}
if($candidates.Count -lt 1){ throw 'NO_OLLAMA_ENDPOINT_WITH_MODELS' }

$preferred=@('qwen3:8b','qwen2.5-coder:14b','mistral-nemo','deepseek-r1:14b')
$chosen=$null
foreach($c in $candidates) {
  foreach($m in $preferred) {
    if(@($c.models) -contains $m) {
      $chosen=[pscustomobject]@{ baseUrl=$c.baseUrl; port=$c.port; model=$m }
      break
    }
  }
  if($chosen){ break }
}
if(-not $chosen) {
  $c=$candidates[0]
  $chosen=[pscustomobject]@{ baseUrl=$c.baseUrl; port=$c.port; model=[string]$c.models[0] }
}
$chosen | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'ollama-endpoint-v413.json') -Encoding UTF8

$configDir=Join-Path $env:USERPROFILE '.openclaw'
$configPath=Join-Path $configDir 'openclaw.json'
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
if(Test-Path $configPath) {
  $raw=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
  if([string]::IsNullOrWhiteSpace($raw)){ $cfg=[pscustomobject]@{} } else { $cfg=$raw | ConvertFrom-Json }
} else {
  $cfg=[pscustomobject]@{}
}

function Ensure-ObjectProperty($obj,[string]$name) {
  $p=$obj.PSObject.Properties[$name]
  if($null -eq $p -or $null -eq $p.Value) {
    $v=[pscustomobject]@{}
    if($null -eq $p){ $obj | Add-Member -NotePropertyName $name -NotePropertyValue $v }
    else { $p.Value=$v }
    return $v
  }
  return $p.Value
}
function Set-ObjectProperty($obj,[string]$name,$value) {
  $p=$obj.PSObject.Properties[$name]
  if($null -eq $p){ $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
  else { $p.Value=$value }
}

$models=Ensure-ObjectProperty $cfg 'models'
$providers=Ensure-ObjectProperty $models 'providers'
$ollama=Ensure-ObjectProperty $providers 'ollama'
Set-ObjectProperty $ollama 'baseUrl' $chosen.baseUrl
Set-ObjectProperty $ollama 'api' 'ollama'
Set-ObjectProperty $ollama 'apiKey' 'ollama-local'

$gateway=Ensure-ObjectProperty $cfg 'gateway'
Set-ObjectProperty $gateway 'mode' 'local'

$tmp=$configPath+'.v413.tmp'
$cfg | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $tmp -Encoding UTF8
$check=Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
if([string]$check.models.providers.ollama.baseUrl -ne [string]$chosen.baseUrl){ throw 'ATOMIC_CONFIG_VERIFY_BASEURL_FAILED' }
if([string]$check.gateway.mode -ne 'local'){ throw 'ATOMIC_CONFIG_VERIFY_GATEWAY_FAILED' }
Move-Item -LiteralPath $tmp -Destination $configPath -Force

[Environment]::SetEnvironmentVariable('OLLAMA_API_KEY','ollama-local','User')
$env:OLLAMA_API_KEY='ollama-local'
$out=& openclaw models set ('ollama/'+$chosen.model) 2>&1 | Out-String
$out | Set-Content -LiteralPath (Join-Path $root 'models-set-v413.txt') -Encoding UTF8
if($LASTEXITCODE -ne 0){ throw 'OPENCLAW_MODEL_SET_FAILED' }

$final=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
if([string]$final.models.providers.ollama.baseUrl -ne [string]$chosen.baseUrl){ throw 'FINAL_CONFIG_BASEURL_LOST' }
if([string]$final.gateway.mode -ne 'local'){ throw 'FINAL_CONFIG_GATEWAY_MODE_LOST' }
Write-Output ('V413_ENDPOINT='+$chosen.baseUrl)
Write-Output ('V413_MODEL='+$chosen.model)
Write-Output 'V413_ATOMIC_CONFIG=PASS'
