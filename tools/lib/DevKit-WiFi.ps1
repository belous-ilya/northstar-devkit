#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Northstar DevKit - WiFi logic shared by the WiFi tools
.DESCRIPTION
    Everything the WiFi tools know, in one dot-sourceable file, so the
    scripts in tools/wifi/ only decide what to print and what to apply:

      PURE (unit-tested in tests/Unit/WiFiCore.Tests.ps1, no hardware):
        ConvertFrom-DevKitWlanScan        netsh "show networks" -> networks
        ConvertFrom-DevKitWlanInterface   netsh "show interfaces" -> adapters
        Get-DevKitWifiChannelLoad         who is crowding which channel
        Get-DevKitWifiScanAdvice          what a scan means for the user
        Get-DevKitWifiDiagnosis           measurements -> findings + fixes
        Compare-DevKitWifiSnapshot        before/after -> did it help
        Test-DevKitDnsBackupNeeded        may the DNS undo file be replaced

      MEASURING (read-only, touch the network but change nothing):
        Measure-DevKitPingLatency, Measure-DevKitDnsResolver,
        Test-DevKitCaptivePortal, Get-DevKitWifiSnapshot,
        Invoke-DevKitWlanRescan (asks the radio for a fresh scan)

    Nothing in this file changes a setting. The mutating steps (DNS, lease,
    adapter, network stack) live in tools/wifi/WiFi-Optimize.ps1, behind its
    confirmation.

    The design rule the old optimizer broke: MEASURE FIRST, then apply only
    the fix the measurements call for, then measure again and say whether it
    helped. It used to run the heaviest repair there is (Winsock + TCP/IP
    reset, which drops the connection and wants a reboot) on every run,
    whatever was actually wrong, and never looked at the result.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
#>

# Scope-aware double-load guard (same reasoning as DevKit-McpList.ps1): a
# $global: flag would skip loading for a sibling script in a scope that never
# saw the functions.
if (Get-Command Get-DevKitWifiDiagnosis -ErrorAction SilentlyContinue) { return }

# ==================== PARSERS (pure) ====================

function ConvertTo-DevKitWifiBand {
    <#
    .SYNOPSIS
        Normalizes a band to '2.4 GHz' / '5 GHz' / '6 GHz', from netsh's
        Band text when present, otherwise from the channel number.
    .DESCRIPTION
        Windows 10 prints no Band line at all, so the channel is the only
        clue there: 1-14 is 2.4 GHz and everything else is treated as 5 GHz.
        (6 GHz reuses low channel numbers, which is exactly why the Band
        line wins whenever netsh provides one.)
    #>
    param(
        [AllowEmptyString()][AllowNull()][string]$BandText = '',
        [int]$Channel = 0
    )
    if ($BandText -match '(\d+(?:[.,]\d+)?)\s*GHz') {
        $number = [double]($matches[1] -replace ',', '.')
        if ($number -lt 3) { return '2.4 GHz' }
        if ($number -lt 5.9) { return '5 GHz' }
        return '6 GHz'
    }
    if ($Channel -ge 1 -and $Channel -le 14) { return '2.4 GHz' }
    if ($Channel -gt 14) { return '5 GHz' }
    return ''
}

function ConvertFrom-DevKitWlanScan {
    <#
    .SYNOPSIS
        Parses "netsh wlan show networks mode=Bssid" output into networks.
    .DESCRIPTION
        Lines are classified by the SHAPE OF THEIR VALUE wherever possible
        ("87%" is a signal, "802.11ax" a radio type, "5 GHz" a band) rather
        than by their English label, so the per-access-point data survives a
        non-English Windows. Authentication/Encryption fall back to their
        position in the block when no English label matched.

        The BSSID check runs BEFORE the SSID check on purpose: "SSID" is a
        substring of "BSSID", and an unanchored SSID pattern would read every
        access-point line as a new network named after a MAC address.

        A hidden network (netsh prints "SSID 3 : " with nothing after the
        colon) is its own network with an empty SSID. The old parser required
        a name, so a hidden network's access points were silently credited to
        whichever network was listed just above it.
    .PARAMETER RawOutput
        The raw text captured from `netsh wlan show networks mode=Bssid`.
    .OUTPUTS
        Array of hashtables: SSID, Auth, Encryption, BSSIDs = array of
        hashtables (MAC, Signal, Channel, Band, RadioType, Utilization,
        Stations). Utilization/Stations are $null when netsh did not report
        them (older access points, older Windows).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$RawOutput
    )

    $results = @()
    $net = $null
    $bss = $null
    $headers = @()

    # Closes the network being built: positional fallbacks, band from channel.
    $complete = {
        param($Network, $HeaderLines)
        if ($null -eq $Network.Auth -and $null -eq $Network.Encryption -and @($HeaderLines).Count -ge 3) {
            # No English label matched and the block has the standard three
            # header lines (network type, authentication, encryption).
            $Network.Auth = $HeaderLines[1]
            $Network.Encryption = $HeaderLines[2]
        }
        foreach ($ap in $Network.BSSIDs) {
            $ap.Band = ConvertTo-DevKitWifiBand -BandText $ap.Band -Channel $ap.Channel
        }
        return $Network
    }

    foreach ($line in ($RawOutput -split "\r?\n")) {
        if ($line -match '^\s*BSSID\s+\d+\s*:\s*(.+?)\s*$') {
            if ($net) {
                $bss = @{ MAC = $matches[1]; Signal = 0; Channel = 0; Band = ''; RadioType = ''; Utilization = $null; Stations = $null }
                $net.BSSIDs += $bss
            }
            continue
        }
        if ($line -match '^\s*SSID\s+\d+\s*:\s*(.*?)\s*$') {
            $name = $matches[1]
            if ($net -and $net.BSSIDs.Count -gt 0) { $results += (& $complete $net $headers) }
            $net = @{ SSID = $name; Auth = $null; Encryption = $null; BSSIDs = @() }
            $bss = $null
            $headers = @()
            continue
        }
        if (-not $net) { continue }
        if ($line -notmatch '^\s*(.+?)\s*:\s*(.*?)\s*$') { continue }
        $key = $matches[1]
        $value = $matches[2]

        if (-not $bss) {
            if ($key -eq 'Authentication') { $net.Auth = $value }
            elseif ($key -eq 'Encryption') { $net.Encryption = $value }
            $headers += $value
            continue
        }

        if ($value -match '^(\d{1,3})\s*%$') { $bss.Signal = [int]$matches[1]; continue }
        if ($value -match '^\d+\s*\(\s*(\d{1,3})\s*%\s*\)$') { $bss.Utilization = [int]$matches[1]; continue }
        if ($value -match '^802\.11') { $bss.RadioType = $value; continue }
        if ($value -match 'GHz') { $bss.Band = $value; continue }
        if ($value -match '^\d{1,3}$') {
            if ($key -eq 'Channel' -or $bss.Channel -eq 0) {
                # English label, or (other locales) the first bare number in
                # the block - Signal, Radio type and Band never look like one.
                if ($key -eq 'Channel' -or $key -notmatch 'Stations') { $bss.Channel = [int]$value; continue }
            }
            if ($key -match 'Stations') { $bss.Stations = [int]$value }
        }
    }

    if ($net -and $net.BSSIDs.Count -gt 0) { $results += (& $complete $net $headers) }

    # The unary comma is required: PowerShell flattens a 0- or 1-element
    # array as it crosses the function-return boundary, and a caller handed a
    # bare hashtable would report its KEY count as the number of networks.
    return , $results
}

function ConvertFrom-DevKitWlanInterface {
    <#
    .SYNOPSIS
        Parses "netsh wlan show interfaces" output into one object per
        wireless adapter, including what it is connected to right now.
    .DESCRIPTION
        Same value-shape approach as ConvertFrom-DevKitWlanScan. An adapter
        counts as Connected when it reports an access-point BSSID - the
        literal state word is localized, the MAC address is not.
    .OUTPUTS
        Array of PSCustomObjects: Name, Description, State, Connected, Ssid,
        Bssid, Band, Channel, RadioType, Auth, SignalPercent, RssiDbm,
        RxMbps, TxMbps. Unknown values are $null (or '' for text).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$RawOutput
    )

    $interfaces = @()
    $current = $null
    $newInterface = {
        @{
            Name = ''; Description = ''; State = ''; Ssid = ''; Bssid = ''; Band = ''; Channel = 0
            RadioType = ''; Auth = ''; SignalPercent = $null; RssiDbm = $null; RxMbps = $null; TxMbps = $null
        }
    }
    $macPattern = '^[0-9a-fA-F]{2}([:-][0-9a-fA-F]{2}){5}$'
    $afterBand = $false

    foreach ($line in ($RawOutput -split "\r?\n")) {
        if ($line -notmatch '^\s*(.+?)\s*:\s*(.*?)\s*$') { continue }
        $key = $matches[1]
        $value = $matches[2]

        if ($key -eq 'Name') {
            if ($current) { $interfaces += $current }
            $current = & $newInterface
            $current.Name = $value
            $afterBand = $false
            continue
        }
        if (-not $current) {
            # Non-English output has no "Name" label; the first labelled
            # line after the "There is 1 interface" sentence is the name.
            if ($value -match 'interface' -or $key -match 'interface') { continue }
            $current = & $newInterface
            $current.Name = $value
            continue
        }

        $wasAfterBand = $afterBand
        $afterBand = $false

        if ($key -eq 'Description') { $current.Description = $value; continue }
        if ($key -eq 'State') { $current.State = $value; continue }
        if ($key -eq 'SSID') { $current.Ssid = $value; continue }
        if ($key -eq 'Authentication') { $current.Auth = $value; continue }
        if ($key -match 'BSSID' -and $value -match $macPattern) { $current.Bssid = $value.ToLowerInvariant(); continue }
        if ($value -match '^(\d{1,3})\s*%$') { $current.SignalPercent = [int]$matches[1]; continue }
        if ($value -match '^802\.11') { $current.RadioType = $value; continue }
        if ($value -match 'GHz') { $current.Band = $value; $afterBand = $true; continue }
        if ($key -match '\(Mbps\)' -and $value -match '^\d+(?:[.,]\d+)?$') {
            $rate = [double]($value -replace ',', '.')
            if ($null -eq $current.RxMbps) { $current.RxMbps = $rate } elseif ($null -eq $current.TxMbps) { $current.TxMbps = $rate }
            continue
        }
        if ($key -eq 'Rssi' -and $value -match '^-?\d+$') { $current.RssiDbm = [int]$value; continue }
        if ($value -match '^\d{1,3}$' -and ($key -eq 'Channel' -or ($wasAfterBand -and $current.Channel -eq 0))) {
            $current.Channel = [int]$value
            continue
        }
    }
    if ($current) { $interfaces += $current }

    $objects = @()
    foreach ($iface in $interfaces) {
        $objects += [PSCustomObject]@{
            Name          = $iface.Name
            Description   = $iface.Description
            State         = $iface.State
            Connected     = [bool]$iface.Bssid
            Ssid          = $iface.Ssid
            Bssid         = $iface.Bssid
            Band          = ConvertTo-DevKitWifiBand -BandText $iface.Band -Channel $iface.Channel
            Channel       = $iface.Channel
            RadioType     = $iface.RadioType
            Auth          = $iface.Auth
            SignalPercent = $iface.SignalPercent
            RssiDbm       = $iface.RssiDbm
            RxMbps        = $iface.RxMbps
            TxMbps        = $iface.TxMbps
        }
    }
    return , $objects
}

# ==================== SCAN ANALYSIS (pure) ====================

function Get-DevKitWifiBestSignal {
    <#
    .SYNOPSIS
        Strongest access-point signal (percent) of a parsed network, 0 when none.
    #>
    param([Parameter(Mandatory = $true)]$Network)
    $best = 0
    foreach ($ap in @($Network.BSSIDs)) {
        if ($ap -and [int]$ap.Signal -gt $best) { $best = [int]$ap.Signal }
    }
    return $best
}

function Get-DevKitWifiChannelLoad {
    <#
    .SYNOPSIS
        One row per (band, channel) in a scan: how many access points sit on
        it, how many overlap it, and how busy its airtime is.
    .DESCRIPTION
        Two different measures of "crowded", because they are not the same
        thing:
          - Overlapping: access points whose channel interferes with this
            one. On 2.4 GHz channels are 5 MHz apart but 20 MHz wide, so
            anything within 4 channels overlaps (which is why only 1, 6 and
            11 are clean). On 5/6 GHz only the same channel counts.
          - Utilization: the busiest "channel utilization" any access point
            on the channel reported - real airtime in use, when the access
            point advertises it. $null when none did.
    .OUTPUTS
        Array of PSCustomObjects (Band, Channel, AccessPoints, Overlapping,
        StrongestSignal, Utilization), sorted by band then channel.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Networks)

    $aps = @()
    foreach ($net in @($Networks)) {
        foreach ($ap in @($net.BSSIDs)) {
            if ($ap -and [int]$ap.Channel -gt 0) { $aps += $ap }
        }
    }

    $rows = @()
    foreach ($group in ($aps | Group-Object { "$($_.Band)|$($_.Channel)" })) {
        $first = $group.Group[0]
        $band = [string]$first.Band
        $channel = [int]$first.Channel
        $sameBand = @($aps | Where-Object { [string]$_.Band -eq $band })
        if ($band -eq '2.4 GHz') {
            $overlapping = @($sameBand | Where-Object { [math]::Abs([int]$_.Channel - $channel) -le 4 }).Count
        } else {
            $overlapping = $group.Count
        }
        $utilizations = @($group.Group | Where-Object { $null -ne $_.Utilization } | ForEach-Object { [int]$_.Utilization })
        $rows += [PSCustomObject]@{
            Band            = $band
            Channel         = $channel
            AccessPoints    = $group.Count
            Overlapping     = $overlapping
            StrongestSignal = ($group.Group | ForEach-Object { [int]$_.Signal } | Measure-Object -Maximum).Maximum
            Utilization     = if ($utilizations.Count -gt 0) { ($utilizations | Measure-Object -Maximum).Maximum } else { $null }
        }
    }
    return , @($rows | Sort-Object Band, Channel)
}

function Get-DevKitWifiScanAdvice {
    <#
    .SYNOPSIS
        Turns a scan (plus the current connection, if any) into advice.
    .DESCRIPTION
        Pure. Every line is something the user can act on; a quiet scan
        produces a single "looks good" line rather than filler.
    .PARAMETER Networks
        Output of ConvertFrom-DevKitWlanScan.
    .PARAMETER Current
        The connected adapter from ConvertFrom-DevKitWlanInterface, or $null.
    .OUTPUTS
        Array of PSCustomObjects (Level = 'good' | 'info' | 'warn', Text).
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Networks,
        $Current = $null
    )

    $advice = @()
    $add = { param($Level, $Text) [PSCustomObject]@{ Level = $Level; Text = $Text } }
    $connected = $Current -and $Current.Connected

    if ($connected) {
        $currentBssid = ([string]$Current.Bssid).ToLowerInvariant()
        $mine = @($Networks | Where-Object { [string]$_.SSID -eq [string]$Current.Ssid }) | Select-Object -First 1
        $myAp = $null
        if ($mine) {
            $myAp = @($mine.BSSIDs | Where-Object { ([string]$_.MAC).ToLowerInvariant() -eq $currentBssid }) | Select-Object -First 1
        }
        $signal = if ($null -ne $Current.SignalPercent) { [int]$Current.SignalPercent } elseif ($myAp) { [int]$myAp.Signal } else { $null }

        if ($null -ne $signal -and $signal -lt 40) {
            $advice += (& $add 'warn' "Your signal is weak ($signal%). Move closer to the access point - no setting on this PC fixes distance.")
        }

        if ($mine) {
            $others = @($mine.BSSIDs | Where-Object { ([string]$_.MAC).ToLowerInvariant() -ne $currentBssid })
            if ([string]$Current.Band -eq '2.4 GHz') {
                $faster = @($others | Where-Object { [string]$_.Band -ne '2.4 GHz' -and [int]$_.Signal -ge 50 } | Sort-Object { [int]$_.Signal } -Descending) | Select-Object -First 1
                if ($faster) {
                    $advice += (& $add 'info' "You are on 2.4 GHz, but '$($Current.Ssid)' is also in range on $($faster.Band) at $($faster.Signal)% - usually much faster. Disconnect and reconnect, or set the adapter's preferred band to $($faster.Band).")
                }
            }
            if ($null -ne $signal) {
                $stronger = @($others | Where-Object { [int]$_.Signal -ge ($signal + 20) } | Sort-Object { [int]$_.Signal } -Descending) | Select-Object -First 1
                if ($stronger) {
                    $advice += (& $add 'info' "Another access point of '$($Current.Ssid)' is much stronger here ($($stronger.Signal)% on channel $($stronger.Channel)). Turning WiFi off and on makes Windows pick it.")
                }
            }
        }

        if ($myAp) {
            $load = @(Get-DevKitWifiChannelLoad -Networks $Networks | Where-Object { $_.Band -eq [string]$myAp.Band -and $_.Channel -eq [int]$myAp.Channel }) | Select-Object -First 1
            if ($null -ne $myAp.Utilization -and [int]$myAp.Utilization -ge 60) {
                $advice += (& $add 'warn' "Your access point reports its channel $($myAp.Utilization)% busy. That is congestion at the router, not a problem on this PC.")
            } elseif ($load -and $load.Band -eq '2.4 GHz' -and $load.Overlapping -ge 5) {
                $advice += (& $add 'warn' "Channel $($load.Channel) is crowded: $($load.Overlapping) access points overlap it. A 5 GHz network, if one is offered, avoids this.")
            }
        }
    }

    $secured = @($Networks | Where-Object { $_.Auth -and [string]$_.Auth -ne 'Open' } | Sort-Object { Get-DevKitWifiBestSignal -Network $_ } -Descending) | Select-Object -First 1
    if ($secured -and -not $connected) {
        $advice += (& $add 'info' "Strongest secured network: '$($secured.SSID)' ($(Get-DevKitWifiBestSignal -Network $secured)%, $($secured.Auth)).")
    }
    $open = @($Networks | Where-Object { [string]$_.Auth -eq 'Open' -and (Get-DevKitWifiBestSignal -Network $_) -ge 40 } | Sort-Object { Get-DevKitWifiBestSignal -Network $_ } -Descending) | Select-Object -First 1
    if ($open -and -not $connected) {
        $advice += (& $add 'info' "Strongest open network: '$($open.SSID)' ($(Get-DevKitWifiBestSignal -Network $open)%). Open means unencrypted - anyone nearby can read plain traffic.")
    }

    if ($advice.Count -eq 0) {
        $text = if ($connected) { 'Nothing to change: good signal, and no faster or stronger access point for this network in range.' } else { 'No usable networks found nearby.' }
        $advice += (& $add 'good' $text)
    }
    return , $advice
}

# ==================== DIAGNOSIS (pure) ====================

function Get-DevKitDnsCandidates {
    <#
    .SYNOPSIS
        The public DNS services the optimizer benchmarks against whatever the
        network handed out.
    #>
    return @(
        [PSCustomObject]@{ Name = 'Cloudflare'; IPv4 = @('1.1.1.1', '1.0.0.1'); IPv6 = @('2606:4700:4700::1111', '2606:4700:4700::1001') }
        [PSCustomObject]@{ Name = 'Google'; IPv4 = @('8.8.8.8', '8.8.4.4'); IPv6 = @('2001:4860:4860::8888', '2001:4860:4860::8844') }
        [PSCustomObject]@{ Name = 'Quad9'; IPv4 = @('9.9.9.9', '149.112.112.112'); IPv6 = @('2620:fe::fe', '2620:fe::9') }
        [PSCustomObject]@{ Name = 'OpenDNS'; IPv4 = @('208.67.222.222', '208.67.220.220'); IPv6 = @('2620:119:35::35', '2620:119:53::53') }
    )
}

function Get-DevKitWifiDiagnosis {
    <#
    .SYNOPSIS
        Measurements in, findings and the fixes they justify out.
    .DESCRIPTION
        Pure - it reads only $Snapshot - so every rule is unit-tested. This
        is the function that replaces "always reset everything": an action
        appears in the plan only when a measurement calls for it, least
        invasive first, and several findings deliberately carry NO action
        because no setting on this PC can fix them (a weak signal, a busy
        channel, an outage past the router).

        Action codes, in the order they are applied:
          FlushDns        clear the local resolver cache
          SwitchDns       point the adapter at the fastest working resolver
                          (BestDns); never while a sign-in page is in the way
          RenewLease      release/renew the DHCP lease
          RestartAdapter  disable/enable the WiFi adapter
          ResetStack      Winsock + TCP/IP reset (needs a restart) - ONLY
                          with -Deep, never chosen automatically
    .PARAMETER Snapshot
        Output of Get-DevKitWifiSnapshot (or a hand-built object in tests):
        AdapterPresent, Connected, Ssid, SignalPercent, IPv4, Gateway,
        Portal ('open'|'portal'|'offline'|'unknown'), GatewayPing and
        InternetPing (AverageLatency, PacketLossPct, JitterMs), DnsCurrent
        (Servers, MedianMs, FailurePct) and DnsCandidates (Name, Servers,
        MedianMs, FailurePct).
    .PARAMETER KeepDns
        Never plan SwitchDns.
    .PARAMETER Deep
        Add RenewLease and ResetStack regardless of findings - the user
        explicitly asked for the full reset.
    .OUTPUTS
        PSCustomObject: Findings (Code, Severity = 'error'|'warn'|'info',
        Message), Actions (string[]), BestDns (candidate or $null), Healthy.
    #>
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [switch]$KeepDns,
        [switch]$Deep
    )

    $findings = @()
    $actions = @()
    $bestDns = $null
    $finding = { param($Code, $Severity, $Message) [PSCustomObject]@{ Code = $Code; Severity = $Severity; Message = $Message } }
    $result = {
        param($F, $A, $B)
        $ordered = @('FlushDns', 'SwitchDns', 'RenewLease', 'RestartAdapter', 'ResetStack' | Where-Object { $A -contains $_ })
        [PSCustomObject]@{
            Findings = @($F)
            Actions  = @($ordered)
            BestDns  = $B
            Healthy  = (@($F | Where-Object { $_.Severity -ne 'info' }).Count -eq 0)
        }
    }

    if (-not $Snapshot.AdapterPresent) {
        $findings += (& $finding 'NoAdapter' 'error' 'No WiFi adapter is active on this PC.')
        return (& $result $findings $actions $null)
    }
    if (-not $Snapshot.Connected) {
        $findings += (& $finding 'NotConnected' 'error' 'Not connected to a WiFi network. Connect first, then run this again.')
        return (& $result $findings $actions $null)
    }

    if ($Deep) { $actions += 'RenewLease', 'ResetStack' }

    if ($null -ne $Snapshot.SignalPercent -and [int]$Snapshot.SignalPercent -lt 40) {
        $findings += (& $finding 'WeakSignal' 'warn' "Weak signal ($($Snapshot.SignalPercent)%). Distance and walls, not settings - move closer or use a nearer access point.")
    }

    $ip = [string]$Snapshot.IPv4
    if (-not $ip -or $ip.StartsWith('169.254.') -or -not $Snapshot.Gateway) {
        $findings += (& $finding 'NoAddress' 'error' 'Connected to the access point but it has not given this PC a usable address.')
        $actions += 'RenewLease'
        return (& $result $findings $actions $null)
    }

    $gateway = $Snapshot.GatewayPing
    if ($gateway -and [int]$gateway.PacketLossPct -ge 100) {
        $findings += (& $finding 'GatewayUnreachable' 'error' "The router ($($Snapshot.Gateway)) does not answer at all.")
        $actions += 'RenewLease', 'RestartAdapter'
        return (& $result $findings $actions $null)
    }
    if ($gateway -and ([int]$gateway.PacketLossPct -ge 10 -or [double]$gateway.AverageLatency -gt 30 -or [double]$gateway.JitterMs -gt 30)) {
        $findings += (& $finding 'PoorLink' 'warn' ("The link to the router itself is unstable ({0} ms average, {1}% lost). That is radio quality - interference or distance - and no setting on this PC fixes it." -f [math]::Round([double]$gateway.AverageLatency, 0), [int]$gateway.PacketLossPct))
    }

    $portalInTheWay = ([string]$Snapshot.Portal -eq 'portal')
    if ($portalInTheWay) {
        $findings += (& $finding 'CaptivePortal' 'warn' 'This network is showing a sign-in page. Open a browser and sign in first - until then nothing here can help, and changing DNS would break the sign-in page.')
    }

    $internet = $Snapshot.InternetPing
    if ($internet) {
        if ([int]$internet.PacketLossPct -ge 100) {
            if ([string]$Snapshot.Portal -eq 'open') {
                $findings += (& $finding 'PingBlocked' 'info' 'This network blocks ping, so latency could not be measured - web access itself works.')
            } elseif (-not $portalInTheWay) {
                $findings += (& $finding 'NoInternet' 'error' 'The router answers but the internet does not. The outage is past the router (its uplink or the provider) - nothing on this PC fixes that.')
            }
        } elseif ([int]$internet.PacketLossPct -ge 10) {
            $findings += (& $finding 'InternetLoss' 'warn' "$($internet.PacketLossPct)% of packets to the internet are being lost.")
        } elseif ([double]$internet.AverageLatency -gt 150) {
            $findings += (& $finding 'HighLatency' 'warn' ("High latency to the internet ({0} ms)." -f [math]::Round([double]$internet.AverageLatency, 0)))
        }
    }

    $current = $Snapshot.DnsCurrent
    $currentServers = @()
    if ($current) { $currentServers = @($current.Servers) }
    $working = @($Snapshot.DnsCandidates | Where-Object {
            $_ -and $null -ne $_.MedianMs -and [int]$_.FailurePct -eq 0 -and
            @($_.Servers | Where-Object { $currentServers -contains $_ }).Count -eq 0
        } | Sort-Object { [double]$_.MedianMs })
    if ($working.Count -gt 0) { $bestDns = $working[0] }

    if ($current) {
        $dnsBroken = ([int]$current.FailurePct -ge 50 -or $null -eq $current.MedianMs)
        if ($dnsBroken) {
            $findings += (& $finding 'DnsFailing' 'error' 'The DNS servers this network handed out are failing to answer.')
            $actions += 'FlushDns'
            if ($bestDns -and -not $KeepDns -and -not $portalInTheWay) { $actions += 'SwitchDns' }
        } elseif ($bestDns -and ([double]$current.MedianMs - [double]$bestDns.MedianMs) -ge 20 -and [double]$current.MedianMs -ge (1.5 * [double]$bestDns.MedianMs)) {
            $message = "DNS is slow: the current servers answer in {0} ms, {1} answers in {2} ms." -f [math]::Round([double]$current.MedianMs, 0), $bestDns.Name, [math]::Round([double]$bestDns.MedianMs, 0)
            if ($KeepDns -or $portalInTheWay) {
                $findings += (& $finding 'DnsSlow' 'info' "$message Left alone as requested.")
            } else {
                $findings += (& $finding 'DnsSlow' 'warn' $message)
                $actions += 'SwitchDns'
            }
        }
    }

    return (& $result $findings $actions $bestDns)
}

function Compare-DevKitWifiSnapshot {
    <#
    .SYNOPSIS
        Before/after measurements side by side, with a verdict per metric
        and overall - the "did that actually help?" the old tool never asked.
    .DESCRIPTION
        Pure. Lower is better for every metric here. A change only counts
        when it clears both 5 units and 15% of the earlier value, so normal
        run-to-run noise reads as "same" instead of a false win or loss.
    .OUTPUTS
        PSCustomObject: Rows (Metric, Before, After, Unit, Verdict =
        'better'|'worse'|'same'|'n/a'), Overall ('better'|'worse'|'same').
    #>
    param(
        [Parameter(Mandatory = $true)]$Before,
        [Parameter(Mandatory = $true)]$After
    )

    $metrics = @(
        @{ Name = 'Router latency'; Unit = 'ms'; Get = { param($s) if ($s.GatewayPing) { $s.GatewayPing.AverageLatency } } }
        @{ Name = 'Router packet loss'; Unit = '%'; Get = { param($s) if ($s.GatewayPing) { $s.GatewayPing.PacketLossPct } } }
        @{ Name = 'Internet latency'; Unit = 'ms'; Get = { param($s) if ($s.InternetPing) { $s.InternetPing.AverageLatency } } }
        @{ Name = 'Internet packet loss'; Unit = '%'; Get = { param($s) if ($s.InternetPing) { $s.InternetPing.PacketLossPct } } }
        @{ Name = 'DNS answer time'; Unit = 'ms'; Get = { param($s) if ($s.DnsCurrent) { $s.DnsCurrent.MedianMs } } }
        @{ Name = 'DNS failures'; Unit = '%'; Get = { param($s) if ($s.DnsCurrent) { $s.DnsCurrent.FailurePct } } }
    )

    $rows = @()
    $better = 0
    $worse = 0
    foreach ($metric in $metrics) {
        $b = & $metric.Get $Before
        $a = & $metric.Get $After
        $verdict = 'n/a'
        if ($null -ne $b -and $null -ne $a) {
            $delta = [double]$a - [double]$b
            $threshold = [math]::Max(5, 0.15 * [math]::Abs([double]$b))
            if ($delta -le -$threshold) { $verdict = 'better'; $better++ }
            elseif ($delta -ge $threshold) { $verdict = 'worse'; $worse++ }
            else { $verdict = 'same' }
        } elseif ($null -eq $b -and $null -ne $a) {
            # Could not be measured before, can be now (e.g. DNS came back).
            $verdict = 'better'; $better++
        } elseif ($null -ne $b -and $null -eq $a) {
            $verdict = 'worse'; $worse++
        }
        $rows += [PSCustomObject]@{
            Metric  = $metric.Name
            Before  = if ($null -ne $b) { [math]::Round([double]$b, 1) } else { $null }
            After   = if ($null -ne $a) { [math]::Round([double]$a, 1) } else { $null }
            Unit    = $metric.Unit
            Verdict = $verdict
        }
    }

    $overall = 'same'
    if ($better -gt $worse) { $overall = 'better' } elseif ($worse -gt $better) { $overall = 'worse' }
    return [PSCustomObject]@{ Rows = @($rows); Overall = $overall }
}

function Test-DevKitDnsBackupNeeded {
    <#
    .SYNOPSIS
        Whether the DNS undo file should be (re)written before a DNS change.
    .DESCRIPTION
        The undo file must hold the settings from BEFORE DevKit touched DNS.
        It used to be rewritten on every run, so a second run backed up the
        servers the first run had just applied - and "Undo" then restored
        DevKit's own choice, with the network's original settings gone.

        Pure. Write a new backup when there is none, or when the adapter's
        current servers are NOT ones DevKit applies (the user or the network
        changed them since, so they are a new "original"). Keep the existing
        backup when the current servers are DevKit's own.
    .PARAMETER ExistingBackup
        The parsed undo file, or $null.
    .PARAMETER CurrentServers
        The adapter's DNS servers right now (IPv4 and IPv6 together). Empty
        means automatic (DHCP).
    .PARAMETER InterfaceAlias
        The adapter about to be changed.
    .PARAMETER CurrentIsStatic
        Whether the adapter's DNS is set by hand right now ($false = handed
        out by the network). Defaults to $true, the cautious reading.
    #>
    param(
        $ExistingBackup = $null,
        [AllowEmptyCollection()][string[]]$CurrentServers = @(),
        [string]$InterfaceAlias = '',
        [bool]$CurrentIsStatic = $true
    )

    if (-not $ExistingBackup) { return $true }
    if ($InterfaceAlias -and [string]$ExistingBackup.InterfaceAlias -and [string]$ExistingBackup.InterfaceAlias -ne $InterfaceAlias) { return $true }
    # Automatic (DHCP) settings are the network's own by definition - even
    # when the router happens to hand out a public resolver DevKit also uses.
    if (-not $CurrentIsStatic) { return $true }

    $known = @()
    foreach ($candidate in (Get-DevKitDnsCandidates)) { $known += $candidate.IPv4; $known += $candidate.IPv6 }
    $current = @($CurrentServers | Where-Object { $_ })
    if ($current.Count -eq 0) { return $true }
    $foreign = @($current | Where-Object { $known -notcontains $_ })
    return ($foreign.Count -gt 0)
}

function Get-DevKitDnsRestorePlan {
    <#
    .SYNOPSIS
        What "Undo DNS" must apply, given the undo file.
    .DESCRIPTION
        Pure. The adapter is always reset to automatic first; a family's
        saved addresses are re-applied ONLY when that family was set by hand
        at backup time (IPv4Static / IPv6Static).

        The distinction is the fix: the old undo re-applied whatever
        addresses had been in use, so a laptop whose DNS came from the
        network (the normal case) ended up with that one network's router
        address PINNED as static DNS - and no name resolution at all on the
        next network it joined. Automatic must be restored as automatic.

        Undo files written before the flags existed carry no such
        information; for those the saved addresses are re-applied, as the
        old tool did (it is the only behaviour their author can have
        expected).
    .OUTPUTS
        PSCustomObject: IPv4 and IPv6 (address arrays to set after the
        reset; empty = leave that family automatic).
    #>
    param([Parameter(Mandatory = $true)]$Backup)

    $hasFlags = ($Backup.PSObject.Properties.Match('IPv4Static').Count -gt 0)
    $v4 = @($Backup.IPv4 | Where-Object { $_ })
    $v6 = @($Backup.IPv6 | Where-Object { $_ })
    if ($hasFlags) {
        if (-not [bool]$Backup.IPv4Static) { $v4 = @() }
        if (-not [bool]$Backup.IPv6Static) { $v6 = @() }
    }
    return [PSCustomObject]@{ IPv4 = @($v4); IPv6 = @($v6) }
}

# ==================== MEASURING (read-only) ====================

function Measure-DevKitPingLatency {
    <#
    .SYNOPSIS
        Pings a target and reports average latency, jitter and packet loss.
    .DESCRIPTION
        Test-Connection reports Latency/ResponseTime = 0 on a timeout, not
        $null, so averaging every reply (success or not) silently folds
        packet loss into the average as artificially-good 0ms readings. This
        averages only replies that actually succeeded and reports loss
        separately. Handles both PowerShell 7's Test-Connection
        (Status/Latency) and Windows PowerShell 5.1's (StatusCode/
        ResponseTime).

        Jitter is the mean difference between consecutive replies - the
        number that explains a call breaking up while "average ping" looks
        fine.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ComputerName,
        [int]$Count = 4
    )

    $pingArgs = @{ ComputerName = $ComputerName; Count = $Count; ErrorAction = 'SilentlyContinue' }
    # PowerShell 7 waits 5 s per unanswered ping by default - 25 s to learn
    # that a dead router is dead. One second is plenty on a local network and
    # still generous for the internet. (Windows PowerShell 5.1 has no such
    # parameter and already times out in about a second.)
    if ((Get-Command Test-Connection).Parameters.ContainsKey('TimeoutSeconds')) { $pingArgs['TimeoutSeconds'] = 1 }
    $replies = @(Test-Connection @pingArgs)
    $sent = [math]::Max($replies.Count, $Count)

    $successful = @($replies | Where-Object {
            ($_.PSObject.Properties.Match('Status').Count -gt 0 -and $_.Status -eq 'Success') -or
            ($_.PSObject.Properties.Match('StatusCode').Count -gt 0 -and $_.StatusCode -eq 0)
        })

    $latencies = @($successful | ForEach-Object {
            if ($_.PSObject.Properties.Match('Latency').Count -gt 0) { [double]$_.Latency } else { [double]$_.ResponseTime }
        })

    $average = $null
    $jitter = $null
    if ($latencies.Count -gt 0) {
        $average = ($latencies | Measure-Object -Average).Average
        $jitter = 0
        if ($latencies.Count -gt 1) {
            $diffs = @(1..($latencies.Count - 1) | ForEach-Object { [math]::Abs($latencies[$_] - $latencies[$_ - 1]) })
            $jitter = ($diffs | Measure-Object -Average).Average
        }
    }

    return [PSCustomObject]@{
        AverageLatency = $average
        JitterMs       = $jitter
        PacketLossPct  = [int][math]::Round((($sent - $successful.Count) / $sent) * 100, 0)
        Sent           = $sent
        Received       = $successful.Count
    }
}

function Measure-DevKitDnsResolver {
    <#
    .SYNOPSIS
        How quickly, and how reliably, one DNS server answers real lookups.
    .DESCRIPTION
        The old optimizer chose a DNS provider by pinging 1.1.1.1 and
        8.8.8.8 twice each. Ping measures the path to a server, not how fast
        it resolves names, and it could only ever pick between those two -
        it never asked whether the DNS already in use was better than both.

        This sends actual queries straight at the server (-Server bypasses
        the local resolver cache, which would otherwise answer in 0 ms and
        make whatever is configured look unbeatable) and reports the median,
        so one slow first packet does not decide the result.
    .PARAMETER Server
        The resolver's address.
    .PARAMETER Names
        Host names to look up.
    .OUTPUTS
        PSCustomObject: Server, MedianMs ($null when nothing answered),
        FailurePct.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Server,
        [string[]]$Names = @('www.microsoft.com', 'www.google.com', 'github.com', 'www.cloudflare.com', 'registry.npmjs.org')
    )

    $timings = @()
    $failures = 0
    foreach ($name in $Names) {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $null = Resolve-DnsName -Name $name -Server $Server -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop
            $watch.Stop()
            $timings += $watch.Elapsed.TotalMilliseconds
        } catch {
            $failures++
        }
    }

    $median = $null
    if ($timings.Count -gt 0) {
        $sorted = @($timings | Sort-Object)
        $middle = [int][math]::Floor($sorted.Count / 2)
        $median = if ($sorted.Count % 2 -eq 1) { $sorted[$middle] } else { ($sorted[$middle - 1] + $sorted[$middle]) / 2 }
    }
    return [PSCustomObject]@{
        Server     = $Server
        MedianMs   = $median
        FailurePct = [int][math]::Round(($failures / [math]::Max($Names.Count, 1)) * 100, 0)
    }
}

function Test-DevKitCaptivePortal {
    <#
    .SYNOPSIS
        Whether a hotel/cafe style sign-in page is intercepting web traffic.
    .DESCRIPTION
        Fetches the same plain-HTTP probe Windows itself uses
        (msftconnecttest.com) without following redirects. The exact
        expected body means open internet; a redirect or any other body
        means something is answering in its place - a sign-in page.
    .OUTPUTS
        'open' | 'portal' | 'offline'
    #>
    param([int]$TimeoutSeconds = 5)

    $handler = $null
    $client = $null
    try {
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $false
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
        $response = $client.GetAsync('http://www.msftconnecttest.com/connecttest.txt').GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
        if ($status -ge 300 -and $status -lt 400) { return 'portal' }
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ($status -eq 200 -and $body.Trim() -eq 'Microsoft Connect Test') { return 'open' }
        return 'portal'
    } catch {
        return 'offline'
    } finally {
        if ($client) { $client.Dispose() }
        if ($handler) { $handler.Dispose() }
    }
}

function Invoke-DevKitWlanRescan {
    <#
    .SYNOPSIS
        Asks every WiFi adapter to scan for networks now.
    .DESCRIPTION
        `netsh wlan show networks` only prints what Windows already has
        cached, and on a connected laptop that is often just the one network
        it is connected to (netsh has no "scan" verb). The Native WiFi API's
        WlanScan starts a real scan; results land in the same cache a few
        seconds later. Changes nothing - no connection is dropped.
    .OUTPUTS
        'started'     at least one adapter accepted the scan request
        'denied'      Windows refused it (error 5). On Windows 11 24H2 and
                      later the WiFi APIs answer this while Location access
                      for desktop apps is off - but not only then: it was
                      also seen from a restricted (sandboxed) shell with
                      Location allowed, so callers word it as likely, not
                      certain.
        'unavailable' anything else - no adapter, no WLAN service, the API
                      could not be loaded.
        Never throws; on anything but 'started' the caller simply shows the
        cached list.
    #>
    try {
        if (-not ('DevKit.WlanNative' -as [type])) {
            Add-Type -Namespace DevKit -Name WlanNative -MemberDefinition @'
[DllImport("wlanapi.dll")] public static extern uint WlanOpenHandle(uint dwClientVersion, IntPtr pReserved, out uint pdwNegotiatedVersion, out IntPtr phClientHandle);
[DllImport("wlanapi.dll")] public static extern uint WlanCloseHandle(IntPtr hClientHandle, IntPtr pReserved);
[DllImport("wlanapi.dll")] public static extern uint WlanEnumInterfaces(IntPtr hClientHandle, IntPtr pReserved, out IntPtr ppInterfaceList);
[DllImport("wlanapi.dll")] public static extern uint WlanScan(IntPtr hClientHandle, ref Guid pInterfaceGuid, IntPtr pDot11Ssid, IntPtr pIeData, IntPtr pReserved);
[DllImport("wlanapi.dll")] public static extern void WlanFreeMemory(IntPtr pMemory);
'@ -ErrorAction Stop
        }

        $handle = [IntPtr]::Zero
        $negotiated = [uint32]0
        if ([DevKit.WlanNative]::WlanOpenHandle(2, [IntPtr]::Zero, [ref]$negotiated, [ref]$handle) -ne 0) { return 'unavailable' }
        try {
            $list = [IntPtr]::Zero
            if ([DevKit.WlanNative]::WlanEnumInterfaces($handle, [IntPtr]::Zero, [ref]$list) -ne 0) { return 'unavailable' }
            try {
                # WLAN_INTERFACE_INFO_LIST: DWORD count, DWORD index, then
                # count x WLAN_INTERFACE_INFO { GUID (16), WCHAR[256] (512),
                # state (4) } = 532 bytes each.
                $count = [System.Runtime.InteropServices.Marshal]::ReadInt32($list, 0)
                $accepted = 0
                $denied = 0
                for ($i = 0; $i -lt $count; $i++) {
                    $entry = [IntPtr]::Add($list, 8 + ($i * 532))
                    $guidBytes = New-Object byte[] 16
                    [System.Runtime.InteropServices.Marshal]::Copy($entry, $guidBytes, 0, 16)
                    $guid = New-Object Guid (, $guidBytes)
                    $code = [DevKit.WlanNative]::WlanScan($handle, [ref]$guid, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
                    if ($code -eq 0) { $accepted++ } elseif ($code -eq 5) { $denied++ }
                }
                if ($accepted -gt 0) { return 'started' }
                if ($denied -gt 0) { return 'denied' }
                return 'unavailable'
            } finally {
                [DevKit.WlanNative]::WlanFreeMemory($list)
            }
        } finally {
            [void][DevKit.WlanNative]::WlanCloseHandle($handle, [IntPtr]::Zero)
        }
    } catch {
        return 'unavailable'
    }
}

function Get-DevKitWifiSnapshot {
    <#
    .SYNOPSIS
        One read-only measurement pass over the WiFi connection: adapter,
        signal, address, router, internet, sign-in page, DNS.
    .DESCRIPTION
        Changes nothing. Takes roughly 5-15 seconds (pings and DNS lookups
        run for real). The output is what Get-DevKitWifiDiagnosis reads and
        what Compare-DevKitWifiSnapshot compares.
    .PARAMETER SkipDnsCandidates
        Only time the DNS servers currently in use - for the "after" pass,
        where the alternatives are no longer the question.
    #>
    param([switch]$SkipDnsCandidates)

    $snapshot = [ordered]@{
        AdapterPresent = $false; InterfaceIndex = $null; InterfaceAlias = ''; Connected = $false
        Ssid = ''; Bssid = ''; SignalPercent = $null; Band = ''; Channel = 0; RadioType = ''; RxMbps = $null; TxMbps = $null
        IPv4 = ''; Gateway = ''; Portal = 'unknown'
        GatewayPing = $null; InternetPing = $null; DnsCurrent = $null; DnsCandidates = @()
    }

    # PhysicalMediaType (not just "wireless-looking name") keeps this
    # WiFi-specific: a docked laptop's Ethernet adapter must never be the one
    # measured, let alone reconfigured.
    $wifiAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.PhysicalMediaType -eq 'Native 802.11' })
    if ($wifiAdapters.Count -eq 0) { return [PSCustomObject]$snapshot }
    $snapshot.AdapterPresent = $true
    $adapter = $wifiAdapters | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if (-not $adapter) {
        # A WiFi adapter exists but is not connected to anything.
        $snapshot.InterfaceAlias = $wifiAdapters[0].Name
        return [PSCustomObject]$snapshot
    }
    $snapshot.InterfaceIndex = $adapter.InterfaceIndex
    $snapshot.InterfaceAlias = $adapter.Name

    $rawInterfaces = (netsh wlan show interfaces | Out-String)
    $wlan = @(ConvertFrom-DevKitWlanInterface -RawOutput $rawInterfaces | Where-Object { $_.Connected }) | Select-Object -First 1
    if ($wlan) {
        $snapshot.Connected = $true
        $snapshot.Ssid = $wlan.Ssid; $snapshot.Bssid = $wlan.Bssid; $snapshot.SignalPercent = $wlan.SignalPercent
        $snapshot.Band = $wlan.Band; $snapshot.Channel = $wlan.Channel; $snapshot.RadioType = $wlan.RadioType
        $snapshot.RxMbps = $wlan.RxMbps; $snapshot.TxMbps = $wlan.TxMbps
    } else {
        # netsh can refuse to report (Windows 11 24H2 hides WLAN details when
        # Location is off). The adapter being Up with an address is still a
        # connection - measure it rather than declaring "not connected".
        $snapshot.Connected = $true
    }

    $config = Get-NetIPConfiguration -InterfaceIndex $adapter.InterfaceIndex -ErrorAction SilentlyContinue
    if ($config) {
        $snapshot.IPv4 = [string](@($config.IPv4Address | ForEach-Object { $_.IPAddress }) | Select-Object -First 1)
        $snapshot.Gateway = [string](@($config.IPv4DefaultGateway | ForEach-Object { $_.NextHop }) | Select-Object -First 1)
    }
    if (-not $snapshot.IPv4 -or $snapshot.IPv4.StartsWith('169.254.') -or -not $snapshot.Gateway) {
        return [PSCustomObject]$snapshot
    }

    $snapshot.GatewayPing = Measure-DevKitPingLatency -ComputerName $snapshot.Gateway -Count 5
    if ($snapshot.GatewayPing.PacketLossPct -ge 100) { return [PSCustomObject]$snapshot }

    $snapshot.Portal = Test-DevKitCaptivePortal
    $snapshot.InternetPing = Measure-DevKitPingLatency -ComputerName '1.1.1.1' -Count 5

    $servers = @(Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            ForEach-Object { $_.ServerAddresses })
    if ($servers.Count -gt 0) {
        $measured = Measure-DevKitDnsResolver -Server $servers[0]
        $snapshot.DnsCurrent = [PSCustomObject]@{ Name = 'Current'; Servers = $servers; MedianMs = $measured.MedianMs; FailurePct = $measured.FailurePct }
    }

    if (-not $SkipDnsCandidates) {
        $candidates = @()
        foreach ($candidate in (Get-DevKitDnsCandidates)) {
            $measured = Measure-DevKitDnsResolver -Server $candidate.IPv4[0]
            $candidates += [PSCustomObject]@{
                Name = $candidate.Name; Servers = $candidate.IPv4; IPv6 = $candidate.IPv6
                MedianMs = $measured.MedianMs; FailurePct = $measured.FailurePct
            }
        }
        $snapshot.DnsCandidates = $candidates
    }

    return [PSCustomObject]$snapshot
}
