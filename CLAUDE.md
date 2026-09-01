# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

A PowerShell lab that deliberately corrupts the transaction log of a database inside a SQL Server Always On Availability Group, observes the failure, and recovers it by failover plus automatic seeding. The output is **evidence for a blog post** — real error numbers, DMV output and timings — not a production tool.

This shapes almost every decision here: when a choice is between "hide the messy detail" and "show what actually happened", always show what actually happened. A surprising result is the deliverable, not a bug to paper over.

## The environment this targets

Live lab, currently reachable from the machine this runs on:

| | sql4 | sql5 |
|---|---|---|
| Version | SQL 2025 RTM 17.0.1000.7 Ent. Developer | same |
| Data | `E:\MSSQL17.MSSQLSERVER\MSSQL\Data\` | same |
| Log | `F:\MSSQL17.MSSQLSERVER\MSSQL\Data\` | same (fixed by `00-Prep`) |
| Backup | `H:\Backup` | same (created by `00-Prep`) |

- AG `agsql2` on WSFC `sqlcls2`, no listener — connect by node name.
- Both replicas `SYNCHRONOUS_COMMIT` / `MANUAL` / `SEEDING_MODE = AUTOMATIC`.
- SQL service account is `OPENDATA\sa_sql`.
- Scripts run **on sql4** as `Administrator`; sql5 is reached over WinRM.
- Quorum is 2-node Majority with **no witness**. Never have both nodes down at once.

`00-Prep-Environment.ps1` corrected sql5's instance default log path from `E:` to `F:` so the nodes are symmetric. Do not undo this — automatic seeding places files in the *destination* instance's default paths, so asymmetric defaults produce asymmetric layouts.

## Conventions

Everything is configured from the `$Lab` block at the top of `Common.ps1`. Never hardcode a server, path or database name in a numbered script — read it from `$Lab`.

- **Query layer is `System.Data.SqlClient`**, via `Invoke-Ag`. dbatools 2.7.27 is installed but deliberately unused; do not introduce a dependency on it. `Invoke-Ag -NoThrow` returns a result object with `.Success`, `.Rows`, `.Messages` and `.Error.Details` (per-error `Number` / `Severity` / `Message`) — that is how SQL error numbers get captured for the blog.
- **AG DDL stays as literal T-SQL** (`ALTER AVAILABILITY GROUP ...`), never wrapped in a cmdlet. The blog shows the statements.
- **Output helpers**: `Write-Step` for section banners, then `Write-Info` / `Write-Ok` / `Write-Warn` / `Write-Bad`. Do not use bare `Write-Host` for status.
- **Every script**: dot-sources `Common.ps1`, calls `Start-LabTranscript` at the top and `Stop-LabTranscript` in a `finally`, and writes evidence via `Save-Snapshot`.
- **Scripts must be idempotent and independently runnable.** The lab gets stepped through, paused for screenshots, and replayed.
- **ASCII only in `.ps1` files.** PowerShell 5.1 reading UTF-8 without a BOM will mangle non-ASCII characters. No arrows, em dashes or box drawing in script content.
- `Set-StrictMode -Version 2.0` and `$ErrorActionPreference = 'Stop'` are set in `Common.ps1` and inherited.
- Destructive scripts default to a **dry run** and require `-Force` (see `01-Cleanup-AG.ps1`).

## Safety rules — do not relax these

`Assert-SafeToCorrupt` in `Common.ps1` gates every byte written to a file. It hard-fails unless:

- the path was resolved from `sys.master_files` **at runtime** (never hardcoded),
- the filename matches `LogCorruptDemo*.ldf`,
- the path is not under a system database,
- a rollback side copy already exists.

Never add a bypass. Never widen it to another database. Every corruption takes a byte-for-byte `.pristine` copy first so `-Rollback` can undo it.

## Hard-won details

These were discovered by running the lab and are easy to get wrong again:

1. **`BACKUP LOG` only reads log written since the previous log backup.** Corrupting an already-backed-up VLF does nothing observable. The target VLF must satisfy all three: `vlf_status = 2`, sequence number **>** the last log backup's VLF, and **<** the current write VLF. The last backup's VLF is `FLOOR(backupset.last_lsn / 1000000000000000)` — the first hex group of an LSN is the VLF sequence number, and the standard numeric LSN conversion makes that a division by 10^15.
2. **The AG never notices Act 1.** The log reader only moves forward, so it does not re-read the damaged region. The dashboard stays green. That is the finding, not a failure of the test.
3. **`DBCC CHECKDB` does not validate the transaction log.** It returns clean on a database with a wrecked log. `05-Observe.ps1` runs it specifically to show this.
4. **The `agsql2` cluster resource ships with `RestartAction = 2`** ("restart and fail over"). Stopping SQL on the owner node would make WSFC move the AG and ruin determinism. `Suspend-AgClusterFailover` parks it at 0 for the corruption window; `Restore-AgClusterFailover` must run in a `finally`.
5. **An empty AG reports `NOT_HEALTHY`** on both replicas — health rolls up from databases and there are none. Expected, not a problem.
6. **A secondary copy can keep its AG membership** when data movement was suspended at the moment the primary removed the database. `ALTER DATABASE ... SET HADR OFF` on the secondary detaches it so it can be dropped. It may also resolve itself into `RESTORING`, after which a plain `DROP DATABASE` works.
7. **Automatic seeding needs `ALTER AVAILABILITY GROUP [ag] GRANT CREATE ANY DATABASE`** on the secondary. Idempotent; scripts 02 and 07 both issue it. Missing it is the usual cause of a seeding failure.
8. **An AG database cannot be set OFFLINE.** Stopping the SQL service is the only way to get exclusive access to the `.ldf`.
9. **A planned failover requires every database in the AG to be `SYNCHRONIZED`**, which is why the AG holds only the demo database.
10. **`-Pause` uses `Read-Host`** and needs a real console. It will not work when a script is launched through a tool with no stdin — the user runs those interactively.

## Running it

Order and full command list are in [README.md](README.md). In short: `00` → `01 -Force` → `02` → `03`, then per act `04` → `05` → `06` → `07`, and finally `08`.

Check state at any time without running a script:

```powershell
. .\Common.ps1
Get-AgPrimary
Get-AgHealth | Format-Table -AutoSize
Get-AgReplicaConfig | Format-Table -AutoSize
Get-AgClusterPolicy
```

Undo a corruption without rebuilding:

```powershell
.\04-Corrupt-Log.ps1 -Rollback -TargetNode sql4
```

Full reset: `01-Cleanup-AG.ps1 -Force` (DMV-driven, so it picks up `LogCorruptDemo` too), then re-run `02` and `03`.

## Repo notes

- `output/` is gitignored — transcripts, DMV snapshots and the assembled `EVIDENCE_*.md` are regenerated every run.
- Remote is `github.com/ronaldgithub/AvailabilityGroup`, branch `main`.
- Do not commit or push unless asked.
