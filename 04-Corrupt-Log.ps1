<#
    04-Corrupt-Log.ps1

    Physically corrupts the transaction log of LogCorruptDemo on one node.

    -Mode Surgical   Clean service shutdown, then overwrite ~4 KB deep inside an
                     *older active* VLF - one written AFTER the last log backup
                     (so the next BACKUP LOG must read it), already hardened on
                     the secondary, but not the VLF the engine is writing to and
                     not needed by crash recovery.
                     Expected: database comes ONLINE, BACKUP LOG fails 9004/9001.

    -Mode Header     Leave an uncommitted transaction open, hard-kill sqlservr so
                     recovery has real work to do, then zero the first 8 KB of
                     the .ldf.
                     Expected: recovery fails, database RECOVERY_PENDING/SUSPECT,
                     errors 5172/9003.

    Every run takes a byte-for-byte side copy of the .ldf first, so any act can be
    undone with -Rollback without rebuilding the lab.

    Usage:  .\04-Corrupt-Log.ps1 -Mode Surgical
            .\04-Corrupt-Log.ps1 -Mode Header -TargetNode sql5
            .\04-Corrupt-Log.ps1 -Rollback -TargetNode sql4

    Author: Ronald.de.Groot@OpenData.nl and Claude Code
#>
[CmdletBinding()]
param(
    [ValidateSet('Surgical', 'Header')][string]$Mode = 'Surgical',
    [string]$TargetNode,
    [int]$PatchBytes = 4096,
    [switch]$Rollback,
    [switch]$Pause,
    [switch]$Force
)

. "$PSScriptRoot\Common.ps1"
$Lab.PauseForScreenshots = [bool]$Pause
$transcript = Start-LabTranscript -Name "04-corrupt-$($Mode.ToLower())"

# ------------------------------------------------------------------ scriptblocks
$sbPatch = {
    param($Path, $Offset, $Length, $Fill)
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $before = New-Object byte[] 64
        [void]$fs.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        [void]$fs.Read($before, 0, 64)

        $bytes = New-Object byte[] $Length
        if ($Fill -eq 'zero') {
            # leave the buffer as zeros
        } else {
            $pattern = [System.Text.Encoding]::ASCII.GetBytes('CORRUPT!')
            for ($i = 0; $i -lt $Length; $i++) { $bytes[$i] = $pattern[$i % $pattern.Length] }
        }

        [void]$fs.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $fs.Write($bytes, 0, $Length)
        $fs.Flush($true)

        $after = New-Object byte[] 64
        [void]$fs.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        [void]$fs.Read($after, 0, 64)

        [pscustomobject]@{
            Path      = $Path
            Offset    = $Offset
            Length    = $Length
            BeforeHex = ($before | ForEach-Object { $_.ToString('X2') }) -join ' '
            AfterHex  = ($after  | ForEach-Object { $_.ToString('X2') }) -join ' '
            FileSize  = $fs.Length
        }
    }
    finally { $fs.Dispose() }
}

try {
    $mode = $Mode

    # ---------------------------------------------------------------- 1. target
    Write-Step "Corrupt transaction log - mode: $mode"

    $db = $Lab.DemoDb
    $primary = Get-AgPrimary
    if (-not $TargetNode) { $TargetNode = $primary }
    Write-Ok "AG primary: $primary"
    Write-Ok "Target node: $TargetNode"

    $logRow = @(Get-DbFile -Server $TargetNode -DbName $db -Type LOG)
    if (-not $logRow -or $logRow.Count -eq 0) { throw "Cannot resolve the log file for '$db' on $TargetNode." }
    $ldf = $logRow[0].physical_name
    Write-Ok "Log file: $ldf ($([math]::Round($logRow[0].size_mb,1)) MB)"

    $pristine = Join-Path $Lab.BackupDir ("{0}_log.ldf.pristine" -f $db)

    # ------------------------------------------------------------- 2. rollback?
    if ($Rollback) {
        Write-Step 'Rollback - restoring the pristine log file'
        $hasCopy = Invoke-OnNode -Node $TargetNode -ScriptBlock { param($p) Test-Path -LiteralPath $p } -ArgumentList $pristine
        if (-not $hasCopy) { throw "No pristine copy at $pristine on $TargetNode." }

        $policy = Suspend-AgClusterFailover
        try {
            Write-Info "Stopping $($Lab.Service) on $TargetNode"
            Invoke-OnNode -Node $TargetNode -ArgumentList @($Lab.Service) -ScriptBlock {
                param($s) Stop-Service -Name $s -Force
            }
            Invoke-OnNode -Node $TargetNode -ArgumentList @($pristine, $ldf) -ScriptBlock {
                param($src, $dst) Copy-Item -LiteralPath $src -Destination $dst -Force
            }
            Write-Ok 'Pristine log file restored'
            Invoke-OnNode -Node $TargetNode -ArgumentList @($Lab.Service) -ScriptBlock {
                param($s) Start-Service -Name $s
            }
            $null = Wait-SqlUp -Server $TargetNode -TimeoutSec 300
        }
        finally { Restore-AgClusterFailover -Policy $policy }

        $state = Invoke-Ag -Server $TargetNode -Query "SELECT name, state_desc FROM sys.databases WHERE name = '$db';" -NoThrow
        if ($state.Success) { $state.Rows | Format-Table -AutoSize | Out-String | Write-Host }
        return
    }

    # ------------------------------------------------------------ 3. preflight
    Write-Step '1. Preflight - the corrupted region must already be hardened on the secondary'

    $health = @(Get-AgHealth -Server $primary | Where-Object { $_.db_name -eq $db })
    $health | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

    $notSync = @($health | Where-Object { $_.sync_state -ne 'SYNCHRONIZED' })
    if ($notSync.Count -gt 0 -and -not $Force) {
        throw "'$db' is not SYNCHRONIZED on both replicas. Corrupting now could make the failover impossible. Use -Force to override."
    }

    $queued = @($health | Where-Object { $_.log_send_kb -gt 0 })
    if ($queued.Count -gt 0) {
        Write-Warn ("Log send queue is not empty: {0}" -f (($queued | ForEach-Object { "$($_.replica)=$($_.log_send_kb)KB" }) -join ' '))
        Write-Info 'A small idle queue is normal; anything large means log has not reached the secondary yet.'
    } else {
        Write-Ok 'Log send queue is empty on both replicas.'
    }

    $secondary = if ($TargetNode -eq $Lab.NodeA) { $Lab.NodeB } else { $Lab.NodeA }
    $hardened = $health | Where-Object { $_.replica -eq $secondary } | Select-Object -First 1
    if ($hardened) { Write-Ok "last_hardened_lsn on $secondary : $($hardened.last_hardened_lsn)" }

    Save-Snapshot -Name "04-$mode-preflight-health" -Data $health -Description "AG state immediately before the $mode corruption" | Out-Null

    # -------------------------------------------------- 4. choose the VLF target
    $offset = 0
    $vlfInfo = $null

    if ($mode -eq 'Surgical') {
        Write-Step '2. Choosing the VLF to corrupt'
        Write-Info 'Must be: active, written AFTER the last log backup (so BACKUP LOG reads it),'
        Write-Info 'NOT the VLF currently being written to, and OUTSIDE the crash-recovery range.'

        # A CHECKPOINT advances log_recovery_lsn towards the tail, which shrinks the
        # range redo has to read on the next startup. Without it an AG database can
        # come back with tens of seconds of redo work - the database is started by
        # the availability group, not by normal startup recovery - and if the damaged
        # VLF falls inside that range, recovery fails 3414 and the database goes
        # SUSPECT instead of quietly coming ONLINE with a broken log chain.
        $null = Invoke-Ag -Server $TargetNode -Database $db -Query 'CHECKPOINT;'
        Write-Info 'CHECKPOINT issued - pulls the recovery start point towards the tail'

        $pick = @(Invoke-Ag -Server $TargetNode -Database $db -Query @"
DECLARE @lastBackupVlf bigint = (
    SELECT TOP 1 FLOOR(last_lsn / 1000000000000000.0)
    FROM msdb.dbo.backupset
    WHERE database_name = '$db' AND type = 'L'
    ORDER BY backup_finish_date DESC);

DECLARE @currentVlf bigint = (
    SELECT MAX(vlf_sequence_number) FROM sys.dm_db_log_info(DB_ID('$db')) WHERE vlf_status = 2);

-- log_recovery_lsn is nvarchar in 'hhhhhhhh:hhhhhhhh:hhhh' form, NOT the numeric
-- LSN backupset uses - so the VLF comes from the first hex group, not a division.
DECLARE @recoveryVlf bigint = (
    SELECT CONVERT(bigint, CONVERT(varbinary(4), '0x' + LEFT(log_recovery_lsn, 8), 1))
    FROM sys.dm_db_log_stats(DB_ID('$db')));

SELECT TOP 1
    vlf_sequence_number AS seq,
    vlf_begin_offset    AS offset_bytes,
    CAST(vlf_size_mb AS decimal(10,2)) AS size_mb,
    vlf_first_lsn,
    ISNULL(@lastBackupVlf, -1) AS last_backup_vlf,
    @currentVlf   AS current_write_vlf,
    @recoveryVlf  AS recovery_start_vlf
FROM sys.dm_db_log_info(DB_ID('$db'))
WHERE vlf_status = 2
  AND vlf_sequence_number > ISNULL(@lastBackupVlf, 0)
  AND vlf_sequence_number < @currentVlf
  AND vlf_sequence_number < ISNULL(@recoveryVlf, @currentVlf)
ORDER BY vlf_sequence_number ASC;
"@)
        if (-not $pick -or $pick.Count -eq 0) {
            throw "No suitable VLF found. Need an active VLF written after the last log backup, below the current write VLF, and below the crash-recovery start VLF - re-run 03-Generate-Load.ps1 with more -ChurnBatches."
        }
        $vlfInfo = $pick[0]
        Write-Ok ("Chosen VLF seq {0} at byte offset {1:N0} ({2} MB)" -f $vlfInfo.seq, $vlfInfo.offset_bytes, $vlfInfo.size_mb)
        Write-Info ("  last log backup ended in VLF {0}, engine is writing to VLF {1}" -f $vlfInfo.last_backup_vlf, $vlfInfo.current_write_vlf)
        Write-Info ("  crash recovery would start at VLF {0} - the target is below it" -f $vlfInfo.recovery_start_vlf)
        Write-Info ("  first LSN in this VLF: {0}" -f $vlfInfo.vlf_first_lsn)
        Write-Info '  the next BACKUP LOG must read this VLF - that is what makes it fail'

        # +8192 clears the VLF's own header and lands in log-record territory
        $offset = [int64]$vlfInfo.offset_bytes + 8192
        Save-Snapshot -Name '04-surgical-vlf-choice' -Data $vlfInfo -Description 'The VLF selected for surgical corruption' | Out-Null
    }
    else {
        Write-Step '2. Target - the log file header'
        Write-Info 'Zeroing the first 8192 bytes of the .ldf.'
        $offset = 0
        $PatchBytes = 8192
    }

    Write-Warn ("About to write {0:N0} bytes at offset {1:N0} (0x{1:X}) of {2} on {3}" -f $PatchBytes, $offset, $ldf, $TargetNode)

    Wait-ForScreenshot -Moment 'Everything healthy, just before the damage' -Capture @(
        'SSMS > Always On High Availability > Availability Groups > agsql2 > Show Dashboard - all green',
        'The VLF table above (sys.dm_db_log_info) with the chosen VLF highlighted',
        'The preflight table showing SYNCHRONIZED / HEALTHY on both replicas'
    )

    # --------------------------------------------- 5. park the cluster policy
    Write-Step '3. Parking the WSFC failover policy'
    $policy = Suspend-AgClusterFailover
    Save-Snapshot -Name "04-$mode-cluster-policy-before" -Data $policy -Description 'Cluster policy captured before the corruption window' | Out-Null

    try {
        # ------------------------------------------------- 6. stop the instance
        if ($mode -eq 'Header') {
            Write-Step '4. Opening an uncommitted transaction, then hard-killing sqlservr'

            $conn = New-Object System.Data.SqlClient.SqlConnection (New-LabConnectionString -Server $TargetNode -Database $db)
            try {
                $conn.Open()
                $cmd = $conn.CreateCommand()
                $cmd.CommandTimeout = 300
                $cmd.CommandText = @"
BEGIN TRANSACTION;
INSERT INTO dbo.Orders (CustomerId, Status, Amount)
SELECT TOP (5000) ABS(CHECKSUM(NEWID())) % 25000, 'UNCOMMITTED',
       CAST(ABS(CHECKSUM(NEWID())) % 500000 / 100.0 AS decimal(12,2))
FROM sys.all_columns a CROSS JOIN sys.all_columns b;
UPDATE TOP (3000) dbo.Orders SET Status = 'DIRTY' WHERE Status = 'NEW';
"@
                [void]$cmd.ExecuteNonQuery()
                Write-Ok 'Transaction is open and NOT committed (5000 inserts + 3000 updates)'

                # force the uncommitted log records out of the log buffer onto disk
                $null = Invoke-Ag -Server $TargetNode -Database $db -Query 'CHECKPOINT;'
                Write-Ok 'CHECKPOINT issued - the uncommitted log records are now on disk'

                $openTran = Invoke-Ag -Server $TargetNode -Database $db -Query @"
SELECT COUNT(*) AS open_transactions
FROM sys.dm_tran_database_transactions
WHERE database_id = DB_ID('$db');
"@ -NoThrow
                if ($openTran.Success) { Write-Info "Open transactions in $db : $($openTran.Rows[0].open_transactions)" }

                Write-Warn "Hard-killing sqlservr.exe on $TargetNode - recovery will have work to do"
                Invoke-OnNode -Node $TargetNode -ScriptBlock {
                    $p = Get-Process -Name sqlservr -ErrorAction SilentlyContinue
                    if ($p) { $p | Stop-Process -Force }
                }
            }
            finally {
                try { $conn.Close(); $conn.Dispose() } catch { }
            }
        }
        else {
            Write-Step "4. Clean shutdown of $($Lab.Service) on $TargetNode"
            Write-Info 'Stopping cleanly, after the CHECKPOINT above, keeps the redo range short.'
            Write-Info 'An AG database is started by the availability group, so it still runs recovery -'
            Write-Info 'a clean stop alone does NOT mean there is nothing to redo.'
            Invoke-OnNode -Node $TargetNode -ArgumentList @($Lab.Service) -ScriptBlock {
                param($s) Stop-Service -Name $s -Force
            }
        }

        # wait for the file to be released
        $released = $false
        for ($i = 0; $i -lt 60; $i++) {
            $running = Invoke-OnNode -Node $TargetNode -ScriptBlock {
                [bool](Get-Process -Name sqlservr -ErrorAction SilentlyContinue)
            }
            if (-not $running) { $released = $true; break }
            Start-Sleep -Seconds 2
        }
        if (-not $released) { throw "sqlservr.exe is still running on $TargetNode - cannot patch the log file." }
        Write-Ok 'SQL Server is stopped and the .ldf is released'

        # ------------------------------------------------ 7. the rollback copy
        Write-Step '5. Taking the pristine side copy'
        Invoke-OnNode -Node $TargetNode -ArgumentList @($ldf, $pristine) -ScriptBlock {
            param($src, $dst) Copy-Item -LiteralPath $src -Destination $dst -Force
        }
        Write-Ok "Pristine copy: $pristine (on $TargetNode)"

        # ---------------------------------------------------- 8. safety gate
        Write-Step '6. Safety gate'
        $null = Assert-SafeToCorrupt -Path $ldf -DbName $db -Node $TargetNode -BackupCopyPath $pristine

        # ------------------------------------------------------- 9. patch it
        Write-Step '7. Writing the corruption'
        $fill = if ($mode -eq 'Header') { 'zero' } else { 'pattern' }
        $patch = Invoke-OnNode -Node $TargetNode -ScriptBlock $sbPatch -ArgumentList @($ldf, $offset, $PatchBytes, $fill)

        Write-Ok ("Wrote {0:N0} bytes at offset {1:N0}" -f $patch.Length, $patch.Offset)
        Write-Host ''
        Write-Host '  first 64 bytes BEFORE:' -ForegroundColor DarkGray
        Write-Host "    $($patch.BeforeHex)" -ForegroundColor DarkGray
        Write-Host '  first 64 bytes AFTER:' -ForegroundColor Yellow
        Write-Host "    $($patch.AfterHex)" -ForegroundColor Yellow
        Save-Snapshot -Name "04-$mode-byte-patch" -Data $patch -Description "Bytes overwritten in $ldf on $TargetNode" | Out-Null

        # The only window in which the .ldf can be opened in a hex editor - SQL
        # is stopped and holds no handle on it. Once the service starts, it locks.
        Write-Host ''
        Write-Host '  HEX EDITOR - open this file now:' -ForegroundColor Magenta
        Write-Host "    file   : $ldf   (on $TargetNode)" -ForegroundColor Magenta
        Write-Host ("    offset : {0:N0} decimal  =  0x{0:X} hex" -f $patch.Offset) -ForegroundColor Magenta
        if ($mode -eq 'Surgical') {
            Write-Host '    look for: the repeating ASCII text "CORRUPT!"' -ForegroundColor Magenta
        } else {
            Write-Host '    look for: 8192 bytes of 00 where the log header used to be' -ForegroundColor Magenta
        }
        Wait-ForScreenshot -Moment 'The damaged bytes in the hex editor (SQL is stopped - this window closes when it starts)' -Capture @(
            'Hex editor at the offset above, showing the overwritten bytes',
            'Optionally the pristine copy side by side for a before/after'
        )

        # ------------------------------------------------- 10. start it back up
        Write-Step "8. Starting $($Lab.Service) on $TargetNode"
        Invoke-OnNode -Node $TargetNode -ArgumentList @($Lab.Service) -ScriptBlock {
            param($s) Start-Service -Name $s
        }

        if (Wait-SqlUp -Server $TargetNode -TimeoutSec 300) {
            Write-Ok "$TargetNode is back up"
        } else {
            Write-Bad "$TargetNode did not come back - check the error log on the node itself."
        }
    }
    finally {
        Write-Step '9. Restoring the WSFC failover policy'
        Restore-AgClusterFailover -Policy $policy

        try {
            $res = Get-ClusterResource -Name $Lab.AgName
            if ($res.State -ne 'Online') {
                Write-Warn "Cluster resource '$($Lab.AgName)' is $($res.State) - bringing it online"
                try { Start-ClusterResource -Name $Lab.AgName -ErrorAction Stop | Out-Null; Write-Ok 'Resource online' }
                catch { Write-Bad "Could not bring the resource online: $($_.Exception.Message)" }
            } else {
                Write-Ok "Cluster resource '$($Lab.AgName)' is Online on $($res.OwnerNode.Name)"
            }
        } catch {
            Write-Warn "Could not read the cluster resource state: $($_.Exception.Message)"
        }
    }

    # ----------------------------------------------------------- 11. first look
    Write-Step '10. First look at the damage'

    Start-Sleep -Seconds 5
    $state = Invoke-Ag -Server $TargetNode -Query @"
SELECT name, state_desc, recovery_model_desc, is_in_standby
FROM sys.databases WHERE name = '$db';
"@ -NoThrow
    if ($state.Success -and $state.Rows.Count) {
        $state.Rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
        $s = $state.Rows[0].state_desc
        if ($mode -eq 'Surgical' -and $s -eq 'ONLINE') {
            Write-Ok "As designed: '$db' is ONLINE. The damage only shows when the log is read."
        } elseif ($mode -eq 'Header' -and $s -ne 'ONLINE') {
            Write-Ok "As designed: '$db' is $s - recovery could not process the log."
        } else {
            Write-Warn "'$db' is $s - not the textbook outcome for $mode mode, but it is a real result. 05-Observe.ps1 will show why."
        }
    } else {
        Write-Warn "Could not read sys.databases on $TargetNode yet."
    }

    if ($mode -eq 'Surgical') {
        Wait-ForScreenshot -Moment 'The insidious part - damaged log, but the AG still reports healthy' -Capture @(
            'SSMS AG dashboard - STILL GREEN even though the log is corrupt',
            'Object Explorer showing LogCorruptDemo as a normal online database',
            'The sys.databases row above showing state_desc = ONLINE'
        )
    } else {
        Wait-ForScreenshot -Moment 'Recovery failed' -Capture @(
            'SSMS Object Explorer - LogCorruptDemo marked Recovery Pending',
            'SSMS AG dashboard - now showing the error',
            'The sys.databases row above'
        )
    }

    Write-Step "Corruption applied ($mode)"
    Write-Ok 'Next: .\05-Observe.ps1'
    Write-Info "Undo with: .\04-Corrupt-Log.ps1 -Rollback -TargetNode $TargetNode"
}
finally {
    Stop-LabTranscript
    Write-Host ''
    Write-Host "  Transcript: $transcript" -ForegroundColor DarkGray
}
