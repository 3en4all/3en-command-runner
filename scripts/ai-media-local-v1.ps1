param(
  [ValidateSet('Discovery','Storage','Acquire','Runtime','Acceptance')][string]$Phase='Discovery',
  [string]$Root='D:\AI-Media'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$StateDir=Join-Path $Root 'state'
$StateFile=Join-Path $StateDir 'state.json'
$InventoryFile=Join-Path $StateDir 'inventory.json'
$CacheRoot=Join-Path $Root 'cache'
$OutputRoot=Join-Path $Root 'output'

function Ensure-Dir([string]$p){ if(-not(Test-Path -LiteralPath $p)){New-Item -ItemType Directory -Force -Path $p|Out-Null} }
function Read-State { if(Test-Path $StateFile){return (Get-Content $StateFile -Raw -Encoding UTF8|ConvertFrom-Json)}; return [pscustomobject]@{} }
function Write-State($s){ Ensure-Dir $StateDir; $s|ConvertTo-Json -Depth 20|Set-Content $StateFile -Encoding UTF8 }
function CmdPath([string]$name){ $c=Get-Command $name -ErrorAction SilentlyContinue; if($c){return [string]$c.Source}; return $null }
function Find-Comfy {
  $candidates=@('D:\ComfyUI','D:\ComfyUI_windows_portable\ComfyUI','D:\AI\ComfyUI','D:\AI-LOCAL\apps\ComfyUI','D:\AI-Free3\ComfyUI','E:\ComfyUI','E:\AI\ComfyUI')
  foreach($p in $candidates){if(Test-Path (Join-Path $p 'main.py')){return $p}}
  foreach($drive in @('D:\','E:\')){
    if(Test-Path $drive){
      $lvl1=@(Get-ChildItem $drive -Directory -ErrorAction SilentlyContinue|Select-Object -First 120)
      foreach($d in $lvl1){
        if(Test-Path (Join-Path $d.FullName 'main.py')){if($d.Name -match 'Comfy'){return $d.FullName}}
        $lvl2=@(Get-ChildItem $d.FullName -Directory -ErrorAction SilentlyContinue|Where-Object{$_.Name -match 'Comfy'}|Select-Object -First 20)
        foreach($x in $lvl2){if(Test-Path (Join-Path $x.FullName 'main.py')){return $x.FullName}}
      }
    }
  }
  return $null
}
function Get-ModelFiles([string]$Comfy){
  $r=@(); if($Comfy){$m=Join-Path $Comfy 'models'; if(Test-Path $m){$r=@(Get-ChildItem $m -Recurse -File -ErrorAction SilentlyContinue|Where-Object{$_.Extension -in @('.safetensors','.ckpt','.gguf','.pt','.pth')}|Select-Object FullName,Name,Length)}}
  return @($r)
}
function Download-File([string]$Url,[string]$Dest,[Int64]$MinBytes){
  if((Test-Path $Dest) -and ((Get-Item $Dest).Length -ge $MinBytes)){Write-Host ('REUSE='+$Dest);return}
  Ensure-Dir (Split-Path $Dest -Parent)
  $tmp=$Dest+'.partial'
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  Write-Host ('DOWNLOAD='+$Url)
  Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $tmp
  if((Get-Item $tmp).Length -lt $MinBytes){throw ('download too small: '+$Dest)}
  Move-Item $tmp $Dest -Force
  Write-Host ('DOWNLOADED='+$Dest)
}

Ensure-Dir $Root; Ensure-Dir $StateDir

if($Phase -eq 'Discovery'){
  $gpuText=''; $nvs=CmdPath 'nvidia-smi.exe'; if($nvs){try{$gpuText=& $nvs --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>$null|Out-String}catch{}}
  $ram=[math]::Round(((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB),1)
  $disks=@(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"|Select-Object DeviceID,@{n='FreeGB';e={[math]::Round($_.FreeSpace/1GB,1)}},@{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}})
  $comfy=Find-Comfy
  $models=Get-ModelFiles $comfy
  $ollama=CmdPath 'ollama.exe'; if(-not $ollama){foreach($p in @('D:\AI-Free3\ollama.exe','C:\Users\'+$env:USERNAME+'\AppData\Local\Programs\Ollama\ollama.exe')){if(Test-Path $p){$ollama=$p;break}}}
  $jan=$null; foreach($p in @('D:\Jan\Jan.exe','C:\Users\'+$env:USERNAME+'\AppData\Local\Programs\Jan\Jan.exe')){if(Test-Path $p){$jan=$p;break}}
  $ffmpeg=CmdPath 'ffmpeg.exe'
  $python=CmdPath 'python.exe'
  $llmModelRoot=$null; if(Test-Path 'D:\AI-Free3\models'){$llmModelRoot='D:\AI-Free3\models'}
  $inv=[ordered]@{
    timestamp=(Get-Date).ToString('o'); computer=$env:COMPUTERNAME; gpu=$gpuText.Trim(); ramGB=$ram; disks=$disks;
    comfyUI=$comfy; ffmpeg=$ffmpeg; python=$python; ollama=$ollama; jan=$jan;
    llmModelRoot=$llmModelRoot;
    comfyModels=$models
  }
  $inv|ConvertTo-Json -Depth 20|Set-Content $InventoryFile -Encoding UTF8
  $s=[pscustomobject]@{phase='Discovery';comfyUI=$comfy;ffmpeg=$ffmpeg;python=$python;ollama=$ollama;jan=$jan;gpu=$gpuText.Trim();ramGB=$ram;imageModel=$null;videoModel=$null;videoVae=$null;videoTextEncoder=$null;audioReady=$false;voiceReady=$false;storageReady=$false;runtimeReady=$false;acceptance=$false}
  foreach($f in $models){
    if(-not $s.imageModel -and $f.Name -match '(?i)sdxl|xl.*base|juggernaut.*xl|dreamshaper.*xl'){ $s.imageModel=$f.FullName }
    if(-not $s.videoModel -and $f.Name -match '(?i)wan2\.2.*ti2v.*5B'){ $s.videoModel=$f.FullName }
    if(-not $s.videoVae -and $f.Name -match '(?i)wan2\.2_vae'){ $s.videoVae=$f.FullName }
    if(-not $s.videoTextEncoder -and $f.Name -match '(?i)umt5_xxl.*fp8'){ $s.videoTextEncoder=$f.FullName }
    if($f.Name -match '(?i)stable.*audio|audio.*open'){ $s.audioReady=$true }
  }
  if((CmdPath 'piper.exe') -or (Get-ChildItem 'D:\' -Filter 'kokoro*.py' -Recurse -ErrorAction SilentlyContinue|Select-Object -First 1)){ $s.voiceReady=$true }
  Write-State $s
  Write-Host ('COMFY='+$comfy);Write-Host ('FFMPEG='+$ffmpeg);Write-Host ('PYTHON='+$python);Write-Host ('OLLAMA='+$ollama);Write-Host ('JAN='+$jan);Write-Host ('GPU='+$gpuText.Trim());Write-Host ('RAM_GB='+$ram);Write-Host ('LLM_MODEL_ROOT='+$llmModelRoot)
  Write-Host 'DISCOVERY=PASS'; exit 0
}

$s=Read-State
if(-not $s.PSObject.Properties['comfyUI']){throw 'Run Discovery first'}

if($Phase -eq 'Storage'){
  foreach($p in @($CacheRoot,(Join-Path $CacheRoot 'huggingface'),(Join-Path $CacheRoot 'torch'),(Join-Path $CacheRoot 'pip'),(Join-Path $Root 'models'),(Join-Path $Root 'workflows'),(Join-Path $Root 'input'),$OutputRoot,(Join-Path $OutputRoot 'images'),(Join-Path $OutputRoot 'videos'),(Join-Path $OutputRoot 'audio'),(Join-Path $OutputRoot 'voice'),(Join-Path $Root 'venvs'),(Join-Path $Root 'scripts'))){Ensure-Dir $p}
  $launcher=@"
`$env:HF_HOME='$($CacheRoot)\huggingface'
`$env:HUGGINGFACE_HUB_CACHE='$($CacheRoot)\huggingface\hub'
`$env:TRANSFORMERS_CACHE='$($CacheRoot)\huggingface\transformers'
`$env:TORCH_HOME='$($CacheRoot)\torch'
`$env:PIP_CACHE_DIR='$($CacheRoot)\pip'
`$env:XDG_CACHE_HOME='$($CacheRoot)\xdg'
Write-Host '3EN AI Media environment active. Cache/models stay on D:.'
"@
  $launcher|Set-Content (Join-Path $Root 'Start-3EN-AI-Media.ps1') -Encoding UTF8
  $s.storageReady=$true;$s.phase='Storage';Write-State $s;Write-Host 'STORAGE=PASS';exit 0
}

if($Phase -eq 'Acquire'){
  if(-not $s.storageReady){throw 'Storage phase not complete'}
  if(-not $s.comfyUI){throw 'ComfyUI not detected. Separate application install is required before model acquisition.'}
  $modelRoot=Join-Path $s.comfyUI 'models'
  if(-not $s.imageModel){
    $dst=Join-Path $modelRoot 'checkpoints\sd_xl_base_1.0.safetensors'
    Download-File 'https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors?download=true' $dst 6000000000
    $s.imageModel=$dst
  }
  if(-not $s.videoModel){
    $dst=Join-Path $modelRoot 'diffusion_models\wan2.2_ti2v_5B_fp16.safetensors'
    Download-File 'https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_ti2v_5B_fp16.safetensors?download=true' $dst 9000000000
    $s.videoModel=$dst
  }
  if(-not $s.videoVae){
    $dst=Join-Path $modelRoot 'vae\wan2.2_vae.safetensors'
    Download-File 'https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan2.2_vae.safetensors?download=true' $dst 1200000000
    $s.videoVae=$dst
  }
  if(-not $s.videoTextEncoder){
    $dst=Join-Path $modelRoot 'text_encoders\umt5_xxl_fp8_e4m3fn_scaled.safetensors'
    Download-File 'https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors?download=true' $dst 6000000000
    $s.videoTextEncoder=$dst
  }
  $s.phase='Acquire';Write-State $s;Write-Host 'ACQUIRE=PASS';exit 0
}

if($Phase -eq 'Runtime'){
  if(-not $s.comfyUI){throw 'ComfyUI missing'}
  if(-not(Test-Path $s.imageModel)){throw 'image model missing'}
  if(-not(Test-Path $s.videoModel)){throw 'video model missing'}
  if(-not(Test-Path $s.videoVae)){throw 'video VAE missing'}
  if(-not(Test-Path $s.videoTextEncoder)){throw 'video text encoder missing'}
  $cfg=[ordered]@{root=$Root;comfyUI=$s.comfyUI;ffmpeg=$s.ffmpeg;imageModel=$s.imageModel;videoModel=$s.videoModel;videoVae=$s.videoVae;videoTextEncoder=$s.videoTextEncoder;outputs=$OutputRoot;llmModels='D:\AI-Free3\models';cache=$CacheRoot}
  $cfg|ConvertTo-Json -Depth 10|Set-Content (Join-Path $StateDir 'runtime.json') -Encoding UTF8
  $s.runtimeReady=$true;$s.phase='Runtime';Write-State $s;Write-Host 'RUNTIME=PASS';exit 0
}

if($Phase -eq 'Acceptance'){
  if(-not $s.runtimeReady){throw 'runtime not ready'}
  $checks=[ordered]@{CDriveFreeGB=[math]::Round((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace/1GB,1);DDriveFreeGB=[math]::Round((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='D:'").FreeSpace/1GB,1);ComfyUI=(Test-Path (Join-Path $s.comfyUI 'main.py'));ImageModel=(Test-Path $s.imageModel);VideoModel=(Test-Path $s.videoModel);VideoVae=(Test-Path $s.videoVae);VideoTextEncoder=(Test-Path $s.videoTextEncoder);CacheRoot=$CacheRoot;OutputRoot=$OutputRoot}
  $checks|ConvertTo-Json -Depth 10|Set-Content (Join-Path $StateDir 'acceptance.json') -Encoding UTF8
  if(-not $checks.ComfyUI -or -not $checks.ImageModel -or -not $checks.VideoModel -or -not $checks.VideoVae -or -not $checks.VideoTextEncoder){throw 'acceptance checks failed'}
  $s.acceptance=$true;$s.phase='Acceptance';Write-State $s;Write-Host 'AI_MEDIA_PROJECT_ACCEPTANCE=PASS';exit 0
}
