#!/usr/bin/env pwsh
<#
.SYNOPSIS
    WiFi Scanner - Northstar DevKit
.DESCRIPTION
    Asks the WiFi adapter for a FRESH scan, then lists every network in
    range with signal, security, band (2.4 / 5 / 6 GHz) and channel, marks
    the one this PC is connected to, shows which channels are crowded, and
    says what - if anything - is worth changing.

    Read-only. The scan request does not drop or change the connection.

    Why the fresh scan matters: `netsh wlan show networks` only prints what
    Windows already has cached, and on a connected laptop that is often just
    the one network it is on.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER NoRescan
    Skip the fresh scan and show Windows' cached list immediately.
.EXAMPLE
    .\WiFi-Scan.ps1
    .\WiFi-Scan.ps1 -NoRescan
#>
[CmdletBinding()]
param(
    [switch]$NoRescan
)

$LibDir = Join-Path (Split-Path -Parent $PSScriptRoot) "lib"
$CommonModule = Join-Path $LibDir "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }
# The parsers and the advice live in the shared WiFi library (unit-tested in
# tests/Unit/WiFiCore.Tests.ps1); this script only measures and prints.
$WifiModule = Join-Path $LibDir "DevKit-WiFi.ps1"
if (Test-Path $WifiModule) {
    . $WifiModule
} else {
    Write-Host "ERROR: Required module not found: $WifiModule" -ForegroundColor Red
    exit 1
}

# Skip the scan when this script is dot-sourced (tests/Unit/
# WiFiScan-Parser.Tests.ps1 dot-sources it for ConvertFrom-DevKitWlanScan),
# so tests never need WiFi hardware, netsh.exe, or the prompt at the end.
if ($MyInvocation.InvocationName -eq '.') {
    return
}

function Exit-DevKitWifiScan {
    # Every exit pauses for Enter when a real console is attached, and never
    # under the Control Center's headless runner (stdin closed - Read-Host
    # would throw).
    param([int]$Code = 0)
    if (-not [Console]::IsInputRedirected) { Read-Host "Press Enter to exit" | Out-Null }
    exit $Code
}

Write-Host ""
Write-Host "   NORTHSTAR DevKit - WiFi SCANNER" -ForegroundColor Cyan
Write-Host "     https://www.northstarcoding.com" -ForegroundColor Gray
Write-Host ""

if (-not $NoRescan) {
    Write-DevKitStep "Asking the adapter for a fresh scan"
    $rescan = Invoke-DevKitWlanRescan
    if ($rescan -eq 'started') {
        # A full scan across 2.4, 5 and 6 GHz takes a few seconds to land in
        # the list netsh reads.
        Start-Sleep -Seconds 4
        Write-DevKitDone
    } else {
        Write-DevKitSkip
        if ($rescan -eq 'denied') {
            Write-Host "  WARNING: Windows refused the scan request (access denied), so this is its cached list - often just the network you are on." -ForegroundColor Yellow
            Write-DevKitInfo "If Location is off, that is the usual reason: Settings > Privacy & security > Location"
            Write-DevKitInfo "  ('Location services' and 'Let desktop apps access your location'), then run this again."
        } else {
            Write-DevKitInfo "Could not start a fresh scan - showing Windows' cached list instead."
        }
    }
}

Write-DevKitStep "Reading networks"
$rawNetworks = (netsh wlan show networks mode=Bssid | Out-String)
$netshExit = $LASTEXITCODE

if ($rawNetworks -match "no wireless interface") {
    Write-DevKitError "No WiFi adapter found."
    Exit-DevKitWifiScan -Code 1
}
if ($netshExit -ne 0 -and $rawNetworks -match "location") {
    # Windows 11 24H2 and later hide WLAN details from every app, netsh
    # included, while Location is off.
    Write-DevKitError "Windows is hiding WiFi details because Location is turned off."
    Write-DevKitInfo "Turn it on in Settings > Privacy & security > Location:"
    Write-DevKitInfo "  'Location services' and 'Let desktop apps access your location'."
    Exit-DevKitWifiScan -Code 1
}
Write-DevKitDone

$networks = ConvertFrom-DevKitWlanScan -RawOutput $rawNetworks
# Both library calls below return their array behind a unary comma, so they
# are assigned BEFORE being filtered: piped straight into Where-Object, the
# filter would receive the whole array as a single item.
$allInterfaces = ConvertFrom-DevKitWlanInterface -RawOutput (netsh wlan show interfaces | Out-String)
$current = @($allInterfaces | Where-Object { $_.Connected }) | Select-Object -First 1

if ($networks.Count -eq 0) {
    Write-Host "  No WiFi networks could be read." -ForegroundColor Yellow
    Write-Host "  Either nothing is in range, or this Windows prints the list in a shape this tool does not know." -ForegroundColor Gray
    Write-Host "`n  Raw output:" -ForegroundColor Cyan
    Write-Host $rawNetworks -ForegroundColor Gray
    Exit-DevKitWifiScan -Code 0
}

$sorted = @($networks | Sort-Object { Get-DevKitWifiBestSignal -Network $_ } -Descending)

Write-Host ""
Write-Host "  Found $($sorted.Count) network(s):" -ForegroundColor Green
Write-Host ""
Write-Host "    SIGNAL  SSID                          SECURITY          BAND          CHANNEL" -ForegroundColor DarkGray
Write-Host "    ------  ----                          --------          ----          -------"

foreach ($net in $sorted) {
    $bestSignal = Get-DevKitWifiBestSignal -Network $net
    $channels = (@($net.BSSIDs | ForEach-Object { [int]$_.Channel } | Sort-Object -Unique) -join ",")
    # "2.4/5 GHz" rather than "2.4 GHz, 5 GHz": the column is narrow.
    $bands = (@($net.BSSIDs | ForEach-Object { ([string]$_.Band) -replace ' GHz', '' } | Where-Object { $_ } | Sort-Object { [double]$_ } -Unique) -join "/")
    if ($bands) { $bands = "$bands GHz" }

    $sigColor = if ($bestSignal -ge 70) { "Green" } elseif ($bestSignal -ge 40) { "Yellow" } else { "Red" }

    $isCurrent = $current -and ([string]$net.SSID -eq [string]$current.Ssid) -and
        (@($net.BSSIDs | Where-Object { ([string]$_.MAC).ToLowerInvariant() -eq [string]$current.Bssid }).Count -gt 0)

    $ssid = if ([string]$net.SSID) { [string]$net.SSID } else { "(hidden network)" }
    if ($ssid.Length -gt 28) { $ssid = $ssid.Substring(0, 25) + "..." }

    # [string] coalesces a missing Authentication line to '' - a bare
    # $net.Auth.PadRight would throw on $null.
    $marker = if ($isCurrent) { "  * " } else { "    " }
    Write-Host $marker -ForegroundColor Cyan -NoNewline
    Write-Host ("$bestSignal%".PadRight(8)) -ForegroundColor $sigColor -NoNewline
    Write-Host ("{0} {1} {2} {3}" -f $ssid.PadRight(29), ([string]$net.Auth).PadRight(17), $bands.PadRight(13), $channels)
}

if ($current) {
    Write-Host ""
    $rate = if ($null -ne $current.RxMbps) { ", link $($current.RxMbps) Mbps down / $($current.TxMbps) Mbps up" } else { "" }
    Write-Host "  * Connected: $($current.Ssid) - $($current.SignalPercent)% on $($current.Band) channel $($current.Channel) ($($current.RadioType))$rate" -ForegroundColor Cyan
}

# Only the channels worth a second look: crowded, or reported busy.
$channelLoad = Get-DevKitWifiChannelLoad -Networks $networks
$busy = @($channelLoad | Where-Object {
        $_.Overlapping -ge 3 -or ($null -ne $_.Utilization -and $_.Utilization -ge 50)
    })
if ($busy.Count -gt 0) {
    Write-Host ""
    Write-Host "  BUSY CHANNELS:" -ForegroundColor Cyan
    foreach ($row in $busy) {
        $airtime = if ($null -ne $row.Utilization) { ", airtime $($row.Utilization)% in use" } else { "" }
        Write-Host "    $($row.Band) channel $($row.Channel): $($row.Overlapping) overlapping access point(s)$airtime" -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "  WHAT THIS MEANS:" -ForegroundColor Cyan
foreach ($item in (Get-DevKitWifiScanAdvice -Networks $networks -Current $current)) {
    $color = switch ($item.Level) { 'warn' { 'Yellow' } 'good' { 'Green' } default { 'Gray' } }
    Write-Host "  - $($item.Text)" -ForegroundColor $color
}

Write-Host ""
Write-Host "  https://www.northstarcoding.com" -ForegroundColor DarkGray
Write-Host ""
Exit-DevKitWifiScan -Code 0
