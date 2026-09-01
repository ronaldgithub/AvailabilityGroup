# Corrupt Transaction Log in an Availability Group

A reproducible PowerShell lab that answers one question with real evidence:

> **What actually happens to an Always On Availability Group when the transaction log of a database on the primary is physically corrupted — and how do you recover from it?**

Every step captures the genuine error numbers, DMV output and timings to `output/`, so the result is blog material rather than a theoretical write-up.

## The two acts

The lab builds one database and then damages it twice, in two deliberately different ways.

### Act 1 — surgical corruption

Clean service shutdown, then ~4 KB overwritten deep inside an **older active VLF**. The chosen VLF is:

- written **after** the last log backup, so the next `BACKUP LOG` must read it;
- already hardened on the secondary, so the failover stays possible;
- **not** the VLF the engine is currently writing to, and not needed by crash recovery.

**Result:** the database comes back **ONLINE**, the AG dashboard stays **green**, `DBCC CHECKDB` comes back **clean** — and `BACKUP LOG` fails with **9004 / 9001**.

That combination is the point. Always On never notices, because the log reader only moves forward and never re-reads the damaged region. Your monitoring says healthy while your log backups are silently broken.

#### Picking the VLF — a worked example

Those three conditions are enforced in SQL, in `04-Corrupt-Log.ps1`, against
`sys.dm_db_log_info` and `msdb.dbo.backupset`. Here is what they resolved to on
one real run (`output\...03-vlf-layout-before-corruption.txt`, 2026-09-01 11:39):

```
LogCorruptDemo_log.ldf  (file_id 2)   45 VLFs x ~64 MB   ~2.94 GB

PHYSICAL layout (ordered by vlf_begin_offset) -- the log has WRAPPED:

  byte 0                                                        ~2.94 GB
    |                                                                  |
    v                                                                  v
   +------+------+------+------+------+------+--- ... ---+------+
   |  89  |  90  |  91  |  92  |  48  |  49  |    ...    |  88  |
   +------+------+------+------+------+------+--- ... ---+------+
                    ^^^^   ^^^^                             ^^^^
                  TARGET  current                        last log
                          write VLF                       backup

CHRONOLOGICAL order (by vlf_sequence_number) -- 48 .. 88 fill the file,
then the writer wraps back to byte 0 and allocates 89, 90, 91, 92:

   48 ... 87   88   |   89     90     91     92
                    |                 ^      ^
        backed up   |   <-- eligible -->     |
        (seq <= 88) |                        engine writing here
                    |
              BACKUP LOG must re-read everything to the right of this line

The three conditions:

   vlf_status = 2          -> 91 is active                        OK
   seq >  last backup VLF  -> 91 > 88, next BACKUP LOG reads it   OK
   seq <  current write    -> 91 < 92, not the tail, so it is
                              already hardened on the secondary   OK

VLF 91 in detail:

   vlf_begin_offset  134,094,848   (127.88 MB into the file)
   vlf_size_mb            63.93
   vlf_first_lsn     0000005B:00000010:0001
                     ^^^^^^^^
                     0x5B = 91

   corruption offset 134,094,848 + 8,192 = 134,103,040
                     (+8 KB clears the VLF's own header and lands in
                      log-record territory)
```

The last log backup ended at LSN `88000002660800001`. The first hex group of an
LSN *is* the VLF sequence number, and the numeric LSN conversion scales it by
10^15 — so `FLOOR(last_lsn / 1000000000000000)` recovers it: VLF **88**. With the
engine writing to 92, that left {89, 90, 91} eligible and `ORDER BY seq DESC`
took **91**.

The numbers differ every run — the script re-derives all of them at runtime and
never hardcodes an offset. The wrap is why: physical position and sequence
number diverge once the log recycles, so the byte offset has to come from the
DMV rather than from arithmetic on the sequence number.

### Act 2 — log header smash

An uncommitted transaction is left open, `sqlservr.exe` is hard-killed so recovery has real work to do, then the first 8 KB of the `.ldf` is zeroed.

**Result:** recovery fails at startup, the database lands in `RECOVERY_PENDING` / `SUSPECT` with **5172 / 9003**.

### The recovery, both times

Fail over to the healthy replica, prove `BACKUP LOG` succeeds there, drop the corrupt copy, and let **automatic seeding** rebuild it. That `BACKUP LOG` succeeding on the failed-over replica is the single most important assertion in the lab: synchronous commit meant the secondary held an undamaged copy of the very log the primary could not read.

## Requirements

- Two SQL Server nodes in a WSFC with an availability group, both replicas `SYNCHRONOUS_COMMIT` and `SEEDING_MODE = AUTOMATIC`
- Enterprise or Developer edition (automatic seeding)
- PowerShell 5.1, WinRM between the nodes, and local admin on both
- Built and verified against **SQL Server 2025 (17.0.1000.7) Developer** on Windows Server 2022

Queries run on `System.Data.SqlClient` directly, so dbatools is not required.

## Configure

Everything is driven from the `$Lab` block at the top of [`Common.ps1`](Common.ps1):

```powershell
$Global:Lab = [ordered]@{
    AgName      = 'agsql2'
    ClusterName = 'sqlcls2'
    NodeA       = 'sql4'
    NodeB       = 'sql5'
    DemoDb      = 'LogCorruptDemo'
    BackupDir   = 'H:\Backup'
    LogDir      = 'F:\MSSQL17.MSSQLSERVER\MSSQL\Data'
    DataDir     = 'E:\MSSQL17.MSSQLSERVER\MSSQL\Data'
}
```

## Run it

```powershell
.\00-Prep-Environment.ps1        # connectivity, folders, symmetric log paths, baseline
.\01-Cleanup-AG.ps1              # dry run - shows what it would drop
.\01-Cleanup-AG.ps1 -Force       # empty the AG
.\02-Create-DemoDb.ps1           # create, back up, add to AG, watch seeding
.\03-Generate-Load.ps1           # ~2 GB of data, then shape the log

# Act 1
.\04-Corrupt-Log.ps1 -Mode Surgical -Pause
.\05-Observe.ps1 -Label act1 -Pause
.\06-Failover.ps1 -Pause
.\07-Repair-Reseed.ps1 -Label act1 -Pause

# Act 2
.\04-Corrupt-Log.ps1 -Mode Header -Pause
.\05-Observe.ps1 -Label act2 -Pause
.\06-Failover.ps1 -Pause
.\07-Repair-Reseed.ps1 -Label act2 -Pause

.\08-Verify.ps1                  # CHECKDB, health, log chain, assemble evidence
```

Each script is idempotent and runnable on its own, so the demo can be stepped through, paused and replayed.

`-Pause` stops at screenshot-worthy moments and prints exactly what is worth capturing — including the hex-editor window, which only exists while SQL Server is stopped and the `.ldf` is unlocked. It needs a real console for `Read-Host`.

## Scripts

| Script | Purpose |
|---|---|
| [`Common.ps1`](Common.ps1) | Query layer, AG state helpers, seeding monitor, safety gate, screenshot pauses |
| [`00-Prep-Environment.ps1`](00-Prep-Environment.ps1) | Connectivity, folder and ACL creation, makes the nodes' log paths symmetric, baseline snapshot |
| [`01-Cleanup-AG.ps1`](01-Cleanup-AG.ps1) | Removes every database from the AG and drops it on both nodes (DMV-driven, so it doubles as a full reset) |
| [`02-Create-DemoDb.ps1`](02-Create-DemoDb.ps1) | Creates the demo database, backs it up, adds it to the AG, watches automatic seeding |
| [`03-Generate-Load.ps1`](03-Generate-Load.ps1) | Bulk load, one log backup, then churn — shapes the log so Act 1 has a valid target |
| [`04-Corrupt-Log.ps1`](04-Corrupt-Log.ps1) | The corruption itself: `-Mode Surgical\|Header`, `-Rollback`, `-Pause` |
| [`05-Observe.ps1`](05-Observe.ps1) | Database state, AG health, the failing log backup, CHECKDB, both error logs |
| [`06-Failover.ps1`](06-Failover.ps1) | Planned manual failover, with a guarded forced-failover fallback |
| [`07-Repair-Reseed.ps1`](07-Repair-Reseed.ps1) | Proves the backup works on the new primary, drops the corrupt copy, re-seeds |
| [`08-Verify.ps1`](08-Verify.ps1) | Final checks and assembles `output/EVIDENCE_*.md` |

## Safety

This lab **deliberately destroys data**. It is for a disposable test environment only.

- `Assert-SafeToCorrupt` refuses to write to anything that is not a runtime-resolved `LogCorruptDemo*.ldf`, rejects system database paths, and demands a rollback copy exists first.
- Every corruption is preceded by a byte-for-byte side copy, so `.\04-Corrupt-Log.ps1 -Rollback -TargetNode <node>` undoes any act without rebuilding.
- `01-Cleanup-AG.ps1` is a dry run unless given `-Force`.
- The WSFC failover policy (`RestartAction`) is parked during the corruption window so the cluster does not move the AG mid-experiment, and restored afterwards.

## Things this lab demonstrates

- A corrupt transaction log on the primary can leave the AG reporting **perfectly healthy**.
- `DBCC CHECKDB` does **not** validate the transaction log — it comes back clean on a database whose log is wrecked.
- A `BACKUP LOG` only reads log written since the previous one, so *where* the corruption lands decides whether you ever find out.
- Synchronous commit means the secondary holds an undamaged copy of the same log.
- Automatic seeding places files in the **destination instance's** default data and log paths, not the source's.

## If you are actually chasing this in production

The lab exists because this failure mode is genuinely hard to diagnose: the two
things an operator normally reaches for both come back clean.

### "No errors in the Windows Event Log"

Weaker evidence than it looks. The storage events that matter here are logged as
**Warnings**, not Errors, so filtering the event log by Error level hides exactly
the wrong ones:

| Event ID | Source | Meaning |
|---|---|---|
| 129 | `storahci` / vendor HBA | Reset to device — an I/O never completed |
| 153 | `disk` | I/O retried, then silently succeeded |
| 51 | `disk` | Paging error during a write |
| 57 | `Ntfs` | Data not written to the transaction log — flushed data lost |

Event 57 is close to a direct description of silent log damage. Re-check with the
level filter off, on the **System** log of both nodes.

### "DBCC CHECKDB is clean"

Worth nothing here, and `05-Observe.ps1` runs CHECKDB specifically to prove it.
CHECKDB validates data pages. It never reads the transaction log.

### The timing trap

Act 1's finding is that the AG never notices. The log reader only moves forward,
so a damaged region is never re-read and the dashboard stays green. The
corruption surfaces only when something is forced to read that region again — a
`BACKUP LOG`, or a restart running recovery.

The damage can therefore predate its discovery by days or weeks, and correlating
against "what changed last night" will point at the wrong event. Anchor on the
**last successful `BACKUP LOG`** in `msdb.dbo.backupset` instead: the damage
landed somewhere after that point, and that is the real search window.

### Candidate causes, roughly in order

1. **Uncoordinated volume-level snapshot or restore.** With data and log on
   separate volumes (`E:` and `F:` here), VSS snapshots and SAN or backup-product
   replicas are taken *per volume*. If the two were ever captured or rolled back
   without a coordinated, application-consistent quiesce, the log no longer
   matches the data — and nothing appears in the event log, because from
   Windows' point of view every write succeeded. Check whether the backup product
   is doing genuine application-aware processing or only a crash-consistent
   image, and whether a replica or storage snapshot was ever failed over,
   reverted or resynced on those volumes.

2. **A write cache lying about durability.** Write-ahead logging depends on a log
   write being on stable media when it is acknowledged. A write-back cache with a
   dead BBU or supercap, bad controller firmware, or an unsafe virtualization
   cache mode will acknowledge writes that were never hardened. One power event
   later, log blocks are gone, with nothing reporting a failure. Check the RAID
   controller battery state, the cache policy, and the datastore or LUN cache
   mode.

3. **Backup-product interactions.** Two owners of one log chain — the backup
   product taking SQL log backups while a maintenance plan or Ola job does the
   same — splits the chain rather than corrupting bytes, but produces very
   similar-looking `BACKUP LOG` failures and is far more common. Also: VM stun
   during snapshot commit causing I/O timeouts (usually leaves error 833), and
   backing up an AG replica without correct replica-preference handling.

4. **Filter drivers.** Antivirus, EDR or backup agents touching `.ldf` files.
   Confirm exclusions for `*.mdf`, `*.ndf`, `*.ldf`, `*.trn`, `*.bak` and the SQL
   binaries on **both** nodes.

### What to pull

```sql
-- the real error record, not the Windows one
EXEC xp_readerrorlog 0, 1, N'823';   -- repeat for 824, 825, 833, 9004, 9001, 5172, 3414
SELECT * FROM msdb.dbo.suspect_pages;

-- where the damage window starts
SELECT TOP 20 backup_start_date, backup_finish_date, type, first_lsn, last_lsn, is_copy_only
FROM msdb.dbo.backupset
WHERE database_name = 'YourDb'
ORDER BY backup_finish_date DESC;
```

Error **825** ("read-retry succeeded") is the one that gets missed: a *warning*
meaning the I/O failed and then worked on retry. It is a storage failure
announcing itself in advance, and it does not reach the Windows Event Log at all.

Also worth checking: the SQL ERRORLOG on **both** replicas, write latency on the
log file in `sys.dm_io_virtual_file_stats`, and whether one backup job covers
both nodes.
