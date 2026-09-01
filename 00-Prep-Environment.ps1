<#
    00-Prep-Environment.ps1

    Phase 0: verify the lab is reachable, fix sql5's instance default LOG path so
    both nodes are symmetric (E: data / F: log / H: backup), create the missing
    folders, and capture a baseline snapshot for the blog.

    Idempotent - safe to re-run.

    Usage:  .\00-Prep-Environment.ps1
            .\00-Prep-Environment.ps1 -SkipLogPathFix
#>
[CmdletBinding()]
param(
    [switch]$SkipLogPathFix,
    [switch]$NoRestart
)

. "$PSScriptRoot\Common.ps1"
$transcript = Start-LabTranscript -Name '00-prep'

try {
    Write-Step 'Phase 0 - environment preparation'

    # ------------------------------------------------------------------ 1. reach
    Write-Step '1. Connectivity'

    foreach ($node in @($Lab.NodeA, $Lab.NodeB)) {
        if (Test-Connection -ComputerName $node -Count 1 -Quiet) {
            Write-Ok "$node responds to ping"
        } else {
            throw "$node is not reachable."
        }

        if ($node -ieq $env:COMPUTERNAME) {
            Write-Ok "$node is this machine - no WinRM needed"
        } else {
            $null = Test-WSMan -ComputerName $node
            Write-Ok "$node WinRM OK"
        }

        if (Test-SqlUp -Server $node) {
            $v = Invoke-Ag -Server $node -Query "SELECT @@SERVERNAME AS srv, SERVERPROPERTY('ProductVersion') AS ver, SERVERPROPERTY('Edition') AS ed"
            Write-Ok ("$node SQL OK - {0} {1} / {2}" -f $v[0].srv, $v[0].ver, $v[0].ed)
        } else {
            throw "$node is not accepting SQL connections."
        }
    }

    # -------------------------------------------------------------- 2. dbatools
    Write-Step '2. dbatools probe (informational)'

    $dbatoolsWorks = $false
    $mod = Get-Module -ListAvailable dbatools | Select-Object -First 1
    if ($mod) {
        Write-Info "dbatools $($mod.Version) present - testing it against SQL 2025..."
        try {
            Import-Module dbatools -ErrorAction Stop -WarningAction SilentlyContinue
            Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true -ErrorAction SilentlyContinue
            $probe = Invoke-DbaQuery -SqlInstance $Lab.NodeA -Query 'SELECT 1 AS ok' -TrustServerCertificate -EnableException -ErrorAction Stop
            if ($probe.ok -eq 1) { $dbatoolsWorks = $true; Write-Ok 'dbatools works against 17.0' }
        } catch {
            Write-Warn "dbatools failed against SQL 2025: $($_.Exception.Message)"
        }
    } else {
        Write-Warn 'dbatools not installed'
    }
    Write-Info 'All lab querying uses System.Data.SqlClient regardless - dbatools is optional here.'

    # ------------------------------------------------- 3. fix the sql5 log path
    Write-Step "3. Fix the instance default LOG path on $($Lab.NodeB)"

    $before = Invoke-Ag -Server $Lab.NodeB -Query @"
SELECT SERVERPROPERTY('InstanceDefaultDataPath') AS data_path,
       SERVERPROPERTY('InstanceDefaultLogPath')  AS log_path,
       SERVERPROPERTY('InstanceDefaultBackupPath') AS backup_path;
"@
    Write-Info "Before: data=$($before[0].data_path)  log=$($before[0].log_path)  backup=$($before[0].backup_path)"

    $needsFix = ($before[0].log_path -notlike 'F:\*')

    if ($SkipLogPathFix) {
        Write-Warn 'Skipping the log path fix on request (-SkipLogPathFix).'
    }
    elseif (-not $needsFix) {
        Write-Ok "$($Lab.NodeB) default log path is already on F: - nothing to do."
    }
    else {
        Write-Info "$($Lab.NodeB) writes logs to $($before[0].log_path) - correcting to $($Lab.LogDir)"

        $fixResult = Invoke-OnNode -Node $Lab.NodeB -ArgumentList @($Lab.LogDir, $Lab.BackupDir, $Lab.Service) -ScriptBlock {
            param($LogDir, $BackupDir, $ServiceName)

            $out = [ordered]@{}

            # --- service account, needed for the ACLs
            $svc = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
            $account = $svc.StartName
            $out.ServiceAccount = $account

            # --- create the folders
            foreach ($dir in @($LogDir, $BackupDir)) {
                if (-not (Test-Path -LiteralPath $dir)) {
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                    $out["Created_$dir"] = $true
                } else {
                    $out["Created_$dir"] = $false
                }
                # grant the SQL service account full control (a brand new folder on a
                # previously unused volume carries no SQL ACL at all)
                $icacls = & icacls.exe $dir /grant ("{0}:(OI)(CI)F" -f $account) 2>&1
                $out["Acl_$dir"] = ($icacls -join ' ').Trim()
            }

            # --- locate the instance registry key rather than assuming its name
            $instKey = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
            $instId = (Get-ItemProperty -Path $instKey).$ServiceName
            $out.InstanceId = $instId

            $mssqlKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instId\MSSQLServer"
            $out.RegKey = $mssqlKey
            $out.DefaultLogBefore = (Get-ItemProperty -Path $mssqlKey -Name DefaultLog -ErrorAction SilentlyContinue).DefaultLog

            Set-ItemProperty -Path $mssqlKey -Name 'DefaultLog' -Value $LogDir -Type String
            $out.DefaultLogAfter = (Get-ItemProperty -Path $mssqlKey -Name DefaultLog).DefaultLog

            [pscustomobject]$out
        }

        Write-Ok "Service account on $($Lab.NodeB): $($fixResult.ServiceAccount)"
        Write-Ok "Registry: $($fixResult.RegKey)\DefaultLog  '$($fixResult.DefaultLogBefore)' -> '$($fixResult.DefaultLogAfter)'"
        Save-Snapshot -Name '00-sql5-logpath-fix' -Data $fixResult -Description 'Folder creation, ACLs and registry change on sql5' | Out-Null

        # --- restart so the new default is unambiguously in effect
        if ($NoRestart) {
            Write-Warn 'Skipping the service restart (-NoRestart). The new path takes effect after the next restart.'
        } else {
            Write-Info "Restarting $($Lab.Service) on $($Lab.NodeB) (secondary replica - the AG stays up on $($Lab.NodeA))"

            $agentWasRunning = Invoke-OnNode -Node $Lab.NodeB -ScriptBlock {
                (Get-Service SQLSERVERAGENT -ErrorAction SilentlyContinue).Status -eq 'Running'
            }

            Invoke-OnNode -Node $Lab.NodeB -ArgumentList @($Lab.Service) -ScriptBlock {
                param($ServiceName)
                Restart-Service -Name $ServiceName -Force
            }

            if (-not (Wait-SqlUp -Server $Lab.NodeB -TimeoutSec 300)) {
                throw "$($Lab.NodeB) did not come back after the restart."
            }

            if ($agentWasRunning) {
                Invoke-OnNode -Node $Lab.NodeB -ScriptBlock {
                    Start-Service SQLSERVERAGENT -ErrorAction SilentlyContinue
                }
                Write-Ok 'SQL Agent restarted on sql5'
            }
        }

        # --- verify
        $after = Invoke-Ag -Server $Lab.NodeB -Query @"
SELECT SERVERPROPERTY('InstanceDefaultDataPath') AS data_path,
       SERVERPROPERTY('InstanceDefaultLogPath')  AS log_path,
       SERVERPROPERTY('InstanceDefaultBackupPath') AS backup_path;
"@
        Write-Info "After:  data=$($after[0].data_path)  log=$($after[0].log_path)  backup=$($after[0].backup_path)"

        if ($after[0].log_path -like 'F:\*') {
            Write-Ok "$($Lab.NodeB) default log path is now on F: - nodes are symmetric."
        } else {
            Write-Bad "$($Lab.NodeB) default log path is STILL $($after[0].log_path)."
            Write-Warn 'Automatic seeding will place log files on the old path. Investigate before continuing.'
        }
    }

    # -------------------------------------------------------- 4. folders on sql4
    Write-Step '4. Folders on both nodes'

    foreach ($node in @($Lab.NodeA, $Lab.NodeB)) {
        $dirs = Invoke-OnNode -Node $node -ArgumentList @($Lab.DataDir, $Lab.LogDir, $Lab.BackupDir) -ScriptBlock {
            param($d, $l, $b)
            [pscustomobject]@{
                Node    = $env:COMPUTERNAME
                DataDir = "$d  -> $(Test-Path -LiteralPath $d)"
                LogDir  = "$l  -> $(Test-Path -LiteralPath $l)"
                BakDir  = "$b  -> $(Test-Path -LiteralPath $b)"
            }
        }
        Write-Info "$($dirs.Node): data $($dirs.DataDir)"
        Write-Info "$($dirs.Node): log  $($dirs.LogDir)"
        Write-Info "$($dirs.Node): bak  $($dirs.BakDir)"
    }

    # ----------------------------------------------------------- 5. the baseline
    Write-Step '5. Baseline snapshot'

    $primary = Get-AgPrimary
    Write-Ok "AG '$($Lab.AgName)' primary is currently: $primary"

    $replicas = Get-AgReplicaConfig -Server $primary
    Write-Host ''
    $replicas | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Save-Snapshot -Name '00-baseline-replicas' -Data $replicas -Description 'Replica configuration before any changes' | Out-Null

    $health = Get-AgHealth -Server $primary
    $health | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Save-Snapshot -Name '00-baseline-dbstate' -Data $health -Description 'Per-database AG state before any changes' | Out-Null

    $agDbs = @(Get-AgDatabases -Server $primary)
    Write-Info ("Databases currently in {0}: {1}" -f $Lab.AgName, ($(if ($agDbs.Count) { $agDbs -join ', ' } else { '(none)' })))

    # cluster resource settings we will need to park during the corruption window
    $clusterInfo = Get-AgClusterPolicy
    Write-Host ''
    $clusterInfo | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    if ($clusterInfo.RestartAction -eq 2) {
        Write-Warn 'RestartAction = 2 ("restart and fail over") - 04-Corrupt-Log.ps1 parks this during the corruption window.'
    }
    Save-Snapshot -Name '00-baseline-clusterpolicy' -Data $clusterInfo -Description 'agsql2 cluster resource restart/failover policy' | Out-Null

    $nodes = Get-ClusterNode | Select-Object Name, State, NodeWeight, DynamicWeight
    $nodes | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Save-Snapshot -Name '00-baseline-clusternodes' -Data $nodes -Description 'WSFC node state' | Out-Null

    Write-Step 'Phase 0 complete'
    Write-Ok "Next: .\01-Cleanup-AG.ps1"
}
finally {
    Stop-LabTranscript
    Write-Host ''
    Write-Host "  Transcript: $transcript" -ForegroundColor DarkGray
}
