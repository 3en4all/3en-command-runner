$ErrorActionPreference='Stop'
$root='C:\3EN-Agent'
$needle='058a8'
$maxFiles=40
Write-Host '=== 058A8 LOCAL EVIDENCE START ==='
Write-Host ('HOST='+$env:COMPUTERNAME)
Write-Host ('UTC='+[DateTimeOffset]::UtcNow.ToString('o'))

$roots=@(
  "$root\runs",
  "$root\workbench\plugin-acceptance-058a8",
  "$root\results",
  "$root\logs"
) | Where-Object { Test-Path $_ }

Write-Host ('ROOTS='+($roots -join ';'))
$files=@()
foreach($r in $roots){
  try {
    $files += Get-ChildItem -LiteralPath $r -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '058a8|output|transcript|acceptance|evidence|result|log' -or $_.FullName -match '058a8' }
  } catch {}
}
$files=$files | Sort-Object LastWriteTime -Descending -Unique | Select-Object -First $maxFiles
Write-Host ('CANDIDATE_COUNT='+@($files).Count)
foreach($f in $files){ Write-Host ('FILE='+$f.FullName+' | '+$f.Length+' | '+$f.LastWriteTime.ToString('o')) }

$patterns='058A8_|RUNNER_EXIT|ERROR|FAILED|TIMEOUT|PHASE|gateway|npm|openclaw|3en_job'
foreach($f in $files){
  if($f.Length -gt 8MB){ continue }
  try {
    $hits=Select-String -LiteralPath $f.FullName -Pattern $patterns -CaseSensitive:$false -ErrorAction SilentlyContinue | Select-Object -Last 80
    if($hits){
      Write-Host ('--- EVIDENCE_FILE '+$f.FullName+' ---')
      foreach($h in $hits){ Write-Host ($h.LineNumber.ToString()+': '+$h.Line) }
    }
  } catch {}
}

$pe="$root\workbench\plugin-acceptance-058a8\process-evidence"
if(Test-Path $pe){
  Write-Host '=== PROCESS EVIDENCE ==='
  Get-ChildItem -LiteralPath $pe -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | ForEach-Object {
    Write-Host ('--- '+$_.FullName+' ---')
    try { Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop | Write-Host } catch { Write-Host ('READ_ERROR='+$_.Exception.Message) }
  }
}

$acc="$root\workbench\plugin-acceptance-058a8\acceptance.json"
if(Test-Path $acc){ Write-Host '=== ACCEPTANCE ==='; Get-Content -LiteralPath $acc -Raw | Write-Host }
Write-Host '=== 058A8 LOCAL EVIDENCE END ==='
