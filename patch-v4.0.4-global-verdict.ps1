param([string]$Source,[string]$Destination)
$ErrorActionPreference='Stop'
if(-not(Test-Path $Source)){throw 'SOURCE_MISSING'}
$c=Get-Content -LiteralPath $Source -Raw -Encoding UTF8
$old='$accepted = (-not $mismatch -and $remaining -eq 0)'
$new='$accepted = (-not $mismatch -and $remaining -eq 0 -and $counts.failed -eq 0 -and $counts.blocked -eq 0)'
if(-not $c.Contains($old)){throw 'ACCEPTED_EXPRESSION_NOT_FOUND'}
$c=$c.Replace($old,$new)
$c=$c.Replace('v4.0.3','v4.0.4')
$c=$c.Replace('v403','v404')
Set-Content -LiteralPath $Destination -Value $c -Encoding UTF8
$t=$null;$e=$null;[System.Management.Automation.Language.Parser]::ParseFile($Destination,[ref]$t,[ref]$e)|Out-Null
if(@($e).Count -gt 0){throw ('V404_SYNTAX_ERRORS='+@($e).Count)}
Write-Output 'V404_GLOBAL_VERDICT_PATCH=PASS'
