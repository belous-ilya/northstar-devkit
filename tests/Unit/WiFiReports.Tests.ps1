#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for the reports behind the widget's WiFi tray
    (tools/lib/DevKit-WiFi.ps1) and the wifi.* RPC methods that serve them.
.DESCRIPTION
    The three ConvertTo-DevKitWifi*Report functions are pure: they take what
    was measured and return plain data for the app. They are tested against
    hand-built measurements, so no WiFi hardware is needed and no network is
    touched.

    The reports cross a contract boundary - the app reads these exact
    property names (app/src/lib/types.ts, "wifi.*") - so the tests pin the
    names and the JSON shape as well as the values.
.EXAMPLE
    Invoke-Pester -Path .\tests\Unit\WiFiReports.Tests.ps1
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $script:RepoRoot 'tools\lib\DevKit-WiFi.ps1')

    function New-TestLink {
        param([hashtable]$Over = @{})
        $link = [ordered]@{
            AdapterPresent = $true; AdapterUp = $true; InterfaceIndex = 12; InterfaceAlias = 'Wi-Fi'; InterfaceGuid = '{GUID}'
            Connected = $true; DetailsHidden = $false
            Ssid = 'HomeNet'; Bssid = 'aa:bb:cc:dd:ee:01'; SignalPercent = 86; Band = '5 GHz'; Channel = 161; RadioType = '802.11ax'
            RxMbps = 286.8; TxMbps = 287; IPv4 = '192.168.0.21'; Gateway = '192.168.0.1'
        }
        foreach ($key in $Over.Keys) { $link[$key] = $Over[$key] }
        return $link
    }

    function New-TestSnapshot {
        param([hashtable]$Over = @{})
        $snapshot = [ordered]@{
            AdapterPresent = $true; InterfaceIndex = 12; InterfaceAlias = 'Wi-Fi'; Connected = $true
            Ssid = 'HomeNet'; Bssid = 'aa:bb:cc:dd:ee:01'; SignalPercent = 86; Band = '5 GHz'; Channel = 161; RadioType = '802.11ax'
            RxMbps = 287; TxMbps = 287; IPv4 = '192.168.0.21'; Gateway = '192.168.0.1'; Portal = 'open'
            GatewayPing = [PSCustomObject]@{ AverageLatency = 2.44; JitterMs = 0.61; PacketLossPct = 0; Sent = 10; Received = 10 }
            InternetPing = [PSCustomObject]@{ AverageLatency = 18.06; JitterMs = 1.25; PacketLossPct = 0; Sent = 10; Received = 10 }
            DnsCurrent = [PSCustomObject]@{ Name = 'Current'; Servers = @('192.168.0.1'); MedianMs = 24.5; FailurePct = 0 }
            DnsCandidates = @(
                [PSCustomObject]@{ Name = 'Cloudflare'; Servers = @('1.1.1.1', '1.0.0.1'); MedianMs = 11.26; FailurePct = 0 }
                [PSCustomObject]@{ Name = 'Google'; Servers = @('8.8.8.8', '8.8.4.4'); MedianMs = 14; FailurePct = 0 }
            )
            DnsIsStatic = $false
        }
        foreach ($key in $Over.Keys) { $snapshot[$key] = $Over[$key] }
        return [PSCustomObject]$snapshot
    }

    function New-TestNetwork {
        param([string]$Ssid, [string]$Auth = 'WPA2-Personal', [array]$AccessPoints)
        return @{ SSID = $Ssid; Auth = $Auth; Encryption = 'CCMP'; BSSIDs = @($AccessPoints) }
    }
    function New-TestAccessPoint {
        param([string]$Mac, [int]$Signal, [int]$Channel, [string]$Band = '5 GHz', $Utilization = $null)
        return @{ MAC = $Mac; Signal = $Signal; Channel = $Channel; Band = $Band; RadioType = '802.11ax'; Utilization = $Utilization; Stations = $null }
    }
}

Describe "ConvertTo-DevKitWifiStatusReport" {

    It "carries the connection under exactly the names the app reads" {
        $report = ConvertTo-DevKitWifiStatusReport -Link (New-TestLink) -DnsServers @('8.8.8.8', '8.8.4.4') -DnsIsStatic $true
        @($report.Keys) | Should -Be @('AdapterPresent', 'Connected', 'DetailsHidden', 'InterfaceAlias', 'Ssid', 'Bssid', 'SignalPercent',
            'Band', 'Channel', 'RadioType', 'RxMbps', 'TxMbps', 'IPv4', 'Gateway', 'DnsServers', 'DnsIsStatic')
        $report.Ssid | Should -Be 'HomeNet'
        $report.SignalPercent | Should -Be 86
        $report.Channel | Should -Be 161
        $report.RxMbps | Should -Be 286.8
        $report.DnsIsStatic | Should -BeTrue
    }

    It "serialises one DNS server as a list, not as a bare value" {
        $json = ConvertTo-DevKitWifiStatusReport -Link (New-TestLink) -DnsServers @('192.168.0.1') | ConvertTo-Json -Depth 5 -Compress
        $json | Should -Match '"DnsServers":\["192\.168\.0\.1"\]'
    }

    It "serialises no DNS servers as an empty list" {
        $json = ConvertTo-DevKitWifiStatusReport -Link (New-TestLink) | ConvertTo-Json -Depth 5 -Compress
        $json | Should -Match '"DnsServers":\[\]'
    }

    It "keeps 'not known' as null instead of turning it into 0" {
        $report = ConvertTo-DevKitWifiStatusReport -Link (New-TestLink @{ SignalPercent = $null; RxMbps = $null; TxMbps = $null; DetailsHidden = $true; Ssid = ''; Bssid = ''; Band = ''; Channel = 0 })
        $report.SignalPercent | Should -BeNullOrEmpty
        $report.RxMbps | Should -BeNullOrEmpty
        $report.DetailsHidden | Should -BeTrue
        $report.Connected | Should -BeTrue
        ($report | ConvertTo-Json -Compress) | Should -Match '"SignalPercent":null'
    }

    It "reports a PC with no WiFi adapter, and one whose adapter is not connected" {
        $none = ConvertTo-DevKitWifiStatusReport -Link (New-TestLink @{ AdapterPresent = $false; AdapterUp = $false; Connected = $false; InterfaceAlias = ''; Ssid = '' })
        $none.AdapterPresent | Should -BeFalse
        $none.Connected | Should -BeFalse
        $idle = ConvertTo-DevKitWifiStatusReport -Link (New-TestLink @{ AdapterUp = $false; Connected = $false; Ssid = ''; IPv4 = ''; Gateway = '' })
        $idle.AdapterPresent | Should -BeTrue
        $idle.Connected | Should -BeFalse
        $idle.InterfaceAlias | Should -Be 'Wi-Fi'
    }
}

Describe "ConvertTo-DevKitWifiMeasureReport" {

    BeforeAll {
        $script:When = [datetime]::new(2026, 11, 21, 18, 30, 0, [DateTimeKind]::Utc)
    }

    It "reports a healthy connection with rounded measurements and no fixes" {
        $snapshot = New-TestSnapshot
        $report = ConvertTo-DevKitWifiMeasureReport -Snapshot $snapshot -Diagnosis (Get-DevKitWifiDiagnosis -Snapshot $snapshot) -MeasuredAt $script:When
        @($report.Keys) | Should -Be @('MeasuredAt', 'Healthy', 'Portal', 'Router', 'Internet', 'DnsCurrent', 'DnsCandidates', 'BestDns', 'Findings', 'Actions')
        $report.MeasuredAt | Should -Be '2026-11-21T18:30:00.0000000Z'
        $report.Healthy | Should -BeTrue
        $report.Router.AverageMs | Should -Be 2.4
        $report.Router.LossPct | Should -Be 0
        $report.Internet.AverageMs | Should -Be 18.1
        $report.DnsCurrent.MedianMs | Should -Be 24.5
        @($report.DnsCandidates).Count | Should -Be 2
        $report.DnsCandidates[0].MedianMs | Should -Be 11.3
        @($report.Findings).Count | Should -Be 0
        @($report.Actions).Count | Should -Be 0
    }

    It "serialises empty findings and actions as lists, and one finding as a list of one" {
        $healthy = New-TestSnapshot
        $json = ConvertTo-DevKitWifiMeasureReport -Snapshot $healthy -Diagnosis (Get-DevKitWifiDiagnosis -Snapshot $healthy) -MeasuredAt $script:When | ConvertTo-Json -Depth 6 -Compress
        $json | Should -Match '"Findings":\[\]'
        $json | Should -Match '"Actions":\[\]'

        $weak = New-TestSnapshot @{ SignalPercent = 22 }
        $json = ConvertTo-DevKitWifiMeasureReport -Snapshot $weak -Diagnosis (Get-DevKitWifiDiagnosis -Snapshot $weak) -MeasuredAt $script:When | ConvertTo-Json -Depth 6 -Compress
        $json | Should -Match '"Findings":\[\{"Code":"WeakSignal","Severity":"warn","Message":"Weak signal \(22%\)'
    }

    It "carries the findings and the fixes they justify, in the order they would be applied" {
        $broken = New-TestSnapshot @{ DnsCurrent = [PSCustomObject]@{ Name = 'Current'; Servers = @('192.168.0.1'); MedianMs = $null; FailurePct = 100 } }
        $report = ConvertTo-DevKitWifiMeasureReport -Snapshot $broken -Diagnosis (Get-DevKitWifiDiagnosis -Snapshot $broken) -MeasuredAt $script:When
        $report.Healthy | Should -BeFalse
        @($report.Findings | ForEach-Object { $_.Code }) | Should -Contain 'DnsFailing'
        @($report.Actions) | Should -Be @('FlushDns', 'SwitchDns')
        $report.BestDns.Name | Should -Be 'Cloudflare'
        $report.DnsCurrent.MedianMs | Should -BeNullOrEmpty
        $report.DnsCurrent.FailurePct | Should -Be 100
    }

    It "reports measurements that were never taken as null, not as zero" {
        # No usable address: the probes do not run at all.
        $noAddress = New-TestSnapshot @{ IPv4 = '169.254.10.20'; Gateway = ''; GatewayPing = $null; InternetPing = $null; DnsCurrent = $null; DnsCandidates = @(); Portal = 'unknown' }
        $report = ConvertTo-DevKitWifiMeasureReport -Snapshot $noAddress -Diagnosis (Get-DevKitWifiDiagnosis -Snapshot $noAddress) -MeasuredAt $script:When
        $report.Router | Should -BeNullOrEmpty
        $report.Internet | Should -BeNullOrEmpty
        $report.DnsCurrent | Should -BeNullOrEmpty
        $report.BestDns | Should -BeNullOrEmpty
        @($report.Actions) | Should -Be @('RenewLease')
        $json = $report | ConvertTo-Json -Depth 6 -Compress
        $json | Should -Match '"Router":null'
        $json | Should -Match '"DnsCandidates":\[\]'
    }

    It "keeps a router that ignores ping as 100% loss with no average, not as a 0 ms reply" {
        $silent = New-TestSnapshot @{ GatewayPing = [PSCustomObject]@{ AverageLatency = $null; JitterMs = $null; PacketLossPct = 100; Sent = 10; Received = 0 } }
        $report = ConvertTo-DevKitWifiMeasureReport -Snapshot $silent -Diagnosis (Get-DevKitWifiDiagnosis -Snapshot $silent) -MeasuredAt $script:When
        $report.Router.LossPct | Should -Be 100
        $report.Router.AverageMs | Should -BeNullOrEmpty
        @($report.Findings | ForEach-Object { $_.Code }) | Should -Contain 'GatewayPingBlocked'
    }
}

Describe "ConvertTo-DevKitWifiScanReport" {

    BeforeAll {
        $script:Networks = @(
            (New-TestNetwork -Ssid 'HomeNet' -AccessPoints @(
                (New-TestAccessPoint -Mac 'AA:BB:CC:DD:EE:01' -Signal 86 -Channel 161 -Band '5 GHz'),
                (New-TestAccessPoint -Mac 'aa:bb:cc:dd:ee:02' -Signal 70 -Channel 6 -Band '2.4 GHz')
            )),
            (New-TestNetwork -Ssid 'Neighbour' -AccessPoints @((New-TestAccessPoint -Mac '11:22:33:44:55:66' -Signal 91 -Channel 6 -Band '2.4 GHz'))),
            (New-TestNetwork -Ssid '' -Auth 'WPA3-Personal' -AccessPoints @((New-TestAccessPoint -Mac '99:88:77:66:55:44' -Signal 40 -Channel 36 -Band '5 GHz'))),
            (New-TestNetwork -Ssid 'CafeGuest' -Auth 'Open' -AccessPoints @((New-TestAccessPoint -Mac '12:34:56:78:9a:bc' -Signal 30 -Channel 11 -Band '2.4 GHz')))
        )
        $script:Current = [PSCustomObject]@{ Name = 'Wi-Fi'; Connected = $true; Ssid = 'HomeNet'; Bssid = 'aa:bb:cc:dd:ee:01'; Band = '5 GHz'; Channel = 161; SignalPercent = 86 }
        $script:Report = ConvertTo-DevKitWifiScanReport -Networks $script:Networks -Current $script:Current -RescanState 'started'
    }

    It "lists every network, strongest first, under the names the app reads" {
        @($script:Report.Keys) | Should -Be @('RescanState', 'Problem', 'Networks', 'ChannelLoad', 'Advice')
        @($script:Report.Networks | ForEach-Object { $_.Ssid }) | Should -Be @('Neighbour', 'HomeNet', '', 'CafeGuest')
        @($script:Report.Networks[0].Keys) | Should -Be @('Ssid', 'Hidden', 'Auth', 'Signal', 'Bands', 'Channels', 'AccessPoints', 'IsCurrent')
        $script:Report.RescanState | Should -Be 'started'
        $script:Report.Problem | Should -Be ''
    }

    It "marks the network this PC is on, and only that one" {
        @($script:Report.Networks | Where-Object { $_.IsCurrent } | ForEach-Object { $_.Ssid }) | Should -Be @('HomeNet')
    }

    It "tells two networks with the same name apart by access point" {
        $twins = @(
            (New-TestNetwork -Ssid 'Guest' -AccessPoints @((New-TestAccessPoint -Mac 'aa:aa:aa:aa:aa:01' -Signal 60 -Channel 1 -Band '2.4 GHz'))),
            (New-TestNetwork -Ssid 'Guest' -AccessPoints @((New-TestAccessPoint -Mac 'bb:bb:bb:bb:bb:02' -Signal 80 -Channel 44 -Band '5 GHz')))
        )
        $on = [PSCustomObject]@{ Connected = $true; Ssid = 'Guest'; Bssid = 'AA:AA:AA:AA:AA:01'; Band = '2.4 GHz'; Channel = 1; SignalPercent = 60 }
        $report = ConvertTo-DevKitWifiScanReport -Networks $twins -Current $on
        @($report.Networks | Where-Object { $_.IsCurrent }).Count | Should -Be 1
        ($report.Networks | Where-Object { $_.IsCurrent }).Signal | Should -Be 60
    }

    It "falls back to the name when Windows did not say which access point" {
        $on = [PSCustomObject]@{ Connected = $true; Ssid = 'HomeNet'; Bssid = ''; Band = ''; Channel = 0; SignalPercent = $null }
        $report = ConvertTo-DevKitWifiScanReport -Networks $script:Networks -Current $on
        @($report.Networks | Where-Object { $_.IsCurrent } | ForEach-Object { $_.Ssid }) | Should -Be @('HomeNet')
    }

    It "marks nothing as current when this PC is not connected" {
        $report = ConvertTo-DevKitWifiScanReport -Networks $script:Networks -Current $null
        @($report.Networks | Where-Object { $_.IsCurrent }).Count | Should -Be 0
    }

    It "summarises a network's access points: best signal, bands, channels, how many" {
        $mine = $script:Report.Networks | Where-Object { $_.Ssid -eq 'HomeNet' }
        $mine.Signal | Should -Be 86
        $mine.AccessPoints | Should -Be 2
        @($mine.Bands) | Should -Be @('2.4 GHz', '5 GHz')
        @($mine.Channels) | Should -Be @(6, 161)
    }

    It "names a hidden network as hidden rather than dropping it" {
        $hidden = $script:Report.Networks | Where-Object { $_.Hidden }
        @($hidden).Count | Should -Be 1
        $hidden.Auth | Should -Be 'WPA3-Personal'
    }

    It "includes the channel load and the advice the scanner tool prints" {
        @($script:Report.ChannelLoad).Count | Should -BeGreaterThan 0
        ($script:Report.ChannelLoad | Where-Object { $_.Band -eq '2.4 GHz' -and $_.Channel -eq 6 }).AccessPoints | Should -Be 2
        @($script:Report.Advice).Count | Should -BeGreaterThan 0
        @($script:Report.Advice | ForEach-Object { $_.Level }) | ForEach-Object { $_ | Should -BeIn @('good', 'info', 'warn') }
    }

    It "serialises one-network, one-band and one-channel results as lists" {
        $single = @((New-TestNetwork -Ssid 'Only' -AccessPoints @((New-TestAccessPoint -Mac 'aa:aa:aa:aa:aa:01' -Signal 60 -Channel 1 -Band '2.4 GHz'))))
        $json = ConvertTo-DevKitWifiScanReport -Networks $single -Current $null | ConvertTo-Json -Depth 6 -Compress
        $json | Should -Match '"Networks":\[\{'
        $json | Should -Match '"Bands":\["2\.4 GHz"\]'
        $json | Should -Match '"Channels":\[1\]'
        $json | Should -Match '"ChannelLoad":\[\{'
        $json | Should -Match '"Advice":\[\{'
    }

    It "answers a scan that could not be read with the reason and empty lists" {
        foreach ($problem in 'noAdapter', 'locationOff') {
            $report = ConvertTo-DevKitWifiScanReport -Networks @() -RescanState 'denied' -Problem $problem
            $report.Problem | Should -Be $problem
            $report.RescanState | Should -Be 'denied'
            $json = $report | ConvertTo-Json -Depth 6 -Compress
            $json | Should -Match '"Networks":\[\]'
            $json | Should -Match '"Advice":\[\]'
        }
    }

    It "answers an empty scan with empty lists and the 'nothing nearby' advice" {
        $report = ConvertTo-DevKitWifiScanReport -Networks @() -Current $null
        @($report.Networks).Count | Should -Be 0
        @($report.Advice).Count | Should -Be 1
    }
}

Describe "Get-DevKitWifiSnapshot still reads the connection the same way" {

    # The adapter/link/address part of the snapshot moved into
    # Get-DevKitWifiLink so the tray's status line and the optimizer read it
    # identically. The snapshot's own shape must not have changed: the
    # optimizer, the diagnosis and Compare-DevKitWifiSnapshot all read it.

    It "returns the same properties as before, for a PC with no WiFi adapter" {
        Mock Get-NetAdapter { @() }
        $snapshot = Get-DevKitWifiSnapshot
        @($snapshot.PSObject.Properties.Name) | Should -Be @('AdapterPresent', 'InterfaceIndex', 'InterfaceAlias', 'Connected',
            'Ssid', 'Bssid', 'SignalPercent', 'Band', 'Channel', 'RadioType', 'RxMbps', 'TxMbps',
            'IPv4', 'Gateway', 'Portal', 'GatewayPing', 'InternetPing', 'DnsCurrent', 'DnsCandidates', 'DnsIsStatic')
        $snapshot.AdapterPresent | Should -BeFalse
        $snapshot.Connected | Should -BeFalse
    }

    It "reports an adapter that is present but not connected, without probing anything" {
        Mock Get-NetAdapter { [PSCustomObject]@{ Name = 'Wi-Fi'; Status = 'Disconnected'; PhysicalMediaType = 'Native 802.11'; InterfaceIndex = 12; InterfaceGuid = '{GUID}' } }
        Mock Measure-DevKitPingLatency { throw 'no probe may run for a disconnected adapter' }
        Mock Test-DevKitCaptivePortal { throw 'no probe may run for a disconnected adapter' }
        $snapshot = Get-DevKitWifiSnapshot
        $snapshot.AdapterPresent | Should -BeTrue
        $snapshot.Connected | Should -BeFalse
        $snapshot.InterfaceAlias | Should -Be 'Wi-Fi'
        $snapshot.GatewayPing | Should -BeNullOrEmpty
    }

    It "ignores an Ethernet adapter, however it is named" {
        Mock Get-NetAdapter { [PSCustomObject]@{ Name = 'Wireless Dock'; Status = 'Up'; PhysicalMediaType = '802.3'; InterfaceIndex = 3; InterfaceGuid = '{ETH}' } }
        (Get-DevKitWifiLink).AdapterPresent | Should -BeFalse
    }
}
