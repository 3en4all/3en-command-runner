$ErrorActionPreference='Continue'
Write-Host '=== NP009_BRIDGE_HANDLER_EVIDENCE_START ==='
$bridge='C:\3EN-Agent\security-monitor-integration\3en-security-monitor-bridge-v1.py'
Write-Host ('BRIDGE_EXISTS='+(Test-Path $bridge))
try{
  $o=& curl.exe -sS --max-time 3 -w "`nCURL_HTTP=%{http_code};CURL_TIME=%{time_total}" http://127.0.0.1:8766/api/status 2>&1
  Write-Host ('CURL_EXIT='+$LASTEXITCODE);$o|ForEach-Object{Write-Host $_}
}catch{Write-Host ('CURL_EXCEPTION='+$_.Exception.Message)}
if(Test-Path $bridge){
  $lines=Get-Content -LiteralPath $bridge
  $keys=@('def status_payload','def run_ssh','subprocess','paramiko','timeout','/api/status','routerSsh')
  foreach($k in $keys){
    $hits=Select-String -LiteralPath $bridge -Pattern $k -SimpleMatch -ErrorAction SilentlyContinue
    foreach($h in $hits){
      $s=[Math]::Max(0,$h.LineNumber-8);$e=[Math]::Min($lines.Count-1,$h.LineNumber+24)
      Write-Host ('--- CONTEXT '+$k+' line '+$h.LineNumber+' ---')
      for($i=$s;$i-le$e;$i++){Write-Host (($i+1).ToString()+': '+$lines[$i])}
    }
  }
}
Write-Host '=== NP009_BRIDGE_HANDLER_EVIDENCE_END ==='
