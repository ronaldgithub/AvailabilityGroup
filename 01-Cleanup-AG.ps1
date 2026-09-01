<#
    01-Cleanup-AG.ps1

    Phase 1: take every database out of agsql2 and drop it on both nodes, leaving
    a healthy but empty availability group as the starting point for the lab.

    Driven from sys.availability_databases_cluster rather than a hardcoded list,
    so this doubles as the full-reset script later (it will pick up LogCorruptDemo).

    Non-AG databases (StackOverflow*, AdventureWorksLT2025, AI, PerformanceMonitor,
    DW*) are never touched.

    Usage:  .\01-Cleanup-AG.ps1            # shows what it would do
            .\01-Cleanup-AG.ps1 -Force     # actually does it
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [string[]]$Exclude = @()
)

. "$PSScriptRoot\Common.ps1"
$transcript = Start-LabTranscript -Name '01-cleanup'

try {
    Write-Step 'Phase 1 - clean sheet'

    $primary = Get-AgPrimary
    if (-not $primary) { throw "Cannot find the primary replica for '$($Lab.AgName)'." }
    $secondary = Get-AgSecondary
    Write-Ok "Primary: $primary   Secondary: $secondary"

    $agDbs = @(Get-AgDatabases -Server $primary | Where-Object { $Exclude -notcontains $_ })

    if ($agDbs.Count -eq 0) {
        Write-Ok "'$($Lab.AgName)' already contains no databases - nothing to clean up."
    }
    else {
        Write-Step 'Databases to be removed from the AG and DROPPED on both nodes'
        foreach ($db in $agDbs) {
            $sizes = Invoke-Ag -Server $primary -Query @"
SELECT CAST(SUM(size)/128.0 AS decimal(10,1)) AS size_mb
FROM sys.master_files WHERE database_id = DB_ID('$db');
"@ -NoThrow
            $mb = if ($sizes.Success -and $sizes.Rows.Count) { $sizes.Rows[0].size_mb } else { '?' }
            Write-Warn ("  {0,-16} {1,10} MB" -f $db, $mb)
        }

        if (-not $Force) {
            Write-Host ''
            Write-Warn 'Dry run. Re-run with -Force to actually remove and drop these databases.'
            return
        }

        # ------------------------------------------------ remove from the AG
        Write-Step "Removing databases from $($Lab.AgName)"
        foreach ($db in $agDbs) {
            $sql = "ALTER AVAILABILITY GROUP [$($Lab.AgName)] REMOVE DATABASE [$db];"
            Write-Info $sql
            $r = Invoke-Ag -Server $primary -Query $sql -NoThrow
            if ($r.Success) {
                Write-Ok "  removed $db from the AG"
            } else {
                Write-Bad "  $db : $($r.Error.Message)"
            }
        }

        Start-Sleep -Seconds 3

        # ------------------------------------------------------ drop the copies
        foreach ($node in @($primary, $secondary)) {
            Write-Step "Dropping databases on $node"
            foreach ($db in $agDbs) {
                $exists = Invoke-Ag -Server $node -Query "SELECT state_desc FROM sys.databases WHERE name = '$db';" -NoThrow
                if (-not $exists.Success -or $exists.Rows.Count -eq 0) {
                    Write-Info "  $db not present on $node"
                    continue
                }
                $state = $exists.Rows[0].state_desc
                Write-Info "  $db is $state on $node - dropping"

                # only meaningful for an ONLINE copy; a RESTORING secondary has no sessions
                if ($state -eq 'ONLINE') {
                    $null = Invoke-Ag -Server $node -Query `
                        "ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;" -NoThrow
                }

                $d = Invoke-Ag -Server $node -Query "DROP DATABASE [$db];" -NoThrow

                # A secondary copy can still hold its AG membership when data movement
                # was suspended at the time the primary removed the database - the
                # removal never reached it. SET HADR OFF detaches it locally.
                if (-not $d.Success -and $d.Error.Message -match 'joined to an availability group') {
                    Write-Warn "  $db on $node is still joined to the AG locally - running SET HADR OFF"
                    $h = Invoke-Ag -Server $node -Query "ALTER DATABASE [$db] SET HADR OFF;" -NoThrow
                    if ($h.Success) {
                        Write-Ok "  $db detached from the AG on $node"
                        $d = Invoke-Ag -Server $node -Query "DROP DATABASE [$db];" -NoThrow
                    } else {
                        Write-Bad "  SET HADR OFF failed for $db on $node : $($h.Error.Message)"
                    }
                }

                if ($d.Success) {
                    Write-Ok "  dropped $db on $node"
                } else {
                    Write-Bad "  $db on $node : $($d.Error.Message)"
                }
            }
        }
    }

    # ---------------------------------------------------------------- verify
    Write-Step 'Verification'

    $remaining = @(Get-AgDatabases -Server $primary)
    if ($remaining.Count -eq 0) {
        Write-Ok "sys.availability_databases_cluster for '$($Lab.AgName)' returns zero rows."
    } else {
        Write-Bad ("Still in the AG: {0}" -f ($remaining -join ', '))
    }

    $replicas = Get-AgReplicaConfig -Server $primary
    $replicas | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Save-Snapshot -Name '01-after-cleanup-replicas' -Data $replicas -Description 'Replica health after emptying the AG' | Out-Null

    $unhealthy = @($replicas | Where-Object { $_.health -ne 'HEALTHY' })
    if ($unhealthy.Count -eq 0) {
        Write-Ok 'Both replicas report HEALTHY.'
    } else {
        Write-Warn 'A replica is not HEALTHY yet - an empty AG can take a few seconds to settle. Re-check with Get-AgReplicaConfig.'
    }

    Write-Step 'Phase 1 complete'
    Write-Ok "Next: .\02-Create-DemoDb.ps1"
}
finally {
    Stop-LabTranscript
    Write-Host ''
    Write-Host "  Transcript: $transcript" -ForegroundColor DarkGray
}
