<#
    02-Create-DemoDb.ps1

    Phase 2a: build LogCorruptDemo on the primary, back it up, and add it to
    agsql2 with automatic seeding while watching the seeding DMVs.

    The log is deliberately created at 512 MB with a fixed 64 MB growth so the
    VLF layout is predictable: SQL carves an initial log of that size into
    8 VLFs of 64 MB, which gives 04-Corrupt-Log.ps1 a clean target to aim at.

    Usage:  .\02-Create-DemoDb.ps1
            .\02-Create-DemoDb.ps1 -DropExisting

    Author: Ronald.de.Groot@OpenData.nl and Claude Code
#>
[CmdletBinding()]
param(
    [switch]$DropExisting,
    [int]$DataSizeMB = 3072,
    [int]$LogSizeMB = 512
)

. "$PSScriptRoot\Common.ps1"
$transcript = Start-LabTranscript -Name '02-create-demodb'

try {
    Write-Step 'Phase 2a - create the demo database and add it to the AG'

    $primary   = Get-AgPrimary
    $secondary = Get-AgSecondary
    if (-not $primary) { throw "Cannot find the primary replica for '$($Lab.AgName)'." }
    Write-Ok "Primary: $primary   Secondary: $secondary"

    $db = $Lab.DemoDb

    # ------------------------------------------------------------- 1. preflight
    Write-Step '1. Preflight'

    # Instant file initialization decides whether the 3 GB data file is instant
    # or zero-filled. Log files are always zeroed regardless.
    $ifi = Invoke-Ag -Server $primary -Query @"
SELECT servicename, instant_file_initialization_enabled
FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server (%';
"@ -NoThrow
    if ($ifi.Success -and $ifi.Rows.Count) {
        Write-Info "Instant file initialization on $primary : $($ifi.Rows[0].instant_file_initialization_enabled)"
    }

    # Automatic seeding needs the secondary to allow the AG to create databases.
    # Idempotent, and the usual cause of a seeding failure when it is missing.
    Write-Info "Granting CREATE ANY DATABASE to '$($Lab.AgName)' on $secondary (idempotent)"
    $grant = Invoke-Ag -Server $secondary -Query "ALTER AVAILABILITY GROUP [$($Lab.AgName)] GRANT CREATE ANY DATABASE;" -NoThrow
    if ($grant.Success) { Write-Ok 'CREATE ANY DATABASE granted on the secondary' }
    else { Write-Warn "Grant returned: $($grant.Error.Message)" }

    # ------------------------------------------------- 2. drop any earlier copy
    foreach ($node in @($primary, $secondary)) {
        $exists = Invoke-Ag -Server $node -Query "SELECT state_desc FROM sys.databases WHERE name = '$db';" -NoThrow
        if ($exists.Success -and $exists.Rows.Count -gt 0) {
            if (-not $DropExisting) {
                throw "'$db' already exists on $node. Re-run with -DropExisting to rebuild it."
            }
            Write-Step "Dropping the existing '$db' on $node"
            if ((Get-AgDatabases -Server $primary) -contains $db) {
                $null = Invoke-Ag -Server $primary -Query "ALTER AVAILABILITY GROUP [$($Lab.AgName)] REMOVE DATABASE [$db];" -NoThrow
                Start-Sleep -Seconds 3
            }
            $null = Invoke-Ag -Server $node -Query "ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;" -NoThrow
            $null = Invoke-Ag -Server $node -Query "ALTER DATABASE [$db] SET HADR OFF;" -NoThrow
            $d = Invoke-Ag -Server $node -Query "DROP DATABASE [$db];" -NoThrow
            if ($d.Success) { Write-Ok "dropped $db on $node" } else { Write-Bad $d.Error.Message }
        }
    }

    # ------------------------------------------------------------- 3. create it
    Write-Step "2. Creating '$db' on $primary"

    $create = @"
CREATE DATABASE [$db]
ON PRIMARY
(
    NAME = N'${db}_data',
    FILENAME = N'$($Lab.DataDir)\$db.mdf',
    SIZE = ${DataSizeMB}MB,
    FILEGROWTH = 512MB
)
LOG ON
(
    NAME = N'${db}_log',
    FILENAME = N'$($Lab.LogDir)\${db}_log.ldf',
    SIZE = ${LogSizeMB}MB,
    FILEGROWTH = 64MB
);
"@
    Write-Info "data: $($Lab.DataDir)\$db.mdf  ($DataSizeMB MB)"
    Write-Info "log : $($Lab.LogDir)\${db}_log.ldf  ($LogSizeMB MB, 64 MB fixed growth)"
    $null = Invoke-Ag -Server $primary -Query $create -TimeoutSec 1800
    Write-Ok "'$db' created"

    $null = Invoke-Ag -Server $primary -Query "ALTER DATABASE [$db] SET RECOVERY FULL;"
    Write-Ok 'Recovery model set to FULL'

    # VLF layout - the thing 04-Corrupt-Log.ps1 will target
    $vlf = @(Invoke-Ag -Server $primary -Query @"
SELECT file_id, vlf_begin_offset, vlf_size_mb, vlf_active, vlf_status, vlf_sequence_number
FROM sys.dm_db_log_info(DB_ID('$db')) ORDER BY vlf_begin_offset;
"@)
    Write-Step 'Initial VLF layout'
    $vlf | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Write-Ok ("{0} VLFs created" -f $vlf.Count)
    Save-Snapshot -Name '02-initial-vlf-layout' -Data $vlf -Description "VLF layout of $db immediately after creation" | Out-Null

    # ------------------------------------------------------------ 4. backup it
    Write-Step '3. Full backup (required before a database can join an AG)'

    $bak = "$($Lab.BackupDir)\${db}_full.bak"
    $backupSql = "BACKUP DATABASE [$db] TO DISK = N'$bak' WITH INIT, COMPRESSION, CHECKSUM, STATS = 25;"
    Write-Info $backupSql
    $b = Invoke-Ag -Server $primary -Query $backupSql -TimeoutSec 3600 -Raw
    $b.Messages | ForEach-Object { Write-Info $_ }
    Write-Ok "Full backup written to $bak"

    # ------------------------------------------------------- 5. add it to the AG
    Write-Step "4. Adding '$db' to $($Lab.AgName) with automatic seeding"

    $addSql = "ALTER AVAILABILITY GROUP [$($Lab.AgName)] ADD DATABASE [$db];"
    Write-Info $addSql
    $null = Invoke-Ag -Server $primary -Query $addSql -TimeoutSec 300
    Write-Ok 'ADD DATABASE issued - automatic seeding starts on the primary'

    $seed = Watch-Seeding -Server $primary -DbName $db -TimeoutSec 1800
    Save-Snapshot -Name '02-seeding-initial' -Data ($seed.Log -join [Environment]::NewLine) `
        -Description "sys.dm_hadr_physical_seeding_stats while seeding $db to $secondary" | Out-Null

    if (-not $seed.Completed) {
        Write-Bad 'Seeding did not complete. Check the error log on both nodes before continuing.'
        Get-SqlErrorLogTail -Server $primary -Filter 'seeding' -Last 20 | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
        throw 'Automatic seeding failed.'
    }

    # ---------------------------------------------------- 6. verify file layout
    Write-Step '5. Verifying the seeded file layout on the secondary'

    $files = Invoke-Ag -Server $secondary -Query @"
SELECT name AS logical_name, type_desc, physical_name
FROM sys.master_files WHERE database_id = DB_ID('$db');
"@
    $files | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

    $logFile = @($files | Where-Object { $_.type_desc -eq 'LOG' })
    if ($logFile.Count -gt 0 -and $logFile[0].physical_name -like 'F:\*') {
        Write-Ok "Seeded log file landed on F: - the Phase 0 path fix worked."
    } elseif ($logFile.Count -gt 0) {
        Write-Warn "Seeded log file is at $($logFile[0].physical_name) - expected F:. The nodes are not symmetric."
    }
    Save-Snapshot -Name '02-seeded-file-layout' -Data $files -Description "Where automatic seeding placed $db on $secondary" | Out-Null

    # --------------------------------------------------------- 7. wait for sync
    Write-Step '6. Waiting for SYNCHRONIZED'
    $null = Wait-ForSyncState -DbName $db -State 'SYNCHRONIZED' -TimeoutSec 600 -Server $primary

    $health = Get-AgHealth -Server $primary
    $health | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Save-Snapshot -Name '02-post-seed-health' -Data $health -Description "AG state after $db joined and synchronized" | Out-Null

    Write-Step 'Phase 2a complete'
    Write-Ok "Next: .\03-Generate-Load.ps1"
}
finally {
    Stop-LabTranscript
    Write-Host ''
    Write-Host "  Transcript: $transcript" -ForegroundColor DarkGray
}
