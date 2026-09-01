<#
    07-Repair-Reseed.ps1 - Author: Ronald.de.Groot@OpenData.nl and Claude Code

    Repairs the damage after a failover:

      1. BACKUP LOG on the NEW primary - expected to SUCCEED. This is the single
         most important assertion in the lab: the synchronous secondary's copy of
         the log was never touched by the primary's physical corruption.
      2. Remove the database from the AG (on the new primary).
      3. Drop the corrupt copy on the old primary.
      4. Add it back to the AG - automatic seeding rebuilds the old primary's copy
         from scratch, with sys.dm_hadr_physical_seeding_stats logged as it runs.

    Usage:  .\07-Repair-Reseed.ps1
            .\07-Repair-Reseed.ps1 -Pause

#>
[CmdletBinding()]
param(
    [string]$Label = 'act1',
    [switch]$SkipBackupProof,
    [switch]$Pause
)

. "$PSScriptRoot\Common.ps1"
$Lab.PauseForScreenshots = [bool]$Pause
$transcript = Start-LabTranscript -Name "07-repair-$Label"

try {
    Write-Step 'Repair and re-seed'

    $db = $Lab.DemoDb
    $primary = Get-AgPrimary
    if (-not $primary) { throw "Cannot determine the primary of '$($Lab.AgName)'." }
    $damaged = if ($primary -eq $Lab.NodeA) { $Lab.NodeB } else { $Lab.NodeA }

    Write-Ok "New primary (healthy copy) : $primary"
    Write-Ok "Old primary (corrupt copy) : $damaged"

    # ------------------------------------------------------------ 1. the proof
    if (-not $SkipBackupProof) {
        Write-Step "1. BACKUP LOG on the new primary - the proof the secondary's log was intact"

        $trn = "$($Lab.BackupDir)\${db}_${Label}_after_failover.trn"
        $sql = "BACKUP LOG [$db] TO DISK = N'$trn' WITH INIT, CHECKSUM, STATS = 25;"
        Write-Info "On $primary : $sql"

        $bk = Invoke-Ag -Server $primary -Query $sql -TimeoutSec 1800 -NoThrow
        $bk.Messages | ForEach-Object { Write-Info $_ }

        $report = New-Object System.Collections.ArrayList
        if ($bk.Success) {
            Write-Ok 'BACKUP LOG SUCCEEDED on the new primary.'
            Write-Ok 'The same log that could not be backed up on the old primary backs up fine here.'
            Write-Ok 'Synchronous commit did its job: the secondary held an undamaged copy.'
            [void]$report.Add("BACKUP LOG on $primary SUCCEEDED")
            $bk.Messages | ForEach-Object { [void]$report.Add($_) }
        } else {
            Write-Bad 'BACKUP LOG FAILED on the new primary too - that is a genuinely bad outcome.'
            [void]$report.Add("BACKUP LOG on $primary FAILED")
            foreach ($d in $bk.Error.Details) {
                Write-Bad ("  Msg {0}: {1}" -f $d.Number, $d.Message)
                [void]$report.Add("Msg $($d.Number): $($d.Message)")
            }
        }
        Save-Snapshot -Name "07-$Label-backup-log-on-new-primary" -Data ($report -join [Environment]::NewLine) `
            -Description 'The payoff: log backup on the failed-over replica' | Out-Null

        Wait-ForScreenshot -Moment 'The payoff - log backup works on the new primary' -Capture @(
            'The successful BACKUP LOG output above',
            'Side by side with the 9004 from 05-Observe.ps1 if you can - that pair tells the whole story'
        )
    }

    # --------------------------------------------------- 2. state before repair
    Write-Step '2. State of the damaged replica before the repair'

    $before = Get-AgHealth -Server $primary
    $before | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Save-Snapshot -Name "07-$Label-before-repair" -Data $before -Description 'AG state before removing the database' | Out-Null

    if (Test-SqlUp -Server $damaged) {
        $ds = Invoke-Ag -Server $damaged -Query @"
SELECT name, state_desc, recovery_model_desc FROM sys.databases WHERE name = '$db';
"@ -NoThrow
        if ($ds.Success -and $ds.Rows.Count) {
            $ds.Rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
        }
    }

    # ----------------------------------------------------- 3. remove and drop
    Write-Step "3. Removing '$db' from the AG and dropping the corrupt copy"

    if ((Get-AgDatabases -Server $primary) -contains $db) {
        $sql = "ALTER AVAILABILITY GROUP [$($Lab.AgName)] REMOVE DATABASE [$db];"
        Write-Info "On $primary : $sql"
        $r = Invoke-Ag -Server $primary -Query $sql -TimeoutSec 300 -NoThrow
        if ($r.Success) { Write-Ok "Removed from the AG (the copy on $primary stays online and usable)" }
        else { Write-Bad $r.Error.Message }
        Start-Sleep -Seconds 5
    } else {
        Write-Info "'$db' is not in the AG - nothing to remove"
    }

    if (Test-SqlUp -Server $damaged) {
        $exists = Invoke-Ag -Server $damaged -Query "SELECT state_desc FROM sys.databases WHERE name='$db';" -NoThrow
        if ($exists.Success -and $exists.Rows.Count) {
            Write-Info "Dropping the corrupt copy on $damaged (state: $($exists.Rows[0].state_desc))"

            # Straight after REMOVE DATABASE the copy is briefly RECOVERING, and a
            # drop in that state fails with "currently in use". It settles into
            # RESTORING on its own a few seconds later and then drops cleanly, so
            # retry rather than giving up on the first attempt.
            $dropped = $false
            for ($attempt = 1; $attempt -le 12; $attempt++) {
                $st = Invoke-Ag -Server $damaged -Query "SELECT state_desc FROM sys.databases WHERE name='$db';" -NoThrow
                if (-not $st.Success -or $st.Rows.Count -eq 0) { $dropped = $true; break }
                $state = $st.Rows[0].state_desc

                $null = Invoke-Ag -Server $damaged -Query "ALTER DATABASE [$db] SET HADR OFF;" -NoThrow
                if ($state -eq 'ONLINE') {
                    $null = Invoke-Ag -Server $damaged -Query "ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;" -NoThrow
                }
                $d = Invoke-Ag -Server $damaged -Query "DROP DATABASE [$db];" -NoThrow
                if ($d.Success) {
                    $dropped = $true
                    Write-Ok ("Corrupt copy dropped on {0} (attempt {1}, state was {2})" -f $damaged, $attempt, $state)
                    break
                }
                Write-Warn ("DROP attempt {0} failed while {1}: {2}" -f $attempt, $state, $d.Error.Message)
                Start-Sleep -Seconds 10
            }

            # Carrying on here is pointless: seeding refuses with error 223
            # "Database With Name Already Exists" if the entry is still in
            # sys.databases, and deleting the files underneath it does not help.
            if (-not $dropped) {
                Write-Bad "Could not drop '$db' on $damaged after 12 attempts."
                Write-Warn 'Stop SQL Server on that node and delete the files, or drop it by hand, then re-run.'
                throw "'$db' still exists on $damaged - automatic seeding would fail with 223 (Database With Name Already Exists)."
            }
        } else {
            Write-Info "'$db' is not present on $damaged"
        }

        # the corrupt .ldf must be gone, or seeding cannot lay down a fresh file
        $stale = Invoke-OnNode -Node $damaged -ArgumentList @("$($Lab.LogDir)\${db}_log.ldf", "$($Lab.DataDir)\${db}.mdf") -ScriptBlock {
            param($ldf, $mdf)
            [pscustomobject]@{
                LdfPresent = Test-Path -LiteralPath $ldf
                MdfPresent = Test-Path -LiteralPath $mdf
                Ldf = $ldf; Mdf = $mdf
            }
        }
        if ($stale.LdfPresent -or $stale.MdfPresent) {
            Write-Warn "Leftover files on $damaged - removing so seeding can create fresh ones"
            Invoke-OnNode -Node $damaged -ArgumentList @($stale.Ldf, $stale.Mdf) -ScriptBlock {
                param($ldf, $mdf)
                foreach ($f in @($ldf, $mdf)) {
                    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
                }
            }
            Write-Ok 'Leftover files removed'
        } else {
            Write-Ok 'No leftover database files on the damaged node'
        }
    } else {
        Write-Warn "$damaged is not reachable - skipping the drop. Re-run this script once it is back."
    }

    # --------------------------------------------------------- 4. re-add + seed
    Write-Step "4. Adding '$db' back to the AG - automatic seeding rebuilds $damaged"

    # automatic seeding needs this on whichever node is currently the secondary
    $g = Invoke-Ag -Server $damaged -Query "ALTER AVAILABILITY GROUP [$($Lab.AgName)] GRANT CREATE ANY DATABASE;" -NoThrow
    if ($g.Success) { Write-Ok "CREATE ANY DATABASE granted on $damaged" }

    # a database needs a full backup on the current primary before it can rejoin
    $lastFull = Invoke-Ag -Server $primary -Query @"
SELECT TOP 1 backup_finish_date FROM msdb.dbo.backupset
WHERE database_name = '$db' AND type = 'D' ORDER BY backup_finish_date DESC;
"@ -NoThrow
    if (-not $lastFull.Success -or $lastFull.Rows.Count -eq 0) {
        Write-Info 'No full backup recorded on this node - taking one'
        $bakFile = "$($Lab.BackupDir)\${db}_full_${Label}_reseed.bak"
        $fb = Invoke-Ag -Server $primary -Query "BACKUP DATABASE [$db] TO DISK = N'$bakFile' WITH INIT, COMPRESSION, CHECKSUM;" -TimeoutSec 3600 -NoThrow
        if ($fb.Success) { Write-Ok "Full backup taken: $bakFile" } else { Write-Bad $fb.Error.Message }
    }

    $sql = "ALTER AVAILABILITY GROUP [$($Lab.AgName)] ADD DATABASE [$db];"
    Write-Info "On $primary : $sql"
    $a = Invoke-Ag -Server $primary -Query $sql -TimeoutSec 300 -NoThrow
    if (-not $a.Success) {
        Write-Bad "ADD DATABASE failed: $($a.Error.Message)"
        throw 'Could not re-add the database to the AG.'
    }
    Write-Ok 'ADD DATABASE accepted - automatic seeding starts now'

    Wait-ForScreenshot -Moment 'Seeding is starting' -Capture @(
        'SSMS AG dashboard showing the database re-added and synchronizing',
        'Have a query window ready on sys.dm_hadr_physical_seeding_stats'
    )

    $seed = Watch-Seeding -Server $primary -DbName $db -TimeoutSec 3600
    Save-Snapshot -Name "07-$Label-seeding-progress" -Data ($seed.Log -join [Environment]::NewLine) `
        -Description "Automatic seeding of $db from $primary to $damaged" | Out-Null

    if (-not $seed.Completed) {
        Write-Bad 'Seeding did not complete cleanly. Error log excerpts:'
        Get-SqlErrorLogTail -Server $primary -Filter 'seeding' -Last 15 |
            ForEach-Object { Write-Host ("    {0}  {1}" -f $_.LogDate, $_.Text) -ForegroundColor Gray }
        Get-SqlErrorLogTail -Server $damaged -Filter 'seeding' -Last 15 |
            ForEach-Object { Write-Host ("    {0}  {1}" -f $_.LogDate, $_.Text) -ForegroundColor Gray }
    }

    # ------------------------------------------------------------- 5. verify
    Write-Step '5. Waiting for SYNCHRONIZED'
    $null = Wait-ForSyncState -DbName $db -State 'SYNCHRONIZED' -TimeoutSec 1800 -Server $primary

    $after = Get-AgHealth -Server $primary
    $after | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Save-Snapshot -Name "07-$Label-after-repair" -Data $after -Description 'AG state after the re-seed' | Out-Null

    $files = Invoke-Ag -Server $damaged -Query @"
SELECT name AS logical_name, type_desc, physical_name FROM sys.master_files WHERE database_id = DB_ID('$db');
"@ -NoThrow
    if ($files.Success -and $files.Rows.Count) {
        Write-Step 'Freshly seeded files on the repaired node'
        $files.Rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
        Save-Snapshot -Name "07-$Label-reseeded-files" -Data $files.Rows -Description "File layout on $damaged after re-seeding" | Out-Null
    }

    Wait-ForScreenshot -Moment 'Repaired and green again' -Capture @(
        'SSMS AG dashboard - both replicas synchronized and healthy',
        'The seeding progress output above showing transfer rate and duration'
    )

    Write-Step 'Repair complete'
    Write-Ok 'Next: .\08-Verify.ps1   (or Act 2: .\04-Corrupt-Log.ps1 -Mode Header)'
}
finally {
    Stop-LabTranscript
    Write-Host ''
    Write-Host "  Transcript: $transcript" -ForegroundColor DarkGray
}
