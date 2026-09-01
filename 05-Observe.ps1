<#
    05-Observe.ps1

    Captures what the corruption actually did: database state, AG health, the
    failing (or succeeding) log backup, DBCC CHECKDB, and the error log entries
    from both nodes.

    Deliberately includes DBCC CHECKDB, because it comes back CLEAN even with a
    wrecked log - CHECKDB validates data pages, not the transaction log. That is
    one of the more useful things this lab demonstrates.

    Usage:  .\05-Observe.ps1
            .\05-Observe.ps1 -Pause -Label act1
#>
[CmdletBinding()]
param(
    [string]$Label = 'act1',
    [switch]$SkipCheckDb,
    [switch]$Pause
)

. "$PSScriptRoot\Common.ps1"
$Lab.PauseForScreenshots = [bool]$Pause
$transcript = Start-LabTranscript -Name "05-observe-$Label"

try {
    Write-Step "Observing the damage - $Label"

    $db = $Lab.DemoDb
    $primary = Get-AgPrimary
    if (-not $primary) {
        Write-Bad "No primary replica found for '$($Lab.AgName)'."
        $primary = $Lab.NodeA
    }
    $secondary = if ($primary -eq $Lab.NodeA) { $Lab.NodeB } else { $Lab.NodeA }
    Write-Ok "Primary: $primary   Secondary: $secondary"

    # ------------------------------------------------------- 1. database state
    Write-Step '1. Database state on both nodes'

    $states = @()
    foreach ($node in @($Lab.NodeA, $Lab.NodeB)) {
        if (-not (Test-SqlUp -Server $node)) {
            Write-Bad "$node is not reachable"
            continue
        }
        $r = Invoke-Ag -Server $node -Query @"
SELECT '$node' AS node, name, state_desc, recovery_model_desc,
       log_reuse_wait_desc, is_read_only
FROM sys.databases WHERE name = '$db';
"@ -NoThrow
        if ($r.Success -and $r.Rows.Count) { $states += $r.Rows }
        elseif ($r.Success) { Write-Warn "'$db' does not exist on $node" }
    }
    $states | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Save-Snapshot -Name "05-$Label-database-state" -Data $states -Description 'sys.databases on both nodes after the corruption' | Out-Null

    # -------------------------------------------------------------- 2. AG state
    Write-Step '2. AG state'

    $health = Get-AgHealth -Server $primary
    $health | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Save-Snapshot -Name "05-$Label-ag-health" -Data $health -Description 'AG per-database state after the corruption' | Out-Null

    $demoRows = @($health | Where-Object { $_.db_name -eq $db })
    $allHealthy = ($demoRows.Count -gt 0) -and (@($demoRows | Where-Object { $_.sync_health -ne 'HEALTHY' }).Count -eq 0)
    if ($allHealthy) {
        Write-Warn 'The AG reports HEALTHY. The log is damaged and Always On has not noticed -'
        Write-Warn 'the log reader only moves forward, so it never re-reads the corrupted region.'
    } else {
        Write-Info 'The AG is reporting a problem - details in the table above.'
    }

    # ------------------------------------------------------------ 3. BACKUP LOG
    Write-Step '3. BACKUP LOG - this is where surgical log corruption surfaces'

    $trn = "$($Lab.BackupDir)\${db}_${Label}.trn"
    $sql = "BACKUP LOG [$db] TO DISK = N'$trn' WITH INIT, CHECKSUM, STATS = 25;"
    Write-Info $sql

    $bk = Invoke-Ag -Server $primary -Query $sql -TimeoutSec 1800 -NoThrow
    $bk.Messages | ForEach-Object { Write-Info $_ }

    $backupReport = New-Object System.Collections.ArrayList
    if ($bk.Success) {
        Write-Ok 'BACKUP LOG SUCCEEDED'
        [void]$backupReport.Add('BACKUP LOG SUCCEEDED')
        $bk.Messages | ForEach-Object { [void]$backupReport.Add($_) }
    } else {
        Write-Bad 'BACKUP LOG FAILED'
        [void]$backupReport.Add('BACKUP LOG FAILED')
        foreach ($d in $bk.Error.Details) {
            $line = "Msg {0}, Level {1}, State {2} : {3}" -f $d.Number, $d.Severity, $d.State, $d.Message
            Write-Bad "  $line"
            [void]$backupReport.Add($line)
        }
        $numbers = @($bk.Error.Details | Select-Object -ExpandProperty Number)
        if ($numbers -contains 9004) { Write-Ok 'Error 9004 - "An error occurred while processing the log". Textbook result.' }
        if ($numbers -contains 9001) { Write-Ok 'Error 9001 - "The log for the database is not available".' }
        if ($numbers -contains 5172 -or $numbers -contains 9003) { Write-Ok 'Header-level damage (5172 / 9003).' }
    }
    Save-Snapshot -Name "05-$Label-backup-log-result" -Data ($backupReport -join [Environment]::NewLine) `
        -Description "Result of BACKUP LOG on $primary after the corruption" | Out-Null

    Wait-ForScreenshot -Moment 'The failing log backup' -Capture @(
        'The Msg 9004 / 9001 text above',
        'Or run the same BACKUP LOG in SSMS to get the error in the Messages pane - better for a blog'
    )

    # -------------------------------------------------------------- 4. CHECKDB
    if (-not $SkipCheckDb) {
        Write-Step '4. DBCC CHECKDB - expected to come back CLEAN'
        Write-Info 'CHECKDB validates data pages. It does not read the transaction log.'
        Write-Info 'A clean CHECKDB on a database with a wrecked log is exactly the point.'

        $dbccOut = New-Object System.Collections.ArrayList
        foreach ($node in @($Lab.NodeA, $Lab.NodeB)) {
            if (-not (Test-SqlUp -Server $node)) { continue }
            $exists = Invoke-Ag -Server $node -Query "SELECT state_desc FROM sys.databases WHERE name='$db';" -NoThrow
            if (-not $exists.Success -or $exists.Rows.Count -eq 0) { continue }
            if ($exists.Rows[0].state_desc -ne 'ONLINE') {
                Write-Warn "$node : '$db' is $($exists.Rows[0].state_desc) - CHECKDB cannot run"
                [void]$dbccOut.Add("$node : skipped, database is $($exists.Rows[0].state_desc)")
                continue
            }

            Write-Info "Running DBCC CHECKDB on $node ..."
            $c = Invoke-Ag -Server $node -Query "DBCC CHECKDB([$db]) WITH NO_INFOMSGS, ALL_ERRORMSGS;" -TimeoutSec 3600 -NoThrow
            if ($c.Success) {
                if ($c.Messages.Count -eq 0) {
                    Write-Ok "$node : CHECKDB clean - no errors"
                    [void]$dbccOut.Add("$node : CHECKDB clean (no output = no corruption in the data files)")
                } else {
                    $c.Messages | ForEach-Object { Write-Warn "  $_"; [void]$dbccOut.Add("$node : $_") }
                }
            } else {
                Write-Bad "$node : CHECKDB failed - $($c.Error.Message)"
                [void]$dbccOut.Add("$node : CHECKDB failed - $($c.Error.Message)")
            }
        }
        Save-Snapshot -Name "05-$Label-checkdb" -Data ($dbccOut -join [Environment]::NewLine) `
            -Description 'DBCC CHECKDB on both nodes - clean data pages despite the damaged log' | Out-Null
    }

    # ------------------------------------------------------------- 5. log info
    Write-Step '5. Log state'

    $loginfo = Invoke-Ag -Server $primary -Database $db -Query @"
SELECT COUNT(*) AS total_vlfs,
       SUM(CASE WHEN vlf_status = 2 THEN 1 ELSE 0 END) AS active_vlfs,
       MIN(vlf_sequence_number) AS min_seq, MAX(vlf_sequence_number) AS max_seq
FROM sys.dm_db_log_info(DB_ID('$db'));
"@ -NoThrow
    if ($loginfo.Success) {
        $loginfo.Rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
        Save-Snapshot -Name "05-$Label-log-info" -Data $loginfo.Rows -Description 'VLF summary after the corruption' | Out-Null
    } else {
        Write-Warn "sys.dm_db_log_info failed: $($loginfo.Error.Message)"
    }

    # -------------------------------------------------------- 6. the error logs
    Write-Step '6. SQL Server error log on both nodes'

    foreach ($node in @($Lab.NodeA, $Lab.NodeB)) {
        if (-not (Test-SqlUp -Server $node)) { Write-Bad "$node unreachable"; continue }
        Write-Host ''
        Write-Host "  --- $node ---" -ForegroundColor Cyan

        $interesting = @()
        foreach ($filter in @($db, 'error', 'Always On')) {
            $lines = Get-SqlErrorLogTail -Server $node -Filter $filter -Last 15
            $interesting += $lines
        }
        $interesting = $interesting |
            Sort-Object -Property LogDate -Unique |
            Select-Object -Last 25

        if ($interesting.Count) {
            $interesting | ForEach-Object { Write-Host ("    {0}  {1}" -f $_.LogDate, $_.Text) -ForegroundColor Gray }
            Save-Snapshot -Name "05-$Label-errorlog-$node" -Data $interesting -Description "Error log excerpts from $node" | Out-Null
        } else {
            Write-Info '  (nothing matched)'
        }
    }

    Write-Step "Observation complete - $Label"
    Write-Ok 'Next: .\06-Failover.ps1'
}
finally {
    Stop-LabTranscript
    Write-Host ''
    Write-Host "  Transcript: $transcript" -ForegroundColor DarkGray
}
