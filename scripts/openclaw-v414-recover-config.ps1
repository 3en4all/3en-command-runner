$ErrorActionPreference='Stop'
$root='C:/3EN-Agent/openclaw-bridge'
$configDir=Join-Path $env:USERPROFILE '.openclaw'
$configPath=Join-Path $configDir 'openclaw.json'
New-Item -ItemType Directory -Force -Path $root,$configDir | Out-Null

function Test-UsableConfig([string]$Path) {
  if(-not(Test-Path -LiteralPath $Path)){ return $false }
  try {
    $raw=Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if([string]::IsNullOrWhiteSpace($raw)){ return $false }
    $null=$raw | ConvertFrom-Json -ErrorAction Stop
    return $true
  } catch { return $false }
}

# Keep only compact configuration evidence; never recursively copy the whole OpenClaw tree.
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir=Join-Path $root ('config-snapshots/'+$stamp)
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
if(Test-Path -LiteralPath $configPath){ Copy-Item -LiteralPath $configPath -Destination (Join-Path $backupDir 'openclaw.json.before') -Force }

# If current config is invalid or clearly truncated, rebuild a baseline using the official CLI.
$currentLen=0
if(Test-Path -LiteralPath $configPath){ $currentLen=(Get-Item -LiteralPath $configPath).Length }
if((-not(Test-UsableConfig $configPath)) -or $currentLen -lt 500) {
  if(Test-Path -LiteralPath $configPath){ Move-Item -LiteralPath $configPath -Destination (Join-Path $backupDir 'openclaw.json.quarantined') -Force }
  $stdout=Join-Path $root 'setup-baseline.stdout.txt'
  $stderr=Join-Path $root 'setup-baseline.stderr.txt'
  Remove-Item $stdout,$stderr -Force -ErrorAction SilentlyContinue
  $p=Start-Process -FilePath 'openclaw.cmd' -ArgumentList @('setup','--baseline') -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  if($p.ExitCode -ne 0){ throw ('OPENCLAW_BASELINE_SETUP_FAILED code='+$p.ExitCode) }
  if(-not(Test-UsableConfig $configPath)){ throw 'OPENCLAW_BASELINE_CONFIG_INVALID' }
}

$cfg=(Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json)
function Ensure-ObjectProperty($obj,[string]$name) {
  $p=$obj.PSObject.Properties[$name]
  if($null -eq $p -or $null -eq $p.Value) {
    $v=[pscustomobject]@{}
    if($null -eq $p){ $obj | Add-Member -NotePropertyName $name -NotePropertyValue $v } else { $p.Value=$v }
    return $v
  }
  return $p.Value
}
function Set-ObjectProperty($obj,[string]$name,$value) {
  $p=$obj.PSObject.Properties[$name]
  if($null -eq $p){ $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value } else { $p.Value=$value }
}

# Discover a real native Ollama endpoint.
$ports=New-Object System.Collections.Generic.HashSet[int]
[void]$ports.Add(11434)
try { Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object {$_.LocalAddress -in @('127.0.0.1','0.0.0.0','::1','::')} | ForEach-Object {[void]$ports.Add([int]$_.LocalPort)} } catch {}
$eps=@()
foreach($port in $ports){
  if($port -lt 1024 -or $port -gt 65535){ continue }
  try {
    $r=Invoke-RestMethod -Uri ('http://127.0.0.1:'+$port+'/api/tags') -TimeoutSec 2 -ErrorAction Stop
    $names=@($r.models | ForEach-Object {$_.name})
    if($names.Count -gt 0){ $eps += [pscustomobject]@{baseUrl=('http://127.0.0.1:'+$port);models=$names} }
  } catch {}
}
if($eps.Count -lt 1){ throw 'NO_OLLAMA_ENDPOINT_WITH_MODELS' }
$preferred=@('qwen3:8b','qwen2.5-coder:14b','mistral-nemo','deepseek-r1:14b')
$chosen=$null
foreach($e in $eps){ foreach($m in $preferred){ if(@($e.models)-contains $m){ $chosen=[pscustomobject]@{baseUrl=$e.baseUrl;model=$m}; break } }; if($chosen){ break } }
if(-not $chosen){ $e=$eps[0]; $chosen=[pscustomobject]@{baseUrl=$e.baseUrl;model=[string]$e.models[0]} }

$models=Ensure-ObjectProperty $cfg 'models'
$providers=Ensure-ObjectProperty $models 'providers'
$ollama=Ensure-ObjectProperty $providers 'ollama'
Set-ObjectProperty $ollama 'baseUrl' $chosen.baseUrl
Set-ObjectProperty $ollama 'api' 'ollama'
Set-ObjectProperty $ollama 'apiKey' 'ollama-local'
$gateway=Ensure-ObjectProperty $cfg 'gateway'
Set-ObjectProperty $gateway 'mode' 'local'

# Atomic local write prevents the CLI config watcher from observing a chain of tiny intermediate configs.
$tmp=$configPath+'.3en-v414.tmp'
$json=$cfg | ConvertTo-Json -Depth 50
[IO.File]::WriteAllText($tmp,$json,(New-Object Text.UTF8Encoding($false)))
$verify=Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
if([string]$verify.gateway.mode -ne 'local'){ throw 'ATOMIC_GATEWAY_MODE_VERIFY_FAILED' }
if([string]$verify.models.providers.ollama.baseUrl -ne [string]$chosen.baseUrl){ throw 'ATOMIC_OLLAMA_URL_VERIFY_FAILED' }
Move-Item -LiteralPath $tmp -Destination $configPath -Force

[Environment]::SetEnvironmentVariable('OLLAMA_API_KEY','ollama-local','User')
$env:OLLAMA_API_KEY='ollama-local'
$stdout=Join-Path $root 'models-set-v414.stdout.txt'
$stderr=Join-Path $root 'models-set-v414.stderr.txt'
Remove-Item $stdout,$stderr -Force -ErrorAction SilentlyContinue
$p=Start-Process -FilePath 'openclaw.cmd' -ArgumentList @('models','set',('ollama/'+$chosen.model)) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr
if($p.ExitCode -ne 0){ throw ('OPENCLAW_MODEL_SET_FAILED code='+$p.ExitCode) }
$chosen | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'ollama-endpoint-v414.json') -Encoding UTF8
$chosen.model | Set-Content -LiteralPath (Join-Path $root 'selected-model.txt') -Encoding ASCII
$final=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
if([string]$final.gateway.mode -ne 'local'){ throw 'FINAL_GATEWAY_MODE_LOST' }
if([string]$final.models.providers.ollama.baseUrl -match '/v1'){ throw 'FINAL_OLLAMA_V1_FORBIDDEN' }
Write-Output ('V414_ENDPOINT='+$chosen.baseUrl)
Write-Output ('V414_MODEL='+$chosen.model)
Write-Output 'V414_CONFIG=PASS'
