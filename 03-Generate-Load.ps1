<#
    03-Generate-Load.ps1

    Phase 2b: put ~2 GB of real data into LogCorruptDemo and then deliberately
    shape the transaction log so 04-Corrupt-Log.ps1 has a clean target.

    Three stages:
      1. Bulk load  - ~2 GB across two tables, in batches, so the log holds
                      genuine, varied content rather than one huge transaction.
      2. Truncate   - one log backup, which frees the VLFs used by the bulk load
                      and gives us a known-good starting point.
      3. Churn      - inserts/updates/deletes with NO log backup afterwards, so
                      several VLFs go active and stay active. That is what gives
                      us an *older active* VLF to corrupt in Act 1 - one that is
                      already hardened on the secondary but is not the VLF the
                      engine is currently writing to.

    Usage:  .\03-Generate-Load.ps1
            .\03-Generate-Load.ps1 -TargetDataMB 2048 -ChurnBatches 40

    Author: Ronald.de.Groot@OpenData.nl and Claude Code
#>
[CmdletBinding()]
param(
    [int]$TargetDataMB = 2048,
    [int]$BatchRows = 10000,
    [int]$ChurnBatches = 40
)

. "$PSScriptRoot\Common.ps1"
$transcript = Start-LabTranscript -Name '03-generate-load'

try {
    Write-Step 'Phase 2b - generate load'

    $primary = Get-AgPrimary
    $db = $Lab.DemoDb
    if (-not $primary) { throw "Cannot find the primary replica for '$($Lab.AgName)'." }
    Write-Ok "Primary: $primary"

    $inAg = @(Get-AgDatabases -Server $primary)
    if ($inAg -notcontains $db) { throw "'$db' is not in $($Lab.AgName). Run 02-Create-DemoDb.ps1 first." }

    # ------------------------------------------------------------ 1. the schema
    Write-Step '1. Schema'

    $schema = @"
IF OBJECT_ID('dbo.Orders') IS NULL
CREATE TABLE dbo.Orders (
    OrderId     int IDENTITY(1,1) NOT NULL PRIMARY KEY CLUSTERED,
    CustomerId  int NOT NULL,
    OrderDate   datetime2(3) NOT NULL CONSTRAINT DF_Orders_Date DEFAULT SYSDATETIME(),
    Status      varchar(20) NOT NULL,
    Amount      decimal(12,2) NOT NULL,
    Filler      char(2000) NOT NULL CONSTRAINT DF_Orders_Filler DEFAULT REPLICATE('x', 2000)
);

IF OBJECT_ID('dbo.AuditTrail') IS NULL
CREATE TABLE dbo.AuditTrail (
    AuditId     bigint IDENTITY(1,1) NOT NULL PRIMARY KEY CLUSTERED,
    OrderId     int NOT NULL,
    Action      varchar(20) NOT NULL,
    ChangedAt   datetime2(3) NOT NULL CONSTRAINT DF_Audit_At DEFAULT SYSDATETIME(),
    Note        varchar(400) NOT NULL
);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Orders_Customer')
CREATE NONCLUSTERED INDEX IX_Orders_Customer ON dbo.Orders (CustomerId) INCLUDE (Status, Amount);
"@
    $null = Invoke-Ag -Server $primary -Query $schema -Database $db -TimeoutSec 300
    Write-Ok 'Tables dbo.Orders and dbo.AuditTrail ready'

    # --------------------------------------------------------- 2. the bulk load
    Write-Step "2. Bulk load to ~$TargetDataMB MB"

    # ~2040 bytes/row => roughly 3 rows per 8 KB page
    $rowsPerMB = 512
    $targetRows = $TargetDataMB * $rowsPerMB / 1.0
    $batches = [math]::Ceiling($targetRows / $BatchRows)
    Write-Info ("~{0:N0} rows in {1:N0} batches of {2:N0}" -f $targetRows, $batches, $BatchRows)

    $insert = @"
INSERT INTO dbo.Orders (CustomerId, Status, Amount)
SELECT TOP ($BatchRows)
       ABS(CHECKSUM(NEWID())) % 25000,
       CASE ABS(CHECKSUM(NEWID())) % 4 WHEN 0 THEN 'NEW' WHEN 1 THEN 'PAID'
                                       WHEN 2 THEN 'SHIPPED' ELSE 'CANCELLED' END,
       CAST(ABS(CHECKSUM(NEWID())) % 500000 / 100.0 AS decimal(12,2))
FROM sys.all_columns a CROSS JOIN sys.all_columns b;
"@

    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 1; $i -le $batches; $i++) {
        $null = Invoke-Ag -Server $primary -Query $insert -Database $db -TimeoutSec 600
        if ($i % 10 -eq 0 -or $i -eq $batches) {
            $size = Invoke-Ag -Server $primary -Database $db -Query @"
SELECT CAST(SUM(size)/128.0 AS decimal(10,1)) AS data_mb
FROM sys.database_files WHERE type_desc = 'ROWS';
SELECT CAST(SUM(used_pages)*8/1024.0 AS decimal(10,1)) AS used_mb
FROM sys.allocation_units;
"@
            $used = ($size | Where-Object { $_.PSObject.Properties.Name -contains 'used_mb' } | Select-Object -First 1).used_mb
            Write-Info ("  batch {0,4}/{1}  used {2,8:N1} MB  elapsed {3,5:N0}s" -f $i, $batches, $used, $sw.Elapsed.TotalSeconds)
        }
    }
    Write-Ok ("Bulk load finished in {0:N0}s" -f $sw.Elapsed.TotalSeconds)

    $sizes = Invoke-Ag -Server $primary -Database $db -Query @"
SELECT name, type_desc,
       CAST(size/128.0 AS decimal(10,1)) AS size_mb,
       CAST(FILEPROPERTY(name,'SpaceUsed')/128.0 AS decimal(10,1)) AS used_mb,
       physical_name
FROM sys.database_files;
"@
    $sizes | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Save-Snapshot -Name '03-file-sizes-after-load' -Data $sizes -Description "$db file sizes after the bulk load" | Out-Null

    # ---------------------------------------------- 3. truncate with one backup
    Write-Step '3. One log backup to truncate the log'

    $logBak = "$($Lab.BackupDir)\${db}_log_baseline.trn"
    $lb = Invoke-Ag -Server $primary -Query "BACKUP LOG [$db] TO DISK = N'$logBak' WITH INIT, COMPRESSION, CHECKSUM;" -TimeoutSec 1800 -Raw
    $lb.Messages | ForEach-Object { Write-Info $_ }
    Write-Ok 'Log backed up - VLFs from the bulk load are now reusable'

    $null = Invoke-Ag -Server $primary -Query "CHECKPOINT;" -Database $db

    # --------------------------------------------------------------- 4. churn
    Write-Step "4. Churn - $ChurnBatches batches with NO log backup afterwards"
    Write-Info 'This is what leaves several VLFs active, which Act 1 needs.'

    $churn = @"
SET NOCOUNT ON;

UPDATE TOP (2000) dbo.Orders
SET Status = 'PROCESSING', Amount = Amount + 1.00
WHERE Status = 'NEW';

INSERT INTO dbo.AuditTrail (OrderId, Action, Note)
SELECT TOP (2000) OrderId, 'STATUS_CHANGE',
       'churn batch note ' + CONVERT(varchar(40), SYSDATETIME(), 121)
FROM dbo.Orders WHERE Status = 'PROCESSING';

DELETE TOP (500) FROM dbo.Orders WHERE Status = 'CANCELLED';

INSERT INTO dbo.Orders (CustomerId, Status, Amount)
SELECT TOP (1500) ABS(CHECKSUM(NEWID())) % 25000, 'NEW',
       CAST(ABS(CHECKSUM(NEWID())) % 500000 / 100.0 AS decimal(12,2))
FROM sys.all_columns a CROSS JOIN sys.all_columns b;
"@

    for ($i = 1; $i -le $ChurnBatches; $i++) {
        $null = Invoke-Ag -Server $primary -Query $churn -Database $db -TimeoutSec 600
        if ($i % 10 -eq 0 -or $i -eq $ChurnBatches) {
            $active = Invoke-Ag -Server $primary -Database $db -Query @"
SELECT COUNT(*) AS total_vlfs,
       SUM(CASE WHEN vlf_status = 2 THEN 1 ELSE 0 END) AS active_vlfs,
       CAST(SUM(CASE WHEN vlf_status = 2 THEN vlf_size_mb ELSE 0 END) AS decimal(10,1)) AS active_mb
FROM sys.dm_db_log_info(DB_ID('$db'));
"@
            Write-Info ("  churn {0,3}/{1}   VLFs {2}  active {3}  ({4} MB)" -f `
                        $i, $ChurnBatches, $active[0].total_vlfs, $active[0].active_vlfs, $active[0].active_mb)
        }
    }
    Write-Ok 'Churn complete'

    # -------------------------------------------------------- 5. the evidence
    Write-Step '5. Log state - the "before" evidence'

    $vlf = @(Invoke-Ag -Server $primary -Database $db -Query @"
SELECT file_id, vlf_begin_offset, CAST(vlf_size_mb AS decimal(10,2)) AS vlf_size_mb,
       vlf_active, vlf_status, vlf_sequence_number, vlf_parity, vlf_first_lsn, vlf_create_lsn
FROM sys.dm_db_log_info(DB_ID('$db')) ORDER BY vlf_begin_offset;
"@)
    $vlf | Format-Table -AutoSize | Out-String -Width 220 | Write-Host

    $activeCount = @($vlf | Where-Object { $_.vlf_status -eq 2 }).Count
    Write-Ok ("{0} VLFs total, {1} active" -f $vlf.Count, $activeCount)
    if ($activeCount -lt 2) {
        Write-Warn 'Fewer than 2 active VLFs - Act 1 needs an older active VLF that is not the current write VLF.'
        Write-Warn 'Re-run with a higher -ChurnBatches value.'
    }
    Save-Snapshot -Name '03-vlf-layout-before-corruption' -Data $vlf -Description "$db VLF layout immediately before Act 1" | Out-Null

    $dblog = Invoke-Ag -Server $primary -Database $db -Query @"
SELECT TOP 25 [Current LSN], Operation, Context, [Transaction ID],
       [Log Record Length] AS len, AllocUnitName
FROM fn_dblog(NULL, NULL) ORDER BY [Current LSN] DESC;
"@ -NoThrow
    if ($dblog.Success) {
        Write-Step 'Tail of the transaction log (fn_dblog)'
        $dblog.Rows | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
        Save-Snapshot -Name '03-fn-dblog-tail' -Data $dblog.Rows -Description 'Log records at the tail before corruption' | Out-Null
    }

    # ---------------------------------------------------------- 6. AG must be OK
    Write-Step '6. AG state'
    $null = Wait-ForSyncState -DbName $db -State 'SYNCHRONIZED' -TimeoutSec 600 -Server $primary
    $health = Get-AgHealth -Server $primary
    $health | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Save-Snapshot -Name '03-health-before-corruption' -Data $health -Description 'AG state immediately before Act 1' | Out-Null

    Write-Step 'Phase 2b complete'
    Write-Ok "Next: .\04-Corrupt-Log.ps1 -Mode Surgical"
}
finally {
    Stop-LabTranscript
    Write-Host ''
    Write-Host "  Transcript: $transcript" -ForegroundColor DarkGray
}
