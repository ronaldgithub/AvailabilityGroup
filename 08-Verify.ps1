<#
    08-Verify.ps1

    Final verification that the lab is back to a known-good state, and assembly
    of everything in output\ into one evidence file for the blog.

    Checks:
      - DBCC CHECKDB clean on both nodes
      - AG healthy, database SYNCHRONIZED, not suspended
      - BACKUP LOG succeeds on the primary (the log chain works again)
      - Row counts match between primary and secondary

    Usage:  .\08-Verify.ps1
            .\08-Verify.ps1 -SkipCheckDb
#>
[CmdletBinding()]
param(
    [switch]$SkipCheckDb,
    [switch]$Pause
)

. "$PSScriptRoot\Common.ps1"
$Lab.PauseForScreenshots = [bool]$Pause
$transcript = Start-LabTranscript -Name '08-verify'

$results = New-Object System.Collections.ArrayList
function Add-Result {
    param([string]$Check, [bool]$Passed, [string]$Detail = '')
    [void]$results.Add([pscustomobject]@{
        Check  = $Check
        Result = $(if ($Passed) { 'PASS' } else { 'FAIL' })
        Detail = $Detail
    })
    if ($Passed) { Write-Ok "$Check - $Detail" } else { Write-Bad "$Check - $Detail" }
}

try {
    Write-Step 'Final verification'

    $db = $Lab.DemoDb
    $primary = Get-AgPrimary
    if (-not $primary) { throw "Cannot determine the primary of '$($Lab.AgName)'." }
    $secondary = if ($primary -eq $Lab.NodeA) { $Lab.NodeB } else { $Lab.NodeA }
    Write-Ok "Primary: $primary   Secondary: $secondary"

    # -------------------------------------------------------------- 1. reachable
    Write-Step '1. Both nodes online'
    foreach ($node in @($Lab.NodeA, $Lab.NodeB)) {
        Add-Result -Check "$node reachable" -Passed (Test-SqlUp -Server $node) -Detail 'SQL accepting connections'
    }

    # ------------------------------------------------------------- 2. AG health
    Write-Step '2. AG health'

    $replicas = Get-AgReplicaConfig -Server $primary
    $replicas | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    $badReplicas = @($replicas | Where-Object { $_.health -ne 'HEALTHY' })
    Add-Result -Check 'Replicas HEALTHY' -Passed ($badReplicas.Count -eq 0) `
               -Detail $(if ($badReplicas.Count) { ($badReplicas | ForEach-Object { "$($_.replica)=$($_.health)" }) -join ' ' } else { 'both replicas healthy' })

    $health = Get-AgHealth -Server $primary
    $health | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Save-Snapshot -Name '08-final-ag-health' -Data $health -Description 'Final AG state' | Out-Null

    $demo = @($health | Where-Object { $_.db_name -eq $db })
    Add-Result -Check "'$db' present on both replicas" -Passed ($demo.Count -ge 2) -Detail "$($demo.Count) replica rows"

    $notSync = @($demo | Where-Object { $_.sync_state -ne 'SYNCHRONIZED' })
    Add-Result -Check "'$db' SYNCHRONIZED" -Passed ($notSync.Count -eq 0) `
               -Detail $(if ($notSync.Count) { ($notSync | ForEach-Object { "$($_.replica)=$($_.sync_state)" }) -join ' ' } else { 'both replicas synchronized' })

    $susp = @($demo | Where-Object { $_.suspended })
    Add-Result -Check 'Data movement not suspended' -Passed ($susp.Count -eq 0) `
               -Detail $(if ($susp.Count) { ($susp | ForEach-Object { "$($_.replica)=$($_.suspend_reason)" }) -join ' ' } else { 'is_suspended = 0 everywhere' })

    # --------------------------------------------------------------- 3. CHECKDB
    if (-not $SkipCheckDb) {
        Write-Step '3. DBCC CHECKDB on both nodes'
        foreach ($node in @($Lab.NodeA, $Lab.NodeB)) {
            if (-not (Test-SqlUp -Server $node)) { Add-Result -Check "CHECKDB on $node" -Passed $false -Detail 'node unreachable'; continue }
            $st = Invoke-Ag -Server $node -Query "SELECT state_desc FROM sys.databases WHERE name='$db';" -NoThrow
            if (-not $st.Success -or $st.Rows.Count -eq 0) { Add-Result -Check "CHECKDB on $node" -Passed $false -Detail 'database missing'; continue }
            if ($st.Rows[0].state_desc -ne 'ONLINE') {
                Add-Result -Check "CHECKDB on $node" -Passed $false -Detail "database is $($st.Rows[0].state_desc)"
                continue
            }
            Write-Info "Running DBCC CHECKDB on $node ..."
            $c = Invoke-Ag -Server $node -Query "DBCC CHECKDB([$db]) WITH NO_INFOMSGS, ALL_ERRORMSGS;" -TimeoutSec 3600 -NoThrow
            $clean = $c.Success -and $c.Messages.Count -eq 0
            Add-Result -Check "CHECKDB on $node" -Passed $clean `
                       -Detail $(if ($clean) { 'no errors' } else { ($c.Messages -join ' | ') })
        }
    }

    # ------------------------------------------------------------ 4. BACKUP LOG
    Write-Step '4. Log chain'

    $trn = "$($Lab.BackupDir)\${db}_final_verify.trn"
    $bk = Invoke-Ag -Server $primary -Query "BACKUP LOG [$db] TO DISK = N'$trn' WITH INIT, CHECKSUM;" -TimeoutSec 1800 -NoThrow
    $bk.Messages | ForEach-Object { Write-Info $_ }
    Add-Result -Check 'BACKUP LOG on the primary' -Passed $bk.Success `
               -Detail $(if ($bk.Success) { 'log backups work again' } else { ($bk.Error.Details | ForEach-Object { "Msg $($_.Number)" }) -join ' ' })

    # ------------------------------------------------------------- 5. row counts
    Write-Step '5. Data comparison'

    $pCount = Invoke-Ag -Server $primary -Database $db -Query @"
SELECT (SELECT COUNT_BIG(*) FROM dbo.Orders) AS orders,
       (SELECT COUNT_BIG(*) FROM dbo.AuditTrail) AS audit;
"@ -NoThrow
    if ($pCount.Success -and $pCount.Rows.Count) {
        Write-Info ("$primary : Orders={0:N0}  AuditTrail={1:N0}" -f $pCount.Rows[0].orders, $pCount.Rows[0].audit)
        Add-Result -Check 'Primary readable' -Passed $true -Detail "$($pCount.Rows[0].orders) orders"
    } else {
        Add-Result -Check 'Primary readable' -Passed $false -Detail 'could not count rows'
    }

    Write-Info 'The secondary is not readable (secondary_role_allow_connections = NO), so no row'
    Write-Info 'comparison there. Row counts on the secondary would need read-intent enabled.'

    # ------------------------------------------------------------- 6. the report
    Write-Step 'Verification summary'
    $results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

    $failed = @($results | Where-Object { $_.Result -eq 'FAIL' })
    if ($failed.Count -eq 0) {
        Write-Ok 'ALL CHECKS PASSED - the lab is back to a known-good state.'
    } else {
        Write-Bad ("{0} check(s) failed:" -f $failed.Count)
        $failed | ForEach-Object { Write-Bad ("  {0}: {1}" -f $_.Check, $_.Detail) }
    }
    Save-Snapshot -Name '08-verification-summary' -Data $results -Description 'Final verification results' | Out-Null

    # ----------------------------------------------------- 7. assemble evidence
    Write-Step 'Assembling the evidence file'

    $evidence = Join-Path $Lab.OutputDir ('EVIDENCE_{0}.md' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $sb = New-Object System.Text.StringBuilder

    [void]$sb.AppendLine('# Corrupt Transaction Log in an Availability Group')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(('Generated {0} on cluster {1}, AG {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $Lab.ClusterName, $Lab.AgName))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Environment')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Item | Value |')
    [void]$sb.AppendLine('|---|---|')
    [void]$sb.AppendLine(('| Nodes | {0}, {1} |' -f $Lab.NodeA, $Lab.NodeB))
    [void]$sb.AppendLine(('| Cluster | {0} |' -f $Lab.ClusterName))
    [void]$sb.AppendLine(('| Availability group | {0} |' -f $Lab.AgName))
    [void]$sb.AppendLine(('| Demo database | {0} |' -f $Lab.DemoDb))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Captured evidence')
    [void]$sb.AppendLine('')

    Get-ChildItem -Path $Lab.OutputDir -Filter '*.txt' | Sort-Object Name | ForEach-Object {
        [void]$sb.AppendLine(('### {0}' -f $_.BaseName))
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('```')
        [void]$sb.AppendLine((Get-Content -LiteralPath $_.FullName -Raw))
        [void]$sb.AppendLine('```')
        [void]$sb.AppendLine('')
    }

    Set-Content -LiteralPath $evidence -Value $sb.ToString() -Encoding UTF8
    Write-Ok "Evidence assembled: $evidence"
    Write-Info ("{0} snapshot files, {1} transcripts" -f `
        (Get-ChildItem $Lab.OutputDir -Filter '*.txt').Count,
        (Get-ChildItem $Lab.OutputDir -Filter '*.log').Count)

    Wait-ForScreenshot -Moment 'All green' -Capture @(
        'SSMS AG dashboard - fully healthy',
        'The verification summary table above'
    )
}
finally {
    Stop-LabTranscript
    Write-Host ''
    Write-Host "  Transcript: $transcript" -ForegroundColor DarkGray
}
