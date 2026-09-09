$ErrorActionPreference='Stop'
param([string]$Source,[string]$Destination)
if(-not(Test-Path $Source)){throw 'SOURCE_MISSING'}
$c=Get-Content -LiteralPath $Source -Raw -Encoding UTF8
$old=@'
        if ($null -ne $existing -and (Test-Terminal ([string]$existing.status))) {
            Write-Log ('RESUME SKIP ' + $id + ' status=' + [string]$existing.status)
            continue
        }
'@
$new=@'
        if ($null -ne $existing -and (Test-Terminal ([string]$existing.status))) {
            $resumeStatus = [string]$existing.status
            Write-Log ('RESUME SKIP ' + $id + ' status=' + $resumeStatus)
            if ($resumeStatus -eq 'SUCCESS') { $counts.success++ }
            elseif ($resumeStatus -eq 'SUCCESS_RECOVERED') { $counts.recovered++ }
            elseif ($resumeStatus -eq 'REJECTED') { $counts.rejected++ }
            elseif ($resumeStatus -eq 'FAILED') { $counts.failed++ }
            elseif ($resumeStatus -eq 'BLOCKED') { $counts.blocked++ }
            if ($expected -ne $resumeStatus) { $mismatch = $true }
            continue
        }
'@
if(-not $c.Contains($old)){throw 'RESUME_BLOCK_NOT_FOUND'}
$c=$c.Replace($old,$new)
$c=$c.Replace('v4.0.2','v4.0.3')
$c=$c.Replace('v402','v403')
Set-Content -LiteralPath $Destination -Value $c -Encoding UTF8
$t=$null;$e=$null;[System.Management.Automation.Language.Parser]::ParseFile($Destination,[ref]$t,[ref]$e)|Out-Null
if(@($e).Count -gt 0){throw ('PATCHED_RUNNER_SYNTAX_ERRORS='+@($e).Count)}
Write-Output 'V403_PATCH=PASS'
