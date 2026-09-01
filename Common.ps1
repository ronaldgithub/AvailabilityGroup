# Common.ps1 - shared helpers for the AG corrupt-log lab
# Dot-source this from every numbered script:  . "$PSScriptRoot\Common.ps1"
# Author: Ronald.de.Groot@OpenData.nl and Claude Code

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- configuration
$Global:Lab = [ordered]@{
    AgName      = 'agsql2'
    ClusterName = 'sqlcls2'
    NodeA       = 'sql4'
    NodeB       = 'sql5'
    DemoDb      = 'LogCorruptDemo'
    Service     = 'MSSQLSERVER'
    Root        = $PSScriptRoot
    OutputDir   = Join-Path $PSScriptRoot 'output'
    BackupDir   = 'H:\Backup'
    LogDir      = 'F:\MSSQL17.MSSQLSERVER\MSSQL\Data'
    DataDir     = 'E:\MSSQL17.MSSQLSERVER\MSSQL\Data'
    # set by a script's -Pause switch; makes Wait-ForScreenshot actually stop
    PauseForScreenshots = $false
}

if (-not (Test-Path $Global:Lab.OutputDir)) {
    New-Item -ItemType Directory -Path $Global:Lab.OutputDir -Force | Out-Null
}

# ---------------------------------------------------------------- console output
function Write-Step {
    param([string]$Message)
    $line = '=' * 78
    Write-Host ''
    Write-Host $line -ForegroundColor Cyan
    Write-Host ("  {0}" -f $Message) -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
}

function Write-Info { param([string]$Message) Write-Host ("  [ ] {0}" -f $Message) -ForegroundColor Gray }
function Write-Ok   { param([string]$Message) Write-Host ("  [+] {0}" -f $Message) -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host ("  [!] {0}" -f $Message) -ForegroundColor Yellow }
function Write-Bad  { param([string]$Message) Write-Host ("  [X] {0}" -f $Message) -ForegroundColor Red }

function Write-Table {
    param([Parameter(ValueFromPipeline = $true)]$InputObject)
    end {
        $all = @($input)
        if ($all.Count -eq 0) { Write-Info '(no rows)'; return }
        $all | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    }
}

# ---------------------------------------------------------------- SQL plumbing
# Implemented directly on System.Data.SqlClient rather than dbatools/SMO: it is
# guaranteed to work against SQL 2025 and returns plain objects. 00-Prep probes
# dbatools separately and reports whether it copes with 17.0.

function New-LabConnectionString {
    param(
        [Parameter(Mandatory = $true)][string]$Server,
        [string]$Database = 'master',
        [int]$ConnectTimeout = 15
    )
    "Server=$Server;Database=$Database;Integrated Security=SSPI;Encrypt=True;" +
    "TrustServerCertificate=True;Connect Timeout=$ConnectTimeout;Application Name=AG-LogCorrupt-Lab"
}

function Invoke-Ag {
    <#
      Runs a query and returns rows as PSCustomObjects.
      -Messages   also collects PRINT / BACKUP informational output
      -Raw        return the whole result object (Rows + Messages + Error)
      -NoThrow    capture the SQL error instead of throwing
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Server,
        [Parameter(Mandatory = $true)][string]$Query,
        [string]$Database = 'master',
        [int]$TimeoutSec = 600,
        [switch]$Raw,
        [switch]$NoThrow
    )

    $result = [pscustomobject]@{
        Server   = $Server
        Rows     = @()
        Messages = @()
        Error    = $null
        Success  = $true
    }

    $conn = New-Object System.Data.SqlClient.SqlConnection (New-LabConnectionString -Server $Server -Database $Database)
    $msgs = New-Object System.Collections.ArrayList
    $handler = [System.Data.SqlClient.SqlInfoMessageEventHandler] {
        param($sender, $e)
        foreach ($err in $e.Errors) { [void]$msgs.Add($err.Message) }
    }
    $conn.add_InfoMessage($handler)
    $conn.FireInfoMessageEventOnUserErrors = $false

    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = $TimeoutSec

        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
        $ds = New-Object System.Data.DataSet
        [void]$adapter.Fill($ds)

        if ($ds.Tables.Count -gt 0) {
            $rows = @()
            foreach ($table in $ds.Tables) {
                foreach ($row in $table.Rows) {
                    $o = [ordered]@{}
                    foreach ($col in $table.Columns) {
                        $v = $row[$col.ColumnName]
                        $o[$col.ColumnName] = if ($v -is [System.DBNull]) { $null } else { $v }
                    }
                    $rows += [pscustomobject]$o
                }
            }
            $result.Rows = $rows
        }
    }
    catch [System.Data.SqlClient.SqlException] {
        $result.Success = $false
        $detail = @()
        foreach ($err in $_.Exception.Errors) {
            $detail += [pscustomobject]@{
                Number   = $err.Number
                Severity = $err.Class
                State    = $err.State
                Line     = $err.LineNumber
                Message  = $err.Message
            }
        }
        $result.Error = [pscustomobject]@{
            Number   = $_.Exception.Number
            Message  = $_.Exception.Message
            Details  = $detail
        }
        if (-not $NoThrow) { $conn.Close(); throw }
    }
    catch {
        $result.Success = $false
        $result.Error = [pscustomobject]@{ Number = -1; Message = $_.Exception.Message; Details = @() }
        if (-not $NoThrow) { $conn.Close(); throw }
    }
    finally {
        $result.Messages = @($msgs)
        if ($conn.State -ne 'Closed') { $conn.Close() }
        $conn.Dispose()
    }

    if ($Raw -or $NoThrow) { return $result }
    return $result.Rows
}

function Test-SqlUp {
    param([Parameter(Mandatory = $true)][string]$Server, [int]$TimeoutSec = 5)
    try {
        $r = Invoke-Ag -Server $Server -Query 'SELECT 1 AS up' -TimeoutSec $TimeoutSec -NoThrow
        return $r.Success
    } catch { return $false }
}

function Wait-SqlUp {
    param([Parameter(Mandatory = $true)][string]$Server, [int]$TimeoutSec = 300)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if (Test-SqlUp -Server $Server) {
            Write-Ok ("{0} is accepting connections after {1:N0}s" -f $Server, $sw.Elapsed.TotalSeconds)
            return $true
        }
        Start-Sleep -Seconds 3
    }
    Write-Bad ("{0} did not come up within {1}s" -f $Server, $TimeoutSec)
    return $false
}

# ---------------------------------------------------------------- AG state
function Get-AgPrimary {
    param([string]$Server)
    $candidates = if ($Server) { @($Server) } else { @($Global:Lab.NodeA, $Global:Lab.NodeB) }
    foreach ($node in $candidates) {
        if (-not (Test-SqlUp -Server $node)) { continue }
        $q = @"
SELECT ar.replica_server_name AS primary_replica
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ar.replica_id = ars.replica_id
JOIN sys.availability_groups ag ON ag.group_id = ars.group_id
WHERE ag.name = '$($Global:Lab.AgName)' AND ars.role_desc = 'PRIMARY';
"@
        $r = Invoke-Ag -Server $node -Query $q -NoThrow
        if ($r.Success -and $r.Rows.Count -gt 0) { return $r.Rows[0].primary_replica }
    }
    return $null
}

function Get-AgSecondary {
    $p = Get-AgPrimary
    if (-not $p) { return $null }
    if ($p -eq $Global:Lab.NodeA) { return $Global:Lab.NodeB } else { return $Global:Lab.NodeA }
}

function Get-AgHealth {
    param([string]$Server)
    if (-not $Server) { $Server = Get-AgPrimary }
    if (-not $Server) { throw 'Cannot determine the AG primary - is either node up?' }
    $q = @"
SELECT
    DB_NAME(drs.database_id)          AS db_name,
    ar.replica_server_name            AS replica,
    ars.role_desc                     AS role,
    drs.synchronization_state_desc    AS sync_state,
    drs.synchronization_health_desc   AS sync_health,
    drs.is_suspended                  AS suspended,
    ISNULL(drs.suspend_reason_desc,'') AS suspend_reason,
    ISNULL(drs.database_state_desc,'') AS db_state,
    ISNULL(drs.log_send_queue_size,-1) AS log_send_kb,
    ISNULL(drs.redo_queue_size,-1)     AS redo_kb,
    drs.last_hardened_lsn             AS last_hardened_lsn
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar  ON ar.replica_id = drs.replica_id
JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = drs.replica_id
JOIN sys.availability_groups ag    ON ag.group_id = drs.group_id
WHERE ag.name = '$($Global:Lab.AgName)'
ORDER BY db_name, replica;
"@
    Invoke-Ag -Server $Server -Query $q
}

function Get-AgReplicaConfig {
    param([string]$Server)
    if (-not $Server) { $Server = Get-AgPrimary }
    $q = @"
SELECT ar.replica_server_name AS replica, ars.role_desc AS role,
       ar.availability_mode_desc AS availability_mode,
       ar.failover_mode_desc AS failover_mode,
       ar.seeding_mode_desc AS seeding_mode,
       ars.operational_state_desc AS op_state,
       ars.connected_state_desc AS connected,
       ars.synchronization_health_desc AS health
FROM sys.availability_replicas ar
JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id
WHERE ag.name = '$($Global:Lab.AgName)'
ORDER BY replica;
"@
    Invoke-Ag -Server $Server -Query $q
}

function Get-AgDatabases {
    param([string]$Server)
    if (-not $Server) { $Server = Get-AgPrimary }
    $q = @"
SELECT adc.database_name
FROM sys.availability_databases_cluster adc
JOIN sys.availability_groups ag ON ag.group_id = adc.group_id
WHERE ag.name = '$($Global:Lab.AgName)'
ORDER BY adc.database_name;
"@
    (Invoke-Ag -Server $Server -Query $q) | Select-Object -ExpandProperty database_name
}

function Wait-ForSyncState {
    <# Polls until the database reaches the wanted state on BOTH replicas. #>
    param(
        [Parameter(Mandatory = $true)][string]$DbName,
        [string]$State = 'SYNCHRONIZED',
        [int]$TimeoutSec = 900,
        [string]$Server
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $last = ''
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try {
            $rows = @(Get-AgHealth -Server $Server | Where-Object { $_.db_name -eq $DbName })
        } catch { $rows = @() }

        if ($rows.Count -ge 2) {
            $states = ($rows | ForEach-Object { "$($_.replica)=$($_.sync_state)" }) -join ' '
            if ($states -ne $last) { Write-Info ("  {0,5:N0}s  {1}" -f $sw.Elapsed.TotalSeconds, $states); $last = $states }
            if (@($rows | Where-Object { $_.sync_state -ne $State }).Count -eq 0) {
                Write-Ok ("'{0}' reached {1} on both replicas after {2:N0}s" -f $DbName, $State, $sw.Elapsed.TotalSeconds)
                return $true
            }
        }
        Start-Sleep -Seconds 3
    }
    Write-Warn ("'{0}' did not reach {1} within {2}s" -f $DbName, $State, $TimeoutSec)
    return $false
}

# ---------------------------------------------------------------- seeding
function Get-SeedingState {
    param([Parameter(Mandatory = $true)][string]$Server)
    $q = @"
SELECT ag.name AS ag_name,
       ar.replica_server_name AS target_replica,
       adc.database_name      AS db_name,
       s.current_state, s.performed_seeding, s.start_time, s.completion_time,
       ISNULL(s.failure_state_desc,'') AS failure_state,
       s.error_code, s.number_of_attempts
FROM sys.dm_hadr_automatic_seeding s
JOIN sys.availability_groups ag  ON ag.group_id = s.ag_id
JOIN sys.availability_replicas ar ON ar.replica_id = s.ag_remote_replica_id
JOIN sys.availability_databases_cluster adc ON adc.group_database_id = s.ag_db_id
WHERE ag.name = '$($Global:Lab.AgName)'
ORDER BY s.start_time DESC;
"@
    Invoke-Ag -Server $Server -Query $q -NoThrow | Select-Object -ExpandProperty Rows
}

function Get-PhysicalSeedingStats {
    param([Parameter(Mandatory = $true)][string]$Server)
    $q = @"
SELECT local_database_name AS db_name, role_desc, internal_state_desc,
       transfer_rate_bytes_per_second, transferred_size_bytes, database_size_bytes,
       CASE WHEN database_size_bytes > 0
            THEN CAST(100.0 * transferred_size_bytes / database_size_bytes AS decimal(5,1))
            ELSE 0 END AS pct,
       start_time_utc, end_time_utc, failure_code, ISNULL(failure_message,'') AS failure_message
FROM sys.dm_hadr_physical_seeding_stats;
"@
    Invoke-Ag -Server $Server -Query $q -NoThrow | Select-Object -ExpandProperty Rows
}

function Watch-Seeding {
    <#
      Polls the seeding DMVs until the named database finishes seeding, logging
      transfer rate and percentage as it goes. This is the blog's money shot.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Server,
        [Parameter(Mandatory = $true)][string]$DbName,
        [int]$TimeoutSec = 1800,
        [int]$IntervalSec = 3
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $log = New-Object System.Collections.ArrayList
    $lastLine = ''

    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $phys = @(Get-PhysicalSeedingStats -Server $Server | Where-Object { $_.db_name -eq $DbName })
        $auto = @(Get-SeedingState -Server $Server | Where-Object { $_.db_name -eq $DbName } | Select-Object -First 1)

        if ($phys.Count -gt 0) {
            $p = $phys[0]
            $mbs = if ($p.transfer_rate_bytes_per_second) { $p.transfer_rate_bytes_per_second / 1MB } else { 0 }
            $line = ("{0,5:N0}s  {1,-22} {2,6:N1}%  {3,8:N1} MB of {4,8:N1} MB  {5,7:N1} MB/s" -f `
                     $sw.Elapsed.TotalSeconds, $p.internal_state_desc, $p.pct,
                     ($p.transferred_size_bytes / 1MB), ($p.database_size_bytes / 1MB), $mbs)
            if ($line -ne $lastLine) { Write-Info $line; [void]$log.Add($line); $lastLine = $line }
            if ($p.failure_code -and $p.failure_code -ne 0) {
                Write-Bad "Seeding failure $($p.failure_code): $($p.failure_message)"
                [void]$log.Add("FAILURE $($p.failure_code): $($p.failure_message)")
            }
        }

        if ($auto.Count -gt 0) {
            $a = $auto[0]
            if ($a.current_state -eq 'COMPLETED') {
                $msg = "Seeding COMPLETED for '$DbName' (performed_seeding=$($a.performed_seeding), attempts=$($a.number_of_attempts))"
                Write-Ok $msg
                [void]$log.Add($msg)
                return [pscustomobject]@{ Completed = $true; Log = @($log); State = $a }
            }
            if ($a.failure_state -and $a.failure_state -ne '' -and $a.failure_state -ne 'NO_FAILURE') {
                $msg = "Seeding FAILED for '$DbName': $($a.failure_state) (error_code=$($a.error_code))"
                Write-Bad $msg
                [void]$log.Add($msg)
                return [pscustomobject]@{ Completed = $false; Log = @($log); State = $a }
            }
        }

        Start-Sleep -Seconds $IntervalSec
    }

    Write-Warn "Seeding for '$DbName' did not complete within $TimeoutSec s"
    return [pscustomobject]@{ Completed = $false; Log = @($log); State = $null }
}

# ---------------------------------------------------------------- files & nodes
function Invoke-OnNode {
    <# Runs a scriptblock on a node, locally when it is this machine. #>
    param(
        [Parameter(Mandatory = $true)][string]$Node,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )
    if ($Node -ieq $env:COMPUTERNAME) {
        return & $ScriptBlock @ArgumentList
    }
    return Invoke-Command -ComputerName $Node -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
}

function Get-DbFile {
    <# Resolves a database file path from sys.master_files at runtime - never hardcoded. #>
    param(
        [Parameter(Mandatory = $true)][string]$Server,
        [Parameter(Mandatory = $true)][string]$DbName,
        [ValidateSet('ROWS', 'LOG')][string]$Type = 'LOG'
    )
    $q = @"
SELECT mf.physical_name, mf.name AS logical_name, mf.size/128.0 AS size_mb, mf.type_desc
FROM sys.master_files mf
WHERE mf.database_id = DB_ID('$DbName') AND mf.type_desc = '$Type';
"@
    Invoke-Ag -Server $Server -Query $q
}

function Assert-SafeToCorrupt {
    <#
      Hard gate before any byte is written to a file. Refuses anything that is
      not a resolved LogCorruptDemo .ldf, and demands a side copy exists first.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$DbName,
        [Parameter(Mandatory = $true)][string]$Node,
        [Parameter(Mandatory = $true)][string]$BackupCopyPath
    )

    Write-Info "Safety gate on $Node : $Path"

    if ($DbName -ne $Global:Lab.DemoDb) {
        throw "REFUSED: this lab only ever corrupts '$($Global:Lab.DemoDb)', not '$DbName'."
    }
    $leaf = Split-Path $Path -Leaf
    if ($leaf -notlike "$($Global:Lab.DemoDb)*.ldf") {
        throw "REFUSED: '$leaf' does not match '$($Global:Lab.DemoDb)*.ldf'."
    }
    if ($Path -match '(?i)\\(master|model|msdb|tempdb|mssqlsystemresource)') {
        throw "REFUSED: '$Path' looks like a system database file."
    }
    $exists = Invoke-OnNode -Node $Node -ScriptBlock { param($p) Test-Path -LiteralPath $p } -ArgumentList $Path
    if (-not $exists) {
        throw "REFUSED: '$Path' does not exist on $Node."
    }
    $copyOk = Invoke-OnNode -Node $Node -ScriptBlock { param($p) Test-Path -LiteralPath $p } -ArgumentList $BackupCopyPath
    if (-not $copyOk) {
        throw "REFUSED: no rollback copy at '$BackupCopyPath' on $Node. Take the side copy first."
    }

    Write-Ok "Safety gate passed - target confirmed as the demo log file with a rollback copy in place."
    return $true
}

# ---------------------------------------------------------------- cluster policy
# The agsql2 resource ships with RestartAction = 2 ("restart and fail over"), so a
# stopped SQL service on the owner node makes WSFC move the AG - which would make
# the corruption experiment non-deterministic. We park that during the window only.

function Get-AgClusterPolicy {
    $res = Get-ClusterResource -Name $Global:Lab.AgName
    [pscustomobject]@{
        Name             = $res.Name
        State            = $res.State
        OwnerNode        = $res.OwnerNode.Name
        RestartAction    = $res.RestartAction
        RestartThreshold = $res.RestartThreshold
        RestartPeriod    = $res.RestartPeriod
    }
}

function Suspend-AgClusterFailover {
    <# Returns the previous policy so it can be handed back to Restore-AgClusterFailover. #>
    $before = Get-AgClusterPolicy
    Write-Info ("Cluster policy before: RestartAction={0} RestartThreshold={1} (owner {2})" -f `
                $before.RestartAction, $before.RestartThreshold, $before.OwnerNode)

    if ($before.RestartAction -ne 0) {
        $res = Get-ClusterResource -Name $Global:Lab.AgName
        $res.RestartAction = 0          # 0 = do not restart, do not fail over
        Write-Ok "Cluster policy parked: RestartAction = 0 (WSFC will leave the AG where it is)"
    } else {
        Write-Info 'Cluster policy already parked.'
    }
    return $before
}

function Restore-AgClusterFailover {
    param([Parameter(Mandatory = $true)]$Policy)
    try {
        $res = Get-ClusterResource -Name $Global:Lab.AgName
        $res.RestartAction = $Policy.RestartAction
        Write-Ok ("Cluster policy restored: RestartAction = {0}" -f $Policy.RestartAction)
    } catch {
        Write-Bad "Could not restore the cluster policy: $($_.Exception.Message)"
        Write-Warn "Set it back by hand:  (Get-ClusterResource -Name $($Global:Lab.AgName)).RestartAction = $($Policy.RestartAction)"
    }
}

# ---------------------------------------------------------------- evidence
function Save-Snapshot {
    <# Writes a labelled block of evidence to output\ for the blog. #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Data,
        [string]$Description = ''
    )
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $file = Join-Path $Global:Lab.OutputDir ("{0}_{1}.txt" -f $stamp, ($Name -replace '[^\w\-]', '-'))

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('=' * 78)
    [void]$sb.AppendLine("  $Name")
    [void]$sb.AppendLine("  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    if ($Description) { [void]$sb.AppendLine("  $Description") }
    [void]$sb.AppendLine('=' * 78)
    [void]$sb.AppendLine('')

    if ($Data -is [string]) {
        [void]$sb.AppendLine($Data)
    } else {
        [void]$sb.AppendLine(($Data | Format-Table -AutoSize | Out-String -Width 220))
    }

    Set-Content -LiteralPath $file -Value $sb.ToString() -Encoding UTF8
    Write-Info "Evidence -> $(Split-Path $file -Leaf)"
    return $file
}

function Wait-ForScreenshot {
    <#
      Pauses at a blog-worthy moment so a screenshot can be taken. Only pauses
      when the calling script was run with -Pause; otherwise it just prints what
      would have been worth capturing, so the transcript still records it.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Moment,
        [string[]]$Capture = @(),
        [switch]$Force
    )

    $line = '-' * 78
    Write-Host ''
    Write-Host $line -ForegroundColor Magenta
    Write-Host "  SCREENSHOT MOMENT: $Moment" -ForegroundColor Magenta
    Write-Host $line -ForegroundColor Magenta
    foreach ($c in $Capture) { Write-Host "    * $c" -ForegroundColor Magenta }

    if ($Global:Lab.PauseForScreenshots -or $Force) {
        Write-Host ''
        Write-Host '  Take the screenshot, then press ENTER to continue...' -ForegroundColor Magenta
        [void](Read-Host)
    } else {
        Write-Host '  (running without -Pause - not stopping)' -ForegroundColor DarkGray
    }
    Write-Host ''
}

function Start-LabTranscript {
    param([Parameter(Mandatory = $true)][string]$Name)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $file = Join-Path $Global:Lab.OutputDir ("{0}_transcript_{1}.log" -f $stamp, $Name)
    try { Start-Transcript -LiteralPath $file -Force | Out-Null } catch { }
    return $file
}

function Stop-LabTranscript {
    try { Stop-Transcript | Out-Null } catch { }
}

function Get-SqlErrorLogTail {
    <# Pulls recent error-log lines matching a filter - the blog evidence. #>
    param(
        [Parameter(Mandatory = $true)][string]$Server,
        [string]$Filter = '',
        [int]$Last = 40
    )
    $q = "EXEC sp_readerrorlog 0, 1, '$($Filter -replace "'","''")', ''"
    $r = Invoke-Ag -Server $Server -Query $q -NoThrow
    if (-not $r.Success) { return @() }
    return @($r.Rows | Select-Object -Last $Last)
}
