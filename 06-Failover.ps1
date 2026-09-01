<#
    06-Failover.ps1 - Author: Ronald.de.Groot@OpenData.nl and Claude Code
    Github -> https://github.com/ronaldgithub/AvailabilityGroup

    Planned manual failover of agsql2 to the healthy replica.

    A planned failover requires every database in the AG to be SYNCHRONIZED. If
    the corrupted region had not been hardened on the secondary before the damage
    was done, that will not be true, and the only way across is a forced failover
    with possible data loss. This script detects that and refuses to force it
    unless you ask, because which of the two happens is itself the finding.

    Usage:  .\06-Failover.ps1
            .\06-Failover.ps1 -Pause
            .\06-Failover.ps1 -AllowDataLoss        # forced failover fallback

#>
[CmdletBinding()]
param(
    [string]$To,
    [switch]$AllowDataLoss,
    [int]$WaitSec = 300,
    [switch]$Pause
)

. "$PSScriptRoot\Common.ps1"
$Lab.PauseForScreenshots = [bool]$Pause
$transcript = Start-LabTranscript -Name '06-failover'

try {
    Write-Step 'Planned manual failover'

    $db = $Lab.DemoDb
    $from = Get-AgPrimary
    if (-not $from) { throw "Cannot determine the current primary of '$($Lab.AgName)'." }
    if (-not $To) { $To = if ($from -eq $Lab.NodeA) { $Lab.NodeB } else { $Lab.NodeA } }

    Write-Ok "Current primary : $from"
    Write-Ok "Failing over to : $To"

    if (-not (Test-SqlUp -Server $To)) { throw "$To is not reachable - cannot fail over to it." }

    # ------------------------------------------------------------ 1. preflight
    Write-Step '1. Preflight - every database in the AG must be SYNCHRONIZED'

    $health = Get-AgHealth -Server $from
    $health | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Save-Snapshot -Name '06-pre-failover-health' -Data $health -Description 'AG state immediately before the failover' | Out-Null

    $notSync = @($health | Where-Object { $_.sync_state -ne 'SYNCHRONIZED' })
    $canPlan = ($notSync.Count -eq 0)

    if ($canPlan) {
        Write-Ok 'All databases are SYNCHRONIZED - a planned failover with no data loss is possible.'
        Write-Info 'This is the proof that synchronous commit protected the secondary copy of the log.'
    } else {
        Write-Bad 'Not every database is SYNCHRONIZED:'
        $notSync | ForEach-Object { Write-Bad ("  {0} on {1}: {2}" -f $_.db_name, $_.replica, $_.sync_state) }
        Write-Warn 'A planned failover is not possible. The corrupted log region was probably not'
        Write-Warn 'hardened on the secondary before the damage, so the log reader cannot ship it.'
        if (-not $AllowDataLoss) {
            throw "Refusing to force a failover. Re-run with -AllowDataLoss to do FORCE_FAILOVER_ALLOW_DATA_LOSS (and capture that outcome - it is a real result worth writing up)."
        }
    }

    Wait-ForScreenshot -Moment 'Just before the failover' -Capture @(
        'The health table above showing SYNCHRONIZED on both replicas',
        'SSMS AG dashboard before the role swap'
    )

    # ------------------------------------------------------------- 2. fail over
    Write-Step "2. Failing over to $To"

    if ($canPlan) {
        $sql = "ALTER AVAILABILITY GROUP [$($Lab.AgName)] FAILOVER;"
    } else {
        $sql = "ALTER AVAILABILITY GROUP [$($Lab.AgName)] FORCE_FAILOVER_ALLOW_DATA_LOSS;"
        Write-Warn 'FORCED FAILOVER - data loss is possible.'
    }

    Write-Info "On $To : $sql"
    $f = Invoke-Ag -Server $To -Query $sql -TimeoutSec 300 -NoThrow
    if ($f.Success) {
        Write-Ok 'Failover command accepted'
    } else {
        Write-Bad "Failover failed: $($f.Error.Message)"
        foreach ($d in $f.Error.Details) { Write-Bad ("  Msg {0}: {1}" -f $d.Number, $d.Message) }
        throw 'Failover did not complete.'
    }

    # ------------------------------------------------------- 3. confirm the swap
    Write-Step '3. Confirming the new role assignment'

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $newPrimary = $null
    while ($sw.Elapsed.TotalSeconds -lt $WaitSec) {
        Start-Sleep -Seconds 3
        $newPrimary = Get-AgPrimary
        if ($newPrimary -eq $To) { break }
    }

    if ($newPrimary -eq $To) {
        Write-Ok ("$To is now PRIMARY (took {0:N0}s)" -f $sw.Elapsed.TotalSeconds)
    } else {
        Write-Bad "Expected $To to be primary, but the primary is '$newPrimary'."
    }

    $replicas = Get-AgReplicaConfig -Server $To
    $replicas | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Save-Snapshot -Name '06-post-failover-replicas' -Data $replicas -Description 'Replica roles after the failover' | Out-Null

    $health2 = Get-AgHealth -Server $To
    $health2 | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Save-Snapshot -Name '06-post-failover-health' -Data $health2 -Description 'AG state after the failover' | Out-Null

    $oldPrimaryRow = @($health2 | Where-Object { $_.db_name -eq $db -and $_.replica -eq $from })
    if ($oldPrimaryRow.Count -gt 0) {
        $r = $oldPrimaryRow[0]
        Write-Info ("Old primary {0}: {1} / {2} suspended={3} {4}" -f `
                    $from, $r.sync_state, $r.sync_health, $r.suspended, $r.suspend_reason)
        if ($r.suspended -or $r.sync_state -ne 'SYNCHRONIZED') {
            Write-Warn "$from now holds the corrupt copy and cannot rejoin - 07-Repair-Reseed.ps1 fixes that."
        }
    }

    $cluster = Get-AgClusterPolicy
    $cluster | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

    Wait-ForScreenshot -Moment 'Roles swapped' -Capture @(
        "SSMS AG dashboard - $To is now primary",
        "The old primary $from showing as not synchronizing / suspended",
        'Failover Cluster Manager showing the agsql2 resource owner'
    )

    Write-Step 'Failover complete'
    Write-Ok 'Next: .\07-Repair-Reseed.ps1'
}
finally {
    Stop-LabTranscript
    Write-Host ''
    Write-Host "  Transcript: $transcript" -ForegroundColor DarkGray
}
