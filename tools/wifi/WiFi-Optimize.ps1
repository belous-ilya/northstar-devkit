#!/usr/bin/env pwsh
<#
.SYNOPSIS
    WiFi Check & Fix - Northstar DevKit
.DESCRIPTION
    Measures the WiFi connection, works out what is actually wrong, applies
    ONLY the fixes the measurements call for, then measures again and says
    whether it helped.

      1. MEASURE   signal and link rate, the router, the internet, a sign-in
                   page check, and how fast the DNS in use really answers
                   compared with Cloudflare, Google, Quad9 and OpenDNS.
      2. DIAGNOSE  each finding in plain words. Several findings carry no
                   fix on purpose - a weak signal, a busy channel or an
                   outage past the router cannot be repaired from this PC,
                   and the tool says so instead of resetting things.
      3. FIX       least invasive first: clear the DNS cache, switch DNS to
                   the fastest working resolver, renew the address, restart
                   the adapter. A healthy connection gets no changes at all.
      4. VERIFY    the same measurements again, side by side. A DNS switch
                   that made things worse is rolled back automatically.

    The Winsock/TCP-IP reset the old optimizer ran on every use (it drops
    the connection and needs a restart) now happens only with -Deep.

    DNS changes are undoable: the adapter's settings from BEFORE DevKit
    touched them are saved once and kept across runs. -RestoreDns puts them
    back - automatic DNS returns as automatic, not as pinned addresses.

    -DiagnoseOnly and -DryRun change nothing and need no administrator
    rights. Applying a fix does.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER DiagnoseOnly
    Measure and report, including what a fix run would do. Changes nothing.
.PARAMETER DryRun
    Same as -DiagnoseOnly (the name the other DevKit tools use).
.PARAMETER Deep
    Also renew the address and reset Winsock + TCP/IP, whatever the
    diagnosis says. Drops the connection and needs a restart to complete.
.PARAMETER Fast
    Skip the download/upload speed test at the end.
.PARAMETER KeepDNS
    Never change DNS settings.
.PARAMETER Force
    Skip the confirmation prompt before applying fixes.
.PARAMETER RestoreDns
    Put back the DNS settings saved before DevKit's first DNS change, then
    exit. Touches nothing else.
.EXAMPLE
    .\WiFi-Optimize.ps1 -DiagnoseOnly
    .\WiFi-Optimize.ps1
    .\WiFi-Optimize.ps1 -Fast -Force
    .\WiFi-Optimize.ps1 -Deep
    .\WiFi-Optimize.ps1 -RestoreDns
#>
[CmdletBinding()]
param(
    [switch]$DiagnoseOnly,
    [switch]$DryRun,
    [switch]$Deep,
    [switch]$Fast,
    [switch]$KeepDNS,
    [switch]$Force,
    [switch]$RestoreDns
)

$LibDir = Join-Path (Split-Path -Parent $PSScriptRoot) "lib"
$CommonModule = Join-Path $LibDir "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }
# All of the measuring and deciding lives in the shared WiFi library
# (unit-tested in tests/Unit/WiFiCore.Tests.ps1). This script prints, asks,
# and applies.
$WifiModule = Join-Path $LibDir "DevKit-WiFi.ps1"
if (Test-Path $WifiModule) {
    . $WifiModule
} else {
    Write-Host "ERROR: Required module not found: $WifiModule" -ForegroundColor Red
    exit 1
}

# The DNS undo file lives under %LOCALAPPDATA%\NorthstarDevKit\ - NOT %TEMP%:
# DevKit's own junk wiper (Close-OutSession) empties TEMP, which used to
# destroy the backup and leave -RestoreDns with nothing to restore.
$DnsBackupDir = Join-Path $env:LOCALAPPDATA "NorthstarDevKit"
$DnsBackupPath = Join-Path $DnsBackupDir "DevKit-WiFi-DnsBackup.json"
# Backups from before that move were written to %TEMP% - still honoured.
$LegacyDnsBackupPath = Join-Path $env:TEMP "DevKit-WiFi-DnsBackup.json"

$readOnlyRun = [bool]($DiagnoseOnly -or $DryRun)

# ==================== HELPERS ====================

function Exit-DevKitWifi {
    # Every exit pauses for Enter when a real console is attached, and never
    # under the Control Center's headless runner (-NonInteractive, stdin
    # closed), where Read-Host would throw.
    # -Force means "do not stop to ask me anything", so a scripted run with a
    # console attached must not sit at this prompt forever either.
    param([int]$Code = 0)
    if (-not $Force -and -not [Console]::IsInputRedirected) { Read-Host "`nPress Enter to exit" | Out-Null }
    exit $Code
}

function Write-DevKitFail {
    param([string]$Detail)
    Write-Host " FAIL" -ForegroundColor Red
    if ($Detail) { Write-DevKitInfo $Detail }
}

function Format-DevKitMs {
    param($Value)
    if ($null -eq $Value) { return 'n/a' }
    return ("{0} ms" -f [math]::Round([double]$Value, 0))
}

function Read-DevKitDnsBackup {
    <#
    .SYNOPSIS
        The parsed DNS undo file (new location first, then the pre-migration
        one), or $null when there is none or it cannot be read.
    #>
    foreach ($path in @($DnsBackupPath, $LegacyDnsBackupPath)) {
        if (Test-Path -LiteralPath $path) {
            try {
                return (Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
            } catch {
                Write-Host "  WARNING: could not read the DNS undo file at $path ($($_.Exception.Message))" -ForegroundColor Yellow
            }
        }
    }
    return $null
}

function Get-DevKitWifiDnsState {
    <#
    .SYNOPSIS
        The adapter's DNS as it stands right now, in the undo file's shape.
    #>
    param([Parameter(Mandatory = $true)]$Snapshot)
    $adapter = Get-NetAdapter -InterfaceIndex $Snapshot.InterfaceIndex -ErrorAction Stop
    $guid = [string]$adapter.InterfaceGuid
    return [PSCustomObject]@{
        Timestamp      = (Get-Date).ToString("o")
        InterfaceIndex = $Snapshot.InterfaceIndex
        InterfaceAlias = $adapter.Name
        InterfaceGuid  = $guid
        IPv4           = @((Get-DnsClientServerAddress -InterfaceIndex $Snapshot.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses)
        # IPv6 is best-effort throughout: an adapter with IPv6 unbound has no
        # IPv6 DNS to read or set, and that must not block the IPv4 change.
        IPv6           = @(try { (Get-DnsClientServerAddress -InterfaceIndex $Snapshot.InterfaceIndex -AddressFamily IPv6 -ErrorAction Stop).ServerAddresses } catch { })
        IPv4Static     = (Test-DevKitDnsIsStatic -InterfaceGuid $guid -AddressFamily IPv4)
        IPv6Static     = (Test-DevKitDnsIsStatic -InterfaceGuid $guid -AddressFamily IPv6)
    }
}

function Resolve-DevKitWifiDnsAdapter {
    <#
    .SYNOPSIS
        The WiFi adapter a saved DNS state belongs to, found by its GUID
        (then by name) - never by the saved interface index.
    .DESCRIPTION
        Interface indexes are reassigned by Windows (a driver reinstall, a
        USB adapter, a new virtual switch). Restoring by the index in the
        undo file could reset the DNS of whatever adapter holds that number
        today - an Ethernet port, a VPN. The GUID stays with the adapter.
        Throws when the adapter is gone or is not a WiFi adapter.
    #>
    param([Parameter(Mandatory = $true)]$State)

    $adapters = @(Get-NetAdapter -ErrorAction Stop)
    $match = $null
    if ([string]$State.InterfaceGuid) {
        $match = $adapters | Where-Object { [string]$_.InterfaceGuid -eq [string]$State.InterfaceGuid } | Select-Object -First 1
    }
    if (-not $match -and [string]$State.InterfaceAlias) {
        $match = $adapters | Where-Object { $_.Name -eq [string]$State.InterfaceAlias } | Select-Object -First 1
    }
    if (-not $match) { throw "the adapter the settings were saved from ('$($State.InterfaceAlias)') is no longer on this PC" }
    if ($match.PhysicalMediaType -ne 'Native 802.11') { throw "'$($match.Name)' is not a WiFi adapter" }
    return $match
}

function Restore-DevKitWifiDns {
    <#
    .SYNOPSIS
        Applies a saved DNS state: reset to automatic, then re-apply only
        the families that were set by hand (Get-DevKitDnsRestorePlan).
        Throws on failure.
    #>
    param([Parameter(Mandatory = $true)]$State)
    $adapter = Resolve-DevKitWifiDnsAdapter -State $State
    $plan = Get-DevKitDnsRestorePlan -Backup $State
    Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ResetServerAddresses -ErrorAction Stop
    if ($plan.IPv4.Count -gt 0) {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses $plan.IPv4 -ErrorAction Stop
    }
    if ($plan.IPv6.Count -gt 0) {
        try {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses $plan.IPv6 -ErrorAction Stop
        } catch {
            Write-Host "  WARNING: IPv6 DNS could not be re-applied ($($_.Exception.Message)); IPv4 DNS is restored." -ForegroundColor Yellow
        }
    }
}

function Save-DevKitWifiDnsUndo {
    <#
    .SYNOPSIS
        Writes the DNS undo file from a captured state when - and only when -
        Test-DevKitDnsBackupNeeded says the file may be replaced. Prints the
        step. Throws when the state has to be saved and cannot be.
    #>
    param([Parameter(Mandatory = $true)]$State)

    Write-DevKitStep "Saving today's DNS settings"
    $needsBackup = Test-DevKitDnsBackupNeeded -ExistingBackup (Read-DevKitDnsBackup) `
        -CurrentServers @($State.IPv4 + $State.IPv6) `
        -InterfaceAlias $State.InterfaceAlias `
        -CurrentIsStatic ([bool]($State.IPv4Static -or $State.IPv6Static))
    if ($needsBackup) {
        if (-not (Test-Path -LiteralPath $DnsBackupDir)) { New-Item -ItemType Directory -Path $DnsBackupDir -Force | Out-Null }
        $State | ConvertTo-Json | Set-Content -LiteralPath $DnsBackupPath -Encoding UTF8 -ErrorAction Stop
        Write-DevKitDone
        Write-DevKitInfo "Saved to $DnsBackupPath"
    } else {
        # The servers in place are ones DevKit applied on an earlier run. The
        # undo file already holds the settings from before THAT - overwriting
        # it would lose them.
        Write-DevKitSkip
        Write-DevKitInfo "Keeping the existing undo file (it holds the settings from before DevKit's earlier change)."
    }
}

function Show-DevKitWifiReport {
    param([Parameter(Mandatory = $true)]$Snapshot)

    Write-Host ""
    Write-Host "  CONNECTION" -ForegroundColor Cyan
    if (-not $Snapshot.AdapterPresent) {
        Write-Host "    No WiFi adapter." -ForegroundColor Red
        return
    }
    if (-not $Snapshot.Connected) {
        Write-Host "    $($Snapshot.InterfaceAlias): not connected." -ForegroundColor Red
        return
    }
    if ($Snapshot.Ssid) {
        $signal = $Snapshot.SignalPercent
        $signalColor = if ($null -eq $signal) { 'Gray' } elseif ($signal -ge 70) { 'Green' } elseif ($signal -ge 40) { 'Yellow' } else { 'Red' }
        Write-Host "    Network:  $($Snapshot.Ssid)" -ForegroundColor Gray
        Write-Host "    Signal:   $signal%" -ForegroundColor $signalColor -NoNewline
        Write-Host "  ($($Snapshot.Band), channel $($Snapshot.Channel), $($Snapshot.RadioType))" -ForegroundColor Gray
        if ($null -ne $Snapshot.RxMbps) {
            Write-Host "    Link:     $($Snapshot.RxMbps) Mbps down / $($Snapshot.TxMbps) Mbps up (what the radio negotiated, not internet speed)" -ForegroundColor Gray
        }
    } else {
        Write-Host "    $($Snapshot.InterfaceAlias): connected (Windows did not report the network's details)." -ForegroundColor Gray
    }
    Write-Host "    Address:  $(if ($Snapshot.IPv4) { $Snapshot.IPv4 } else { 'none' })   Router: $(if ($Snapshot.Gateway) { $Snapshot.Gateway } else { 'none' })" -ForegroundColor Gray

    if ($Snapshot.GatewayPing) {
        $g = $Snapshot.GatewayPing
        Write-Host ""
        Write-Host "  RESPONSE TIMES" -ForegroundColor Cyan
        Write-Host ("    Router:    {0}, {1}% lost, jitter {2}" -f (Format-DevKitMs $g.AverageLatency), $g.PacketLossPct, (Format-DevKitMs $g.JitterMs)) -ForegroundColor Gray
        if ($Snapshot.InternetPing) {
            $n = $Snapshot.InternetPing
            Write-Host ("    Internet:  {0}, {1}% lost, jitter {2}" -f (Format-DevKitMs $n.AverageLatency), $n.PacketLossPct, (Format-DevKitMs $n.JitterMs)) -ForegroundColor Gray
        }
    }

    if ($Snapshot.DnsCurrent) {
        Write-Host ""
        Write-Host "  DNS ANSWER TIME (median of real lookups, lower is better)" -ForegroundColor Cyan
        # A provider already in use is the "In use now" row - listing it a
        # second time under its own name would read as a different option.
        $inUse = @($Snapshot.DnsCurrent.Servers)
        $rows = @($Snapshot.DnsCurrent) + @($Snapshot.DnsCandidates | Where-Object {
                $_ -and @($_.Servers | Where-Object { $inUse -contains $_ }).Count -eq 0
            })
        foreach ($row in $rows) {
            if (-not $row) { continue }
            $label = if ($row.Name -eq 'Current') { "In use now" } else { $row.Name }
            $detail = if ([int]$row.FailurePct -gt 0) { "  ($($row.FailurePct)% of lookups failed)" } else { "" }
            $color = if ($null -eq $row.MedianMs -or [int]$row.FailurePct -ge 50) { 'Red' } elseif ($row.Name -eq 'Current') { 'White' } else { 'Gray' }
            Write-Host ("    {0} {1} {2}{3}" -f $label.PadRight(11), (Format-DevKitMs $row.MedianMs).PadRight(8), (@($row.Servers) -join ', '), $detail) -ForegroundColor $color
        }
    }
}

function Get-DevKitWifiActionText {
    param([string]$Action, $Diagnosis)
    switch ($Action) {
        'FlushDns' { return "Clear this PC's DNS cache." }
        'RestoreAutoDns' { return "Put this adapter's DNS back to automatic, so this network can hand out its own. Today's settings are saved first; undo with -RestoreDns." }
        'SwitchDns' { return "Switch DNS to $($Diagnosis.BestDns.Name) ($(@($Diagnosis.BestDns.Servers) -join ', ')). Today's settings are saved first; undo with -RestoreDns." }
        'RenewLease' { return "Ask the router for a fresh address (a brief disconnect)." }
        'RestartAdapter' { return "Turn the WiFi adapter off and on (disconnects for a few seconds)." }
        'ResetStack' { return "Reset Winsock and TCP/IP (drops the connection; needs a restart to complete)." }
    }
    return $Action
}

function Invoke-DevKitWifiSpeedTest {
    <#
    .SYNOPSIS
        Time-boxed download and upload throughput against Cloudflare.
    .DESCRIPTION
        Reads (then writes) for a fixed wall-clock window and reports the
        throughput that produced. A fixed-size payload with a timeout fails
        on exactly the slow connections this tool exists to diagnose; a
        window always yields a real number, however low.
    #>
    $client = $null
    $stream = $null
    try {
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        } catch { }
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(30)

        Write-DevKitStep "Measuring download speed"
        try {
            $window = 8
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $response = $client.GetAsync("https://speed.cloudflare.com/__down?bytes=50000000", [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            if (-not $response.IsSuccessStatusCode) { throw "the test server answered HTTP $([int]$response.StatusCode)" }
            $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $buffer = New-Object byte[] 65536
            [long]$total = 0
            while ($watch.Elapsed.TotalSeconds -lt $window) {
                # ReadAsync with a bounded wait, not a blocking Read: once the
                # headers have arrived HttpClient's own timeout no longer
                # applies, so a connection that stalls mid-download would
                # hang this tool (and, run from the app, hold its one tool
                # lane) until someone killed it.
                $pending = $stream.ReadAsync($buffer, 0, $buffer.Length)
                if (-not $pending.Wait(5000)) { throw "the download stalled" }
                $read = $pending.Result
                if ($read -le 0) { break }
                $total += $read
            }
            $watch.Stop()
            if ($total -le 0) { throw "no data arrived" }
            $mbps = [math]::Round(($total * 8) / $watch.Elapsed.TotalSeconds / 1000000, 1)
            Write-DevKitDone
            Write-Host "  Download: $mbps Mbps" -ForegroundColor $(if ($mbps -gt 50) { "Green" } elseif ($mbps -gt 10) { "Yellow" } else { "Red" })
        } catch {
            Write-DevKitFail "Could not measure download speed: $($_.Exception.Message)"
        } finally {
            if ($stream) { $stream.Dispose(); $stream = $null }
        }

        Write-DevKitStep "Measuring upload speed"
        try {
            $window = 6
            # How long one upload request may go unanswered. An upload that
            # stalls is a result, not an error: seen on a real connection
            # where downloads and pings were fine and about one upload
            # request in five got no answer for ten seconds or more. Left to
            # the client's own 30-second timeout, one such request used to
            # fail the whole measurement half a minute later with nothing to
            # show for it.
            $stallSeconds = 8
            # 256 KB a request (it was 1 MB): on a slow uplink more requests
            # finish inside the window, so there is something to report.
            $chunk = New-Object byte[] (256 * 1024)
            (New-Object System.Random).NextBytes($chunk)
            [long]$sent = 0
            $stalled = $false
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            while ($watch.Elapsed.TotalSeconds -lt $window) {
                $content = New-Object System.Net.Http.ByteArrayContent(, $chunk)
                $limit = New-Object System.Threading.CancellationTokenSource
                $reply = $null
                try {
                    $pending = $client.PostAsync("https://speed.cloudflare.com/__up", $content, $limit.Token)
                    if (-not $pending.Wait($stallSeconds * 1000)) {
                        # Give the request up so its connection is released,
                        # and stop: what got through before this is the
                        # measurement.
                        $limit.Cancel()
                        $stalled = $true
                        break
                    }
                    $reply = $pending.Result
                    if (-not $reply.IsSuccessStatusCode) { throw "the test server answered HTTP $([int]$reply.StatusCode)" }
                    $sent += $chunk.Length
                } finally {
                    if ($reply) { $reply.Dispose() }
                    $content.Dispose()
                    $limit.Dispose()
                }
            }
            $watch.Stop()
            if ($sent -le 0) {
                if ($stalled) { throw "the first upload request got no answer in $stallSeconds seconds" }
                throw "nothing was uploaded"
            }
            # Over the whole time spent, the stall included: that is the
            # throughput this connection actually delivered.
            $mbps = [math]::Round(($sent * 8) / $watch.Elapsed.TotalSeconds / 1000000, 1)
            Write-DevKitDone
            Write-Host "  Upload:   $mbps Mbps" -ForegroundColor $(if ($stalled) { "Yellow" } elseif ($mbps -gt 20) { "Green" } elseif ($mbps -gt 5) { "Yellow" } else { "Red" })
            if ($stalled) {
                Write-DevKitInfo "The upload stalled part-way: one request got no answer for $stallSeconds seconds, and that wait is counted in the figure above."
                Write-DevKitInfo "Uploads that stall while downloads and pings are fine point past this PC, at the router or the provider."
            }
        } catch {
            # A failed .NET task arrives wrapped; the inner message is the one
            # worth reading.
            $reason = $_.Exception
            while ($reason.InnerException) { $reason = $reason.InnerException }
            Write-DevKitFail "Could not measure upload speed: $($reason.Message)"
        }
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($client) { $client.Dispose() }
    }
}

# ==================== UNDO DNS ====================

if ($RestoreDns) {
    Write-Host ""
    Write-Host "   NORTHSTAR DevKit - WiFi (Undo DNS change)" -ForegroundColor Cyan
    Write-Host "     https://www.northstarcoding.com" -ForegroundColor Gray
    Write-Host ""

    $dnsBackup = Read-DevKitDnsBackup
    if (-not $dnsBackup) {
        Write-DevKitError "No DNS undo file found - checked both:"
        Write-DevKitInfo "  $DnsBackupPath"
        Write-DevKitInfo "  $LegacyDnsBackupPath (pre-migration location)"
        Write-DevKitInfo "To put DNS back to automatic by hand, run:"
        Write-DevKitInfo "  Set-DnsClientServerAddress -InterfaceIndex <n> -ResetServerAddresses"
        Exit-DevKitWifi -Code 1
    }

    $plan = Get-DevKitDnsRestorePlan -Backup $dnsBackup
    $describe = {
        param($Addresses)
        if (@($Addresses).Count -gt 0) { @($Addresses) -join ', ' } else { 'automatic (from the network)' }
    }
    Write-DevKitInfo "Saved $($dnsBackup.Timestamp) from '$($dnsBackup.InterfaceAlias)':"
    Write-DevKitInfo "  IPv4 DNS: $(& $describe $plan.IPv4)"
    Write-DevKitInfo "  IPv6 DNS: $(& $describe $plan.IPv6)"
    Write-Host ""

    # The read-only switches mean read-only here too, and the same
    # confirmation rules apply as for a fix: this changes a real setting.
    if ($readOnlyRun) {
        Write-DevKitInfo "Dry run: this is what Undo DNS would restore. Nothing was changed."
        Exit-DevKitWifi -Code 0
    }
    if (-not (Test-DevKitAdmin)) {
        Write-Host "  ERROR: Administrator privileges required to change DNS settings. Nothing was changed." -ForegroundColor Red
        Exit-DevKitWifi -Code 1
    }
    if (-not $Force) {
        if ([Console]::IsInputRedirected) {
            Write-DevKitInfo "Confirmation required but this session is non-interactive - re-run with -Force to apply. Nothing was changed."
            exit 0
        }
        $confirm = Read-Host "  Restore these DNS settings? (y/n)"
        if ($confirm -ne 'y') {
            Write-Host "  Cancelled. Nothing was changed.`n" -ForegroundColor Gray
            exit 0
        }
    }

    Write-DevKitStep "Restoring DNS on $($dnsBackup.InterfaceAlias)"
    try {
        Restore-DevKitWifiDns -State $dnsBackup
        Clear-DnsClientCache -ErrorAction SilentlyContinue
        Write-DevKitDone
    } catch {
        Write-DevKitFail "Could not restore DNS: $($_.Exception.Message)"
        Exit-DevKitWifi -Code 1
    }
    Exit-DevKitWifi -Code 0
}

# ==================== MEASURE ====================

$startTime = Get-Date

Write-Host ""
Write-Host "   NORTHSTAR DevKit - WiFi $(if ($readOnlyRun) { 'CHECK' } else { 'CHECK & FIX' })" -ForegroundColor Cyan
Write-Host "     https://www.northstarcoding.com" -ForegroundColor Gray
Write-Host ""

Write-DevKitStep "Measuring the connection (about 10 seconds)"
$before = Get-DevKitWifiSnapshot
Write-DevKitDone

Show-DevKitWifiReport -Snapshot $before

# ==================== DIAGNOSE ====================

$diagnosis = Get-DevKitWifiDiagnosis -Snapshot $before -KeepDns:$KeepDNS -Deep:$Deep

Write-Host ""
Write-Host "  WHAT WAS FOUND" -ForegroundColor Cyan
if ($diagnosis.Findings.Count -eq 0) {
    Write-Host "  - Nothing wrong: signal, router, internet and DNS all measure healthy." -ForegroundColor Green
} else {
    foreach ($item in $diagnosis.Findings) {
        $color = switch ($item.Severity) { 'error' { 'Red' } 'warn' { 'Yellow' } default { 'Gray' } }
        Write-Host "  - $($item.Message)" -ForegroundColor $color
    }
}

Write-Host ""
if ($diagnosis.Actions.Count -eq 0) {
    Write-Host "  NOTHING TO FIX" -ForegroundColor Cyan
    if ($diagnosis.Healthy) {
        Write-DevKitInfo "No setting on this PC would make this connection better, so nothing was changed."
    } else {
        Write-DevKitInfo "What was found cannot be repaired from this PC, so nothing was changed."
    }
} else {
    Write-Host "  $(if ($readOnlyRun) { 'WHAT A FIX RUN WOULD DO' } else { 'WHAT WILL BE DONE' })" -ForegroundColor Cyan
    $step = 0
    foreach ($action in $diagnosis.Actions) {
        $step++
        Write-Host "    $step. $(Get-DevKitWifiActionText -Action $action -Diagnosis $diagnosis)" -ForegroundColor Gray
    }
}

# "Can a speed test even run?" is answered by what lies BEYOND the router -
# a router that ignores ping says nothing about the connection through it.
function Test-DevKitWifiOnline {
    param($Snapshot)
    if (-not $Snapshot -or -not $Snapshot.Connected) { return $false }
    if ([string]$Snapshot.Portal -eq 'open') { return $true }
    return [bool]($Snapshot.InternetPing -and [int]$Snapshot.InternetPing.PacketLossPct -lt 100)
}
$canMeasureSpeed = Test-DevKitWifiOnline -Snapshot $before

if ($readOnlyRun -or $diagnosis.Actions.Count -eq 0) {
    if (-not $Fast -and $canMeasureSpeed) {
        Write-Host ""
        Invoke-DevKitWifiSpeedTest
    }
    if ($readOnlyRun -and $diagnosis.Actions.Count -gt 0) {
        Write-Host ""
        Write-DevKitInfo "Nothing was changed. Run WiFi Fix to apply the steps above."
    }
    Write-Host ""
    Exit-DevKitWifi -Code 0
}

# ==================== FIX ====================

if (-not (Test-DevKitAdmin)) {
    Write-Host ""
    Write-Host "  ERROR: Administrator privileges are required to apply these fixes." -ForegroundColor Red
    Write-Host "  Nothing was changed. Run from an elevated terminal, or use the DevKit app." -ForegroundColor Gray
    Exit-DevKitWifi -Code 1
}

if (-not $Force) {
    Write-Host ""
    if ([Console]::IsInputRedirected) {
        # Headless runner (Control Center's tool.run): stdin is closed, so a
        # y/n read would throw. The caution confirm dialog injects -Force for
        # approved runs, so reaching here means no approval was given.
        Write-DevKitInfo "Confirmation required but this session is non-interactive - re-run with -Force to apply. Nothing was changed."
        exit 0
    }
    $confirm = Read-Host "  Apply $(if ($diagnosis.Actions.Count -eq 1) { 'this step' } else { "these $($diagnosis.Actions.Count) steps" })? (y/n)"
    if ($confirm -ne 'y') {
        Write-Host "  Cancelled. Nothing was changed.`n" -ForegroundColor Gray
        exit 0
    }
}

Write-Host ""
Write-Host "  FIXING" -ForegroundColor Cyan

$failedActions = 0
$dnsBeforeChange = $null
$dnsSwitched = $false
$dnsMadeAutomatic = $false
$restartNeeded = $false

foreach ($action in $diagnosis.Actions) {
    switch ($action) {
        'FlushDns' {
            Write-DevKitStep "Clearing the DNS cache"
            try {
                Clear-DnsClientCache -ErrorAction Stop
                Write-DevKitDone
            } catch {
                Write-DevKitFail $_.Exception.Message
                $failedActions++
            }
        }

        'SwitchDns' {
            $target = $diagnosis.BestDns
            $ipv6Note = $null
            try {
                $dnsBeforeChange = Get-DevKitWifiDnsState -Snapshot $before
                Save-DevKitWifiDnsUndo -State $dnsBeforeChange
            } catch {
                # Without a saved state there is no undo and no rollback, so
                # the DNS change does not happen at all.
                Write-DevKitFail "Could not save the current DNS settings ($($_.Exception.Message)) - leaving DNS unchanged."
                $dnsBeforeChange = $null
                $failedActions++
                break
            }

            Write-DevKitStep "Switching DNS to $($target.Name)"
            try {
                Set-DnsClientServerAddress -InterfaceIndex $before.InterfaceIndex -ServerAddresses @($target.Servers) -ErrorAction Stop
                if (@($target.IPv6).Count -gt 0) {
                    # Best-effort: an adapter with IPv6 unbound cannot take
                    # IPv6 DNS, and that is no reason to undo the IPv4 change.
                    try {
                        Set-DnsClientServerAddress -InterfaceIndex $before.InterfaceIndex -ServerAddresses @($target.IPv6) -ErrorAction Stop
                    } catch {
                        $ipv6Note = "IPv6 DNS left as it was: $($_.Exception.Message)"
                    }
                }
                $applied = @((Get-DnsClientServerAddress -InterfaceIndex $before.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses)
                if ($applied -notcontains $target.Servers[0]) { throw "Windows reports DNS as $($applied -join ', ')" }
                Clear-DnsClientCache -ErrorAction SilentlyContinue
                $dnsSwitched = $true
                Write-DevKitDone
                if ($ipv6Note) { Write-DevKitInfo $ipv6Note }
            } catch {
                Write-DevKitFail "Could not set DNS: $($_.Exception.Message)"
                $failedActions++
                try { Restore-DevKitWifiDns -State $dnsBeforeChange } catch { Write-Host "  WARNING: could not put the previous DNS back either: $($_.Exception.Message)" -ForegroundColor Yellow }
            }
        }

        'RestoreAutoDns' {
            try {
                $dnsBeforeChange = Get-DevKitWifiDnsState -Snapshot $before
                Save-DevKitWifiDnsUndo -State $dnsBeforeChange
            } catch {
                Write-DevKitFail "Could not save the current DNS settings ($($_.Exception.Message)) - leaving DNS unchanged."
                $dnsBeforeChange = $null
                $failedActions++
                break
            }

            Write-DevKitStep "Putting DNS back to automatic"
            try {
                Set-DnsClientServerAddress -InterfaceIndex $before.InterfaceIndex -ResetServerAddresses -ErrorAction Stop
                Clear-DnsClientCache -ErrorAction SilentlyContinue
                $dnsMadeAutomatic = $true
                Write-DevKitDone
            } catch {
                Write-DevKitFail "Could not reset DNS: $($_.Exception.Message)"
                $failedActions++
            }
        }

        'RenewLease' {
            # Scoped to the WiFi adapter by name. The old optimizer ran a
            # bare `ipconfig /release`, which also dropped a docked laptop's
            # Ethernet connection.
            Write-DevKitStep "Renewing the address on $($before.InterfaceAlias)"
            ipconfig /release "$($before.InterfaceAlias)" | Out-Null
            ipconfig /renew "$($before.InterfaceAlias)" | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-DevKitDone } else { Write-DevKitFail "ipconfig /renew exited with code $LASTEXITCODE"; $failedActions++ }
        }

        'RestartAdapter' {
            Write-DevKitStep "Restarting $($before.InterfaceAlias)"
            try {
                Restart-NetAdapter -Name $before.InterfaceAlias -Confirm:$false -ErrorAction Stop
                # Back when it is Up and the router has handed out an address.
                $back = $false
                foreach ($attempt in 1..25) {
                    Start-Sleep -Seconds 1
                    $adapterNow = Get-NetAdapter -Name $before.InterfaceAlias -ErrorAction SilentlyContinue
                    $configNow = Get-NetIPConfiguration -InterfaceAlias $before.InterfaceAlias -ErrorAction SilentlyContinue
                    if ($adapterNow -and $adapterNow.Status -eq 'Up' -and $configNow -and $configNow.IPv4DefaultGateway) { $back = $true; break }
                }
                if ($back) { Write-DevKitDone } else { Write-DevKitFail "The adapter restarted but has not reconnected after 25 seconds."; $failedActions++ }
            } catch {
                Write-DevKitFail $_.Exception.Message
                $failedActions++
                # A restart is a disable followed by an enable. If it failed
                # between the two, do not leave the adapter switched off.
                try { Enable-NetAdapter -Name $before.InterfaceAlias -Confirm:$false -ErrorAction Stop } catch { }
            }
        }

        'ResetStack' {
            Write-DevKitStep "Resetting Winsock"
            netsh winsock reset | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-DevKitDone } else { Write-DevKitFail "netsh winsock reset exited with code $LASTEXITCODE"; $failedActions++ }

            Write-DevKitStep "Resetting TCP/IP"
            netsh int ip reset | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-DevKitDone } else { Write-DevKitFail "netsh int ip reset exited with code $LASTEXITCODE"; $failedActions++ }

            Write-DevKitStep "Restoring TCP defaults"
            netsh int tcp set global autotuninglevel=normal | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-DevKitDone } else { Write-DevKitFail "netsh int tcp set global exited with code $LASTEXITCODE"; $failedActions++ }
            $restartNeeded = $true
        }
    }
}

# ==================== VERIFY ====================

Write-Host ""
Write-DevKitStep "Measuring again"
Start-Sleep -Seconds 3
$after = Get-DevKitWifiSnapshot -SkipDnsCandidates
Write-DevKitDone

# A DNS switch has to earn its place. If lookups now fail, or answer clearly
# slower than before, put the previous settings straight back.
if ($dnsSwitched -and $dnsBeforeChange) {
    $dnsNow = $after.DnsCurrent
    $dnsThen = $before.DnsCurrent
    # Only a MEASURED failure counts. No DNS reading at all means the
    # connection is not back yet (adapter still reconnecting, no address) -
    # that says nothing about the new servers, and rolling a good switch back
    # for it would be wrong.
    $broken = ($dnsNow -and ($null -eq $dnsNow.MedianMs -or [int]$dnsNow.FailurePct -ge 50))
    $slower = ($dnsNow -and -not $broken -and $dnsThen -and $null -ne $dnsThen.MedianMs -and
        ([double]$dnsNow.MedianMs -gt ([double]$dnsThen.MedianMs + [math]::Max(20, 0.5 * [double]$dnsThen.MedianMs))))
    if (-not $dnsNow) {
        Write-DevKitInfo "The connection is not back yet, so the new DNS could not be checked. If names do not resolve once it is, run this tool with -RestoreDns."
    }
    if ($broken -or $slower) {
        Write-Host "  WARNING: the new DNS $(if ($broken) { 'is not answering' } else { 'answers slower than the old one did' }) - putting the previous settings back." -ForegroundColor Yellow
        Write-DevKitStep "Restoring the previous DNS"
        try {
            Restore-DevKitWifiDns -State $dnsBeforeChange
            Clear-DnsClientCache -ErrorAction SilentlyContinue
            Write-DevKitDone
            $dnsSwitched = $false
            Start-Sleep -Seconds 2
            $after = Get-DevKitWifiSnapshot -SkipDnsCandidates
        } catch {
            Write-DevKitFail "Could not restore DNS: $($_.Exception.Message). Run this tool with -RestoreDns."
            $failedActions++
        }
    }
}

$comparison = Compare-DevKitWifiSnapshot -Before $before -After $after

Write-Host ""
Write-Host "  BEFORE AND AFTER" -ForegroundColor Cyan
foreach ($row in $comparison.Rows) {
    if ($row.Verdict -eq 'n/a') { continue }
    $beforeText = if ($null -ne $row.Before) { "$($row.Before) $($row.Unit)" } else { 'n/a' }
    $afterText = if ($null -ne $row.After) { "$($row.After) $($row.Unit)" } else { 'n/a' }
    $color = switch ($row.Verdict) { 'better' { 'Green' } 'worse' { 'Yellow' } default { 'Gray' } }
    Write-Host ("    {0} {1} -> {2} {3}" -f $row.Metric.PadRight(22), $beforeText.PadRight(10), $afterText.PadRight(10), $row.Verdict) -ForegroundColor $color
}

Write-Host ""
switch ($comparison.Overall) {
    'better' { Write-Host "  RESULT: the connection measures better than before." -ForegroundColor Green }
    'worse' { Write-Host "  RESULT: the connection measures WORSE than before. $(if ($dnsSwitched) { 'Undo the DNS change with -RestoreDns.' })" -ForegroundColor Yellow }
    default { Write-Host "  RESULT: no measurable change. What is slowing this connection is not something these fixes reach." -ForegroundColor Gray }
}

if (-not $Fast -and (Test-DevKitWifiOnline -Snapshot $after)) {
    Write-Host ""
    Invoke-DevKitWifiSpeedTest
}

# ==================== SUMMARY ====================

$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 0)
Write-Host ""
Write-Host "  Finished in $duration seconds." -ForegroundColor Gray
if ($dnsSwitched) {
    Write-Host "  DNS is now $($diagnosis.BestDns.Name). Undo anytime: .\WiFi-Optimize.ps1 -RestoreDns" -ForegroundColor Gray
}
if ($dnsMadeAutomatic) {
    Write-Host "  DNS is now automatic (handed out by this network). The previous manual settings can be put back with -RestoreDns." -ForegroundColor Gray
}
if ($restartNeeded) {
    Write-Host ""
    Write-Host "  IMPORTANT: restart Windows to complete the network stack reset." -ForegroundColor Yellow
}
if ($failedActions -gt 0) {
    Write-Host "  $failedActions step(s) failed - see above." -ForegroundColor Red
}
Write-Host ""
Write-Host "  https://www.northstarcoding.com" -ForegroundColor DarkGray
Write-Host ""

# Explicit exit code: WiFi-FastMode.ps1 forwards $LASTEXITCODE, which would
# otherwise be whatever the last native netsh/ipconfig call returned.
Exit-DevKitWifi -Code $(if ($failedActions -gt 0) { 1 } else { 0 })
