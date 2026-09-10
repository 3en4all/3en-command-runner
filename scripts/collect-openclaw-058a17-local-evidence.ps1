$ErrorActionPreference='Stop'
$root='C:\3EN-Agent'
Write-Host '=== 058A17_LOCAL_EVIDENCE_START ==='
$roots=@("$root\runs","$root\workbench\plugin-acceptance-058a17","$root\results")|Where-Object{Test-Path $_}
$files=@()
foreach($r in $roots){$files+=Get-ChildItem -LiteralPath $r -Recurse -File -ErrorAction SilentlyContinue|Where-Object{$_.FullName -match '058a17' -or $_.Name -match 'output|transcript|result|acceptance'}}
$files=$files|Sort-Object LastWriteTime -Descending -Unique|Select-Object -First 25
Write-Host ('FILES='+@($files).Count)
foreach($f in $files){
 Write-Host ('FILE='+$f.FullName)
 if($f.Length -lt 6MB){
  $h=Select-String -LiteralPath $f.FullName -Pattern '058A17','ERROR','FAILED','TIMEOUT','ROLLBACK','PROJECT NEEDS DECISION' -SimpleMatch -ErrorAction SilentlyContinue|Select-Object -Last 60
  foreach($x in $h){Write-Host ($x.LineNumber.ToString()+': '+$x.Line)}
 }
}
Write-Host '=== 058A17_LOCAL_EVIDENCE_END ==='
