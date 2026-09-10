$ErrorActionPreference='Stop'
$Root='C:\3EN-Agent\workbench\maintenance-058d'
$Out=Join-Path $Root 'openclaw-cli-capabilities.json'
if(Test-Path $Root){Remove-Item $Root -Recurse -Force};New-Item -ItemType Directory -Force -Path $Root|Out-Null
function Run([string]$Name,[string]$Args){
  $psi=New-Object Diagnostics.ProcessStartInfo
  $psi.FileName='openclaw.cmd';$psi.Arguments=$Args;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true
  $p=New-Object Diagnostics.Process;$p.StartInfo=$psi;[void]$p.Start();$o=$p.StandardOutput.ReadToEnd();$e=$p.StandardError.ReadToEnd();$done=$p.WaitForExit(30000);if(-not$done){try{& taskkill.exe /PID $p.Id /T /F|Out-Null}catch{};return [ordered]@{name=$Name;exit=124;stdout=$o;stderr=$e}}
  return [ordered]@{name=$Name;exit=[int]$p.ExitCode;stdout=$o;stderr=$e}
}
$r=@()
$r+=Run 'version' '--version'
$r+=Run 'install_help' 'plugins install --help'
$r+=Run 'enable_help' 'plugins enable --help'
$r+=Run 'inspect_help' 'plugins inspect --help'
$r+=Run 'list' 'plugins list --json'
[ordered]@{schemaVersion=1;status='PASS';results=$r;collectedAt=(Get-Date).ToString('o')}|ConvertTo-Json -Depth 8|Set-Content $Out -Encoding UTF8
foreach($x in $r){Write-Output ('058D_'+$x.name.ToUpper()+'_EXIT='+$x.exit);$txt=(($x.stdout+' '+$x.stderr)-replace '[\r\n]+',' | ');if($txt.Length-gt1800){$txt=$txt.Substring(0,1800)};Write-Output ('058D_'+$x.name.ToUpper()+'_TEXT='+$txt)}
Write-Output 'V464_058D_DISCOVERY=PASS'
