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
