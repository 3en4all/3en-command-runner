# Wait for router+Pi-hole project terminal success, then launch Security & Privacy Stack.
$ErrorActionPreference='Stop'
$root='C:\3EN-Agent'
$state=Join-Path $root '3en-project.state.json'
$runner=Join-Path $root '3en-agent-runner-v3.10.1.ps1'
$acceptedProjects=@('2026-09-09-router-pihole-final-v1','2026-09-09-router-pihole-final-v2','2026-09-09-router-pihole-final-v3')
$deadline=(Get-Date).AddMinutes(15)
while((Get-Date)-lt$deadline){
  try{
    if(Test-Path $state){
      $s=Get-Content $state -Raw|ConvertFrom-Json
      if([string]$s.projectId -in $acceptedProjects){
        $p=$s.chapterStatuses.PSObject.Properties['router-pihole-005-final']
        if($p -and [string]$p.Value -in @('SUCCESS','SUCCESS_RECOVERED')){break}
        if($p -and [string]$p.Value -like 'FAILED_*'){exit 20}
      }
    }
  }catch{}
  Start-Sleep 2
}
if((Get-Date)-ge$deadline){exit 21}
Start-Sleep 3
if(-not(Test-Path $runner)){Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/3en4all/3en-command-runner/main/3en-agent-runner-v3.10.1.ps1' -OutFile $runner}
Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,'-ProjectPath','project-security-privacy-stack-v1.json') -WorkingDirectory $root|Out-Null
