#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for the pure WiFi logic in tools/lib/DevKit-WiFi.ps1.
.DESCRIPTION
    Covers the parsers (against real Windows 11 netsh output shapes), the
    channel-load and scan-advice analysis, the diagnosis planner that decides
    which fixes a set of measurements justifies, the before/after comparison,
    and the rule that protects the DNS undo file.

    NOTHING HERE TOUCHES A NETWORK SETTING OR NEEDS WIFI HARDWARE. Every
    function under test is pure; the measuring and mutating halves of the
    WiFi tools are deliberately not exercised.
.NOTES
    Pester 5 syntax (dashed `Should -Be`).
    Run with:
        Invoke-Pester -Path .\tests\Unit\WiFiCore.Tests.ps1
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $script:RepoRoot 'tools\lib\DevKit-WiFi.ps1')

    # Shape captured from a real Windows 11 machine (names and addresses
    # replaced): Band line present, a "Bss Load" sub-block with channel
    # utilization, and QoS lines whose values are bare integers.
    $script:Win11Scan = @"

Interface name : Wi-Fi
There are 3 networks currently visible.

SSID 1 : Office
    Network type            : Infrastructure
    Authentication          : WPA2-Personal
    Encryption              : CCMP
    BSSID 1                 : aa:aa:aa:aa:aa:01
         Signal             : 87%
         Radio type         : 802.11ax
         Band               : 5 GHz
         Channel            : 161
         Bss Load:
             Connected Stations:         6
             Channel Utilization:        3 (1 %)
             Medium Available Capacity:  31250 (1000000 us/s)
         QoS MSCS Supported    : 1
         QoS Map Supported     : 0
         Basic rates (Mbps) : 6 12 24
         Other rates (Mbps) : 9 18 36 48 54
    BSSID 2                 : aa:aa:aa:aa:aa:02
         Signal             : 62%
         Radio type         : 802.11n
         Band               : 2.4 GHz
         Channel            : 6
         Bss Load:
             Connected Stations:         14
             Channel Utilization:        180 (70 %)
             Medium Available Capacity:  0 (0 us/s)
         Basic rates (Mbps) : 1 2 5.5 11
         Other rates (Mbps) : 6 9 12 18 24 36 48 54

SSID 2 :
    Network type            : Infrastructure
    Authentication          : WPA3-Personal
    Encryption              : CCMP
    BSSID 1                 : bb:bb:bb:bb:bb:01
         Signal             : 40%
         Radio type         : 802.11ax
         Band               : 6 GHz
         Channel            : 5
         Basic rates (Mbps) : 6 12 24

SSID 3 : Cafe Guest
    Network type            : Infrastructure
    Authentication          : Open
    Encryption              : None
    BSSID 1                 : cc:cc:cc:cc:cc:01
         Signal             : 55%
         Radio type         : 802.11n
         Band               : 2.4 GHz
         Channel            : 4
         Basic rates (Mbps) : 1 2 5.5 11

"@ -replace "`r?`n", "`r`n"

    $script:Win11Interface = @"

There is 1 interface on the system:

    Name                   : Wi-Fi
    Description            : Intel(R) Wi-Fi 6E AX211 160MHz
    GUID                   : 11111111-2222-3333-4444-555555555555
    Physical address       : 0a:0b:0c:0d:0e:0f
    Interface type         : Primary
    State                  : connected
    SSID                   : Office
    AP BSSID               : AA:AA:AA:AA:AA:01
    Band                   : 5 GHz
    Channel                : 161
    Connected Akm-cipher   : [ akm = 00-0f-ac:02, cipher =  00-0f-ac:04 ]
    Network type           : Infrastructure
    Radio type             : 802.11ax
    Authentication         : WPA2-Personal
    Cipher                 : CCMP
    Connection mode        : Auto Connect
    Receive rate (Mbps)    : 287
    Transmit rate (Mbps)   : 144.5
    Signal                 : 87%
    Rssi                   : -49
    Profile                : Office
    QoS MSCS Configured         : 0
    QoS Map Configured          : 0

"@ -replace "`r?`n", "`r`n"

    # A healthy connection; individual tests override one thing at a time.
    function New-TestSnapshot {
        param([hashtable]$Override = @{})
        $base = @{
            AdapterPresent = $true; Connected = $true; Ssid = 'Office'; SignalPercent = 80
            IPv4 = '192.168.1.20'; Gateway = '192.168.1.1'; Portal = 'open'
            GatewayPing = [PSCustomObject]@{ AverageLatency = 3; PacketLossPct = 0; JitterMs = 1 }
            InternetPing = [PSCustomObject]@{ AverageLatency = 20; PacketLossPct = 0; JitterMs = 2 }
            DnsCurrent = [PSCustomObject]@{ Name = 'Current'; Servers = @('192.168.1.1'); MedianMs = 12; FailurePct = 0 }
            DnsCandidates = @(
                [PSCustomObject]@{ Name = 'Cloudflare'; Servers = @('1.1.1.1', '1.0.0.1'); MedianMs = 14; FailurePct = 0 }
                [PSCustomObject]@{ Name = 'Google'; Servers = @('8.8.8.8', '8.8.4.4'); MedianMs = 22; FailurePct = 0 }
            )
        }
        foreach ($key in $Override.Keys) { $base[$key] = $Override[$key] }
        return [PSCustomObject]$base
    }
}

Describe "ConvertTo-DevKitWifiBand" {

    It "normalizes netsh band text" {
        ConvertTo-DevKitWifiBand -BandText '2.4 GHz' | Should -Be '2.4 GHz'
        ConvertTo-DevKitWifiBand -BandText '2,4 GHz' | Should -Be '2.4 GHz'
        ConvertTo-DevKitWifiBand -BandText '5 GHz' | Should -Be '5 GHz'
        ConvertTo-DevKitWifiBand -BandText '6 GHz' | Should -Be '6 GHz'
    }

    It "falls back to the channel when Windows prints no band" {
        ConvertTo-DevKitWifiBand -Channel 11 | Should -Be '2.4 GHz'
        ConvertTo-DevKitWifiBand -Channel 149 | Should -Be '5 GHz'
        ConvertTo-DevKitWifiBand -Channel 0 | Should -Be ''
    }

    It "trusts the band text over the channel, because 6 GHz reuses low channel numbers" {
        ConvertTo-DevKitWifiBand -BandText '6 GHz' -Channel 5 | Should -Be '6 GHz'
    }
}

Describe "ConvertFrom-DevKitWlanScan (Windows 11 output)" {

    BeforeAll {
        $script:Scan = ConvertFrom-DevKitWlanScan -RawOutput $script:Win11Scan
    }

    It "finds every network, including the hidden one" {
        $script:Scan.Count | Should -Be 3
        @($script:Scan | ForEach-Object { $_.SSID }) | Should -Be @('Office', '', 'Cafe Guest')
    }

    It "keeps a hidden network's access point out of the network listed above it" {
        $office = $script:Scan | Where-Object { $_.SSID -eq 'Office' }
        $office.BSSIDs.Count | Should -Be 2
        @($office.BSSIDs | ForEach-Object { $_.MAC }) | Should -Not -Contain 'bb:bb:bb:bb:bb:01'
        $hidden = $script:Scan | Where-Object { $_.SSID -eq '' }
        $hidden.BSSIDs[0].MAC | Should -Be 'bb:bb:bb:bb:bb:01'
    }

    It "reads signal, channel, band and radio type per access point" {
        $ap = ($script:Scan | Where-Object { $_.SSID -eq 'Office' }).BSSIDs[0]
        $ap.Signal | Should -Be 87
        $ap.Channel | Should -Be 161
        $ap.Band | Should -Be '5 GHz'
        $ap.RadioType | Should -Be '802.11ax'
    }

    It "does not mistake Connected Stations or the QoS flags for the channel" {
        $aps = ($script:Scan | Where-Object { $_.SSID -eq 'Office' }).BSSIDs
        $aps[0].Channel | Should -Be 161
        $aps[1].Channel | Should -Be 6
        $aps[0].Stations | Should -Be 6
        $aps[1].Stations | Should -Be 14
    }

    It "reads channel utilization as a percentage, and leaves it null when absent" {
        $aps = ($script:Scan | Where-Object { $_.SSID -eq 'Office' }).BSSIDs
        $aps[0].Utilization | Should -Be 1
        $aps[1].Utilization | Should -Be 70
        ($script:Scan | Where-Object { $_.SSID -eq 'Cafe Guest' }).BSSIDs[0].Utilization | Should -BeNullOrEmpty
    }

    It "keeps a 6 GHz access point on 6 GHz even though its channel number is low" {
        ($script:Scan | Where-Object { $_.SSID -eq '' }).BSSIDs[0].Band | Should -Be '6 GHz'
    }

    It "reads authentication and encryption" {
        $cafe = $script:Scan | Where-Object { $_.SSID -eq 'Cafe Guest' }
        $cafe.Auth | Should -Be 'Open'
        $cafe.Encryption | Should -Be 'None'
    }

    It "parses LF-only input the same way" {
        $lf = $script:Win11Scan -replace "`r`n", "`n"
        (ConvertFrom-DevKitWlanScan -RawOutput $lf).Count | Should -Be 3
    }

    It "reads a non-English block by the shape of its values" {
        $german = @"
Schnittstellenname : WLAN
Momentan sind 1 Netzwerke sichtbar.

SSID 1 : Buero
    Netzwerktyp             : Infrastruktur
    Authentifizierung       : WPA2-Personal
    Verschluesselung        : CCMP
    BSSID 1                 : dd:dd:dd:dd:dd:01
         Signal             : 74%
         Funktyp            : 802.11ac
         Band               : 5 GHz
         Kanal              : 44
         Basisraten (MBit/s) : 6 12 24

"@ -replace "`r?`n", "`r`n"
        $nets = ConvertFrom-DevKitWlanScan -RawOutput $german
        $nets.Count | Should -Be 1
        $nets[0].SSID | Should -Be 'Buero'
        $nets[0].Auth | Should -Be 'WPA2-Personal'
        $nets[0].Encryption | Should -Be 'CCMP'
        $nets[0].BSSIDs[0].Signal | Should -Be 74
        $nets[0].BSSIDs[0].Channel | Should -Be 44
        $nets[0].BSSIDs[0].Band | Should -Be '5 GHz'
        $nets[0].BSSIDs[0].RadioType | Should -Be '802.11ac'
    }
}

Describe "ConvertFrom-DevKitWlanInterface" {

    BeforeAll {
        $script:Interfaces = ConvertFrom-DevKitWlanInterface -RawOutput $script:Win11Interface
    }

    It "returns one adapter as a true array" {
        $script:Interfaces.GetType().IsArray | Should -BeTrue
        $script:Interfaces.Count | Should -Be 1
    }

    It "reads the connection it is on" {
        $i = $script:Interfaces[0]
        $i.Name | Should -Be 'Wi-Fi'
        $i.Connected | Should -BeTrue
        $i.Ssid | Should -Be 'Office'
        $i.Band | Should -Be '5 GHz'
        $i.Channel | Should -Be 161
        $i.RadioType | Should -Be '802.11ax'
        $i.Auth | Should -Be 'WPA2-Personal'
        $i.SignalPercent | Should -Be 87
        $i.RssiDbm | Should -Be -49
        $i.RxMbps | Should -Be 287
        $i.TxMbps | Should -Be 144.5
    }

    It "takes the access point's address, lowercased, and not the adapter's own" {
        $script:Interfaces[0].Bssid | Should -Be 'aa:aa:aa:aa:aa:01'
    }

    It "reports a disconnected adapter as not connected" {
        $raw = @"
There is 1 interface on the system:

    Name                   : Wi-Fi
    Description            : Intel(R) Wi-Fi 6E AX211 160MHz
    Physical address       : 0a:0b:0c:0d:0e:0f
    State                  : disconnected
    Radio status           : Hardware On

"@ -replace "`r?`n", "`r`n"
        $list = ConvertFrom-DevKitWlanInterface -RawOutput $raw
        $list.Count | Should -Be 1
        $list[0].Connected | Should -BeFalse
        $list[0].SignalPercent | Should -BeNullOrEmpty
    }

    It "returns an empty array when there is no wireless interface" {
        (ConvertFrom-DevKitWlanInterface -RawOutput "There is no wireless interface on the system.`r`n").Count | Should -Be 0
        (ConvertFrom-DevKitWlanInterface -RawOutput '').Count | Should -Be 0
    }
}

Describe "Get-DevKitWifiChannelLoad" {

    BeforeAll {
        $script:Load = Get-DevKitWifiChannelLoad -Networks (ConvertFrom-DevKitWlanScan -RawOutput $script:Win11Scan)
    }

    It "has one row per band and channel" {
        $script:Load.Count | Should -Be 4
    }

    It "counts 2.4 GHz neighbours within four channels as overlapping" {
        # Channels 4 and 6 are only 10 MHz apart; each interferes with the other.
        ($script:Load | Where-Object { $_.Band -eq '2.4 GHz' -and $_.Channel -eq 6 }).Overlapping | Should -Be 2
        ($script:Load | Where-Object { $_.Band -eq '2.4 GHz' -and $_.Channel -eq 4 }).Overlapping | Should -Be 2
    }

    It "counts only the same channel on 5 GHz" {
        ($script:Load | Where-Object { $_.Band -eq '5 GHz' -and $_.Channel -eq 161 }).Overlapping | Should -Be 1
    }

    It "does not let a 6 GHz channel 5 collide with 2.4 GHz channels 4 and 6" {
        ($script:Load | Where-Object { $_.Band -eq '6 GHz' -and $_.Channel -eq 5 }).Overlapping | Should -Be 1
    }

    It "carries the busiest reported utilization, null when nobody reported one" {
        ($script:Load | Where-Object { $_.Band -eq '2.4 GHz' -and $_.Channel -eq 6 }).Utilization | Should -Be 70
        ($script:Load | Where-Object { $_.Band -eq '2.4 GHz' -and $_.Channel -eq 4 }).Utilization | Should -BeNullOrEmpty
    }

    It "returns an empty array for an empty scan" {
        (Get-DevKitWifiChannelLoad -Networks @()).Count | Should -Be 0
    }
}

Describe "Get-DevKitWifiScanAdvice" {

    BeforeAll {
        $script:Networks = ConvertFrom-DevKitWlanScan -RawOutput $script:Win11Scan
        function New-TestConnection {
            param([string]$Bssid, [string]$Band, [int]$Signal)
            [PSCustomObject]@{ Connected = $true; Ssid = 'Office'; Bssid = $Bssid; Band = $Band; SignalPercent = $Signal }
        }
    }

    It "says nothing needs changing on a strong 5 GHz connection" {
        $advice = Get-DevKitWifiScanAdvice -Networks $script:Networks -Current (New-TestConnection 'aa:aa:aa:aa:aa:01' '5 GHz' 87)
        $advice.Count | Should -Be 1
        $advice[0].Level | Should -Be 'good'
    }

    It "points out the 5 GHz access point when connected on 2.4 GHz" {
        $advice = Get-DevKitWifiScanAdvice -Networks $script:Networks -Current (New-TestConnection 'aa:aa:aa:aa:aa:02' '2.4 GHz' 62)
        ($advice | Where-Object { $_.Text -match 'also in range on 5 GHz at 87%' }) | Should -Not -BeNullOrEmpty
    }

    It "reports a busy channel from the access point's own utilization" {
        $advice = Get-DevKitWifiScanAdvice -Networks $script:Networks -Current (New-TestConnection 'aa:aa:aa:aa:aa:02' '2.4 GHz' 62)
        ($advice | Where-Object { $_.Level -eq 'warn' -and $_.Text -match '70% busy' }) | Should -Not -BeNullOrEmpty
    }

    It "warns about a weak signal" {
        $advice = Get-DevKitWifiScanAdvice -Networks $script:Networks -Current (New-TestConnection 'aa:aa:aa:aa:aa:01' '5 GHz' 30)
        ($advice | Where-Object { $_.Level -eq 'warn' -and $_.Text -match 'weak \(30%\)' }) | Should -Not -BeNullOrEmpty
    }

    It "never calls an open network the best SECURED one" {
        # The old scanner printed the strongest network of any kind under
        # "Best secured network". Make the open network the strongest here.
        $nets = ConvertFrom-DevKitWlanScan -RawOutput ($script:Win11Scan -replace 'Signal             : 55%', 'Signal             : 99%')
        $advice = Get-DevKitWifiScanAdvice -Networks $nets
        $secured = $advice | Where-Object { $_.Text -match '^Strongest secured network' }
        $secured.Text | Should -Match "'Office'"
        $secured.Text | Should -Not -Match 'Cafe Guest'
        ($advice | Where-Object { $_.Text -match "^Strongest open network: 'Cafe Guest' \(99%\)" }) | Should -Not -BeNullOrEmpty
    }

    It "says so when nothing usable is nearby" {
        $advice = Get-DevKitWifiScanAdvice -Networks @()
        $advice[0].Text | Should -Match 'No usable networks'
    }
}

Describe "Get-DevKitWifiDiagnosis" {

    It "plans nothing for a healthy connection" {
        $d = Get-DevKitWifiDiagnosis -Snapshot (New-TestSnapshot)
        $d.Healthy | Should -BeTrue
        $d.Actions.Count | Should -Be 0
        $d.Findings.Count | Should -Be 0
    }

    It "never plans the network-stack reset by itself" {
        $bad = New-TestSnapshot @{
            SignalPercent = 20
            GatewayPing = [PSCustomObject]@{ AverageLatency = 90; PacketLossPct = 30; JitterMs = 60 }
            InternetPing = [PSCustomObject]@{ AverageLatency = 400; PacketLossPct = 40; JitterMs = 80 }
            DnsCurrent = [PSCustomObject]@{ Name = 'Current'; Servers = @('192.168.1.1'); MedianMs = $null; FailurePct = 100 }
        }
        (Get-DevKitWifiDiagnosis -Snapshot $bad).Actions | Should -Not -Contain 'ResetStack'
    }

    It "reports a missing or disconnected adapter and plans nothing" {
        $none = Get-DevKitWifiDiagnosis -Snapshot (New-TestSnapshot @{ AdapterPresent = $false })
        $none.Findings[0].Code | Should -Be 'NoAdapter'
        $none.Actions.Count | Should -Be 0
        $off = Get-DevKitWifiDiagnosis -Snapshot (New-TestSnapshot @{ Connected = $false })
        $off.Findings[0].Code | Should -Be 'NotConnected'
        $off.Actions.Count | Should -Be 0
    }

    It "treats a weak signal as something no setting fixes" {
        $d = Get-DevKitWifiDiagnosis -Snapshot (New-TestSnapshot @{ SignalPercent = 25 })
        $d.Findings.Code | Should -Contain 'WeakSignal'
        $d.Actions.Count | Should -Be 0
        $d.Healthy | Should -BeFalse
    }

    It "renews the lease when there is no usable address - <case>" -ForEach @(
        @{ case = 'no address'; override = @{ IPv4 = '' } }
        @{ case = 'self-assigned address'; override = @{ IPv4 = '169.254.10.20' } }
        @{ case = 'no gateway'; override = @{ Gateway = '' } }
    ) {
        $d = Get-DevKitWifiDiagnosis -Snapshot (New-TestSnapshot $override)
        $d.Findings.Code | Should -Contain 'NoAddress'
        $d.Actions | Should -Be @('RenewLease')
    }

    It "renews the lease, then restarts the adapter, when neither the router nor anything beyond it answers" {
        $d = Get-DevKitWifiDiagnosis -Snapshot (New-TestSnapshot @{
                Portal = 'offline'
                GatewayPing = [PSCustomObject]@{ AverageLatency = $null; PacketLossPct = 100; JitterMs = $null }
                InternetPing = [PSCustomObject]@{ AverageLatency = $null; PacketLossPct = 100; JitterMs = $null }
            })
        $d.Findings.Code | Should -Contain 'GatewayUnreachable'
        $d.Actions | Should -Be @('RenewLease', 'RestartAdapter')
    }

    It "does not bounce the adapter because the router ignores ping while the internet works - <case>" -ForEach @(
        @{ case = 'internet pings answer'; override = @{ Portal = 'unknown' } }
        @{ case = 'web probe answers, ping blocked everywhere'; override = @{ Portal = 'open'; InternetPing = [PSCustomObject]@{ AverageLatency = $null; PacketLossPct = 100; JitterMs = $null } } }
    ) {
        # A VPN that blocks LAN access, or a guest gateway that drops ICMP:
        # the old rule read the silent router as a dead link and planned a
        # lease release plus an adapter restart on a working connection.
        $silent = @{ GatewayPing = [PSCustomObject]@{ AverageLatency = $null; PacketLossPct = 100; JitterMs = $null } }
        foreach ($key in $override.Keys) { $silent[$key] = $override[$key] }
        $d = Get-DevKitWifiDiagnosis -Snapshot (New-TestSnapshot $silent)
        $d.Findings.Code | Should -Contain 'GatewayPingBlocked'
        $d.Findings.Code | Should -Not -Contain 'GatewayUnreachable'
        $d.Actions | Should -Not -Contain 'RestartAdapter'
        $d.Actions | Should -Not -Contain 'RenewLease'
        $d.Healthy | Should -BeTrue
    }

    It "does not flag one lost ping in ten as a lossy connection" {
        $d = Get-DevKitWifiDiagnosis -Snapshot (New-TestSnapshot @{
                GatewayPing = [PSCustomObject]@{ AverageLatency = 3; PacketLossPct = 10; JitterMs = 1 }
                InternetPing = [PSCustomObject]@{ AverageLatency = 20; PacketLossPct = 10; JitterMs = 2 }
            })
        $d.Healthy | Should -BeTrue
    }

    It "hands DNS back to the network when DNS pinned on the adapter is failing here" {
        # The roaming-laptop case: an earlier run pinned public DNS, and this
        # network (a sign-in page, a company network) blocks outside DNS.
        $d = Get-DevKitWifiDiagnosis -Snapshot (New-TestSnapshot @{
                Portal = 'offline'; DnsIsStatic = $true
                DnsCurrent = [PSCustomObject]@{ Name = 'Current'; Servers = @('1.1.1.1', '1.0.0.1'); MedianMs = $null; FailurePct = 100 }
                DnsCandidates = @()
                InternetPing = [PSCustomObject]@{ AverageLatency = 20; PacketLossPct = 0; JitterMs = 2 }
            })
        $d.Findings.Code | Should -Contain 'StaticDnsFailing'
        $d.Actions | Should -Be @('FlushDns', 'RestoreAutoDns')
    }

    It "restores automatic DNS even behind a sign-in page, where it is what makes the page reachable" {
        $d = Get-DevKitWifiDiagnosis -Snapshot (New-TestSnapshot @{
                Portal = 'portal'; DnsIsStatic = $true
                DnsCurrent = [PSCustomObject]@{ Name = 'Current'; Servers = @('1.1.1.1'); MedianMs = $null; FailurePct = 100 }
            })
        $d.Actions | Should -Contain 'RestoreAutoDns'
        $d.Actions | Should -Not -Contain 'SwitchDns'
    }

    It "leaves failing pinned DNS alone under -KeepDns, but still says what is wrong" {
        $d = Get-DevKitWifiDiagnosis -KeepDns -Snapshot (New-TestSnapshot @{
                DnsIsStatic = $true
                DnsCurrent = [PSCustomObject]@{ Name = 'Current'; Servers = @('1.1.1.1'); MedianMs = $null; FailurePct = 100 }
            })
        $d.Findings.Code | Should -Contain 'StaticDnsFailing'
        $d.Actions | Should -Be @('FlushDns')
    }

    It "does not override a resolver that is only moderately slower" {
        # 35 ms against 14 ms: plausibly a filtering or company resolver
        # someone chose. Not worth replacing for 21 ms.
        $d = Get-DevKitWifiDiagnosis -Snapshot (New-TestSnapshot @{
                DnsCurrent = [PSCustomObject]@{ Name = 'Current'; Servers = @('192.168.1.2'); MedianMs = 35; FailurePct = 0 }
            })
        $d.Actions | Should -Not -Contain 'SwitchDns'
    }

    It "never combines a DNS switch with the stack reset" {
        $d = Get-DevKitWifiDiagnosis -Deep -Snapshot (New-TestSnapshot @{
                DnsCurrent = [PSCustomObject]@{ Name = 'Current'; Servers = @('10.0.0.1'); MedianMs = 180; FailurePct = 0 }
            })
        $d.Actions | Should -Not -Contain 'SwitchDns'
        $d.Actions | Should -Contain 'ResetStack'
    }

    It "reports an unstable link to the router without planning a fix" {
        $d = Get-DevKitWifiDiagnosis -Snapshot (New-TestSnapshot @{
                GatewayPing = [PSCustomObject]@{ AverageLatency = 80; PacketLossPct = 20; JitterMs = 45 }
            })
        $d.Findings.Code | Should -Contain 'PoorLink'
        $d.Actions.Count | Should -Be 0
    }

    It "blames the far side when the router answers and the internet does not" {
        $d = Get-DevKitWifiDiagnosis -Snapshot (New-TestSnapshot @{
                Portal = 'offline'
                InternetPing = [PSCustomObject]@{ AverageLatency = $null; PacketLossPct = 100; JitterMs = $null }
                DnsCurrent = [PSCustomObject]@{ Name = 'Current'; Servers = @('192.168.1.1'); MedianMs = 5; FailurePct = 0 }
                DnsCandidates = @()
            })
        $d.Findings.Code | Should -Contain 'NoInternet'
        $d.Actions.Count | Should -Be 0
    }

    It "does not call a ping-blocking network an outage" {
        $d = Get-DevKitWifiDiagnosis -Snapshot (New-TestSnapshot @{
                Portal = 'open'
                InternetPing = [PSCustomObject]@{ AverageLatency = $null; PacketLossPct = 100; JitterMs = $null }
            })
        $d.Findings.Code | Should -Contain 'PingBlocked'
        $d.Findings.Code | Should -Not -Contain 'NoInternet'
        $d.Healthy | Should -BeTrue
    }

    It "switches DNS when the current servers are clearly slower" {
        $d = Get-DevKitWifiDiagnosis -Snapshot (New-TestSnapshot @{
                DnsCurrent = [PSCustomObject]@{ Name = 'Current'; Servers = @('10.0.0.1'); MedianMs = 180; FailurePct = 0 }
            })
        $d.Findings.Code | Should -Contain 'DnsSlow'
        $d.Actions | Should -Be @('SwitchDns')
        $d.BestDns.Name | Should -Be 'Cloudflare'
    }

    It "leaves DNS alone when the difference is noise" {
        $d = Get-DevKitWifiDiagnosis -Snapshot (New-TestSnapshot @{
                DnsCurrent = [PSCustomObject]@{ Name = 'Current'; Servers = @('10.0.0.1'); MedianMs = 25; FailurePct = 0 }
            })
        $d.Actions | Should -Not -Contain 'SwitchDns'
        $d.Healthy | Should -BeTrue
    }

    It "flushes and switches DNS when the current servers are failing" {
        $d = Get-DevKitWifiDiagnosis -Snapshot (New-TestSnapshot @{
                DnsCurrent = [PSCustomObject]@{ Name = 'Current'; Servers = @('10.0.0.1'); MedianMs = $null; FailurePct = 100 }
            })
        $d.Findings.Code | Should -Contain 'DnsFailing'
        $d.Actions | Should -Be @('FlushDns', 'SwitchDns')
    }

    It "never switches DNS behind a sign-in page" {
        $d = Get-DevKitWifiDiagnosis -Snapshot (New-TestSnapshot @{
                Portal = 'portal'
                DnsCurrent = [PSCustomObject]@{ Name = 'Current'; Servers = @('10.0.0.1'); MedianMs = 180; FailurePct = 0 }
            })
        $d.Findings.Code | Should -Contain 'CaptivePortal'
        $d.Actions | Should -Not -Contain 'SwitchDns'
    }

    It "honours -KeepDns" {
        $d = Get-DevKitWifiDiagnosis -KeepDns -Snapshot (New-TestSnapshot @{
                DnsCurrent = [PSCustomObject]@{ Name = 'Current'; Servers = @('10.0.0.1'); MedianMs = 180; FailurePct = 0 }
            })
        $d.Actions | Should -Not -Contain 'SwitchDns'
    }

    It "does not offer the servers already in use as the alternative" {
        $d = Get-DevKitWifiDiagnosis -Snapshot (New-TestSnapshot @{
                DnsCurrent = [PSCustomObject]@{ Name = 'Current'; Servers = @('1.1.1.1', '1.0.0.1'); MedianMs = 14; FailurePct = 0 }
            })
        $d.BestDns.Name | Should -Be 'Google'
        $d.Actions | Should -Not -Contain 'SwitchDns'
    }

    It "ignores a candidate that dropped queries, however fast" {
        $d = Get-DevKitWifiDiagnosis -Snapshot (New-TestSnapshot @{
                DnsCurrent = [PSCustomObject]@{ Name = 'Current'; Servers = @('10.0.0.1'); MedianMs = 180; FailurePct = 0 }
                DnsCandidates = @(
                    [PSCustomObject]@{ Name = 'Flaky'; Servers = @('9.9.9.9'); MedianMs = 2; FailurePct = 40 }
                    [PSCustomObject]@{ Name = 'Google'; Servers = @('8.8.8.8'); MedianMs = 22; FailurePct = 0 }
                )
            })
        $d.BestDns.Name | Should -Be 'Google'
    }

    It "adds the stack reset only when -Deep asks for it, last in the order" {
        $d = Get-DevKitWifiDiagnosis -Deep -Snapshot (New-TestSnapshot)
        $d.Actions | Should -Be @('RenewLease', 'ResetStack')
    }
}

Describe "Compare-DevKitWifiSnapshot" {

    It "calls a clear DNS improvement better" {
        $before = New-TestSnapshot @{ DnsCurrent = [PSCustomObject]@{ MedianMs = 180; FailurePct = 0 } }
        $after = New-TestSnapshot @{ DnsCurrent = [PSCustomObject]@{ MedianMs = 14; FailurePct = 0 } }
        $c = Compare-DevKitWifiSnapshot -Before $before -After $after
        ($c.Rows | Where-Object { $_.Metric -eq 'DNS answer time' }).Verdict | Should -Be 'better'
        $c.Overall | Should -Be 'better'
    }

    It "calls run-to-run noise the same" {
        $before = New-TestSnapshot
        $after = New-TestSnapshot @{ InternetPing = [PSCustomObject]@{ AverageLatency = 22; PacketLossPct = 0; JitterMs = 2 } }
        (Compare-DevKitWifiSnapshot -Before $before -After $after).Overall | Should -Be 'same'
    }

    It "says so when a change made things worse" {
        $before = New-TestSnapshot
        $after = New-TestSnapshot @{ DnsCurrent = [PSCustomObject]@{ MedianMs = 140; FailurePct = 20 } }
        $c = Compare-DevKitWifiSnapshot -Before $before -After $after
        $c.Overall | Should -Be 'worse'
    }

    It "counts a measurement that only works afterwards as better" {
        $before = New-TestSnapshot @{ DnsCurrent = [PSCustomObject]@{ MedianMs = $null; FailurePct = 100 } }
        $after = New-TestSnapshot @{ DnsCurrent = [PSCustomObject]@{ MedianMs = 15; FailurePct = 0 } }
        $c = Compare-DevKitWifiSnapshot -Before $before -After $after
        ($c.Rows | Where-Object { $_.Metric -eq 'DNS answer time' }).Verdict | Should -Be 'better'
    }

    It "marks a metric n/a when it could not be measured either time" {
        $blank = New-TestSnapshot @{ InternetPing = $null }
        $c = Compare-DevKitWifiSnapshot -Before $blank -After $blank
        ($c.Rows | Where-Object { $_.Metric -eq 'Internet latency' }).Verdict | Should -Be 'n/a'
    }
}

Describe "Test-DevKitDnsBackupNeeded" {

    It "writes a backup when there is none" {
        Test-DevKitDnsBackupNeeded -ExistingBackup $null -CurrentServers @('192.168.1.1') | Should -BeTrue
    }

    It "keeps the original backup on a second run, when the servers in place are DevKit's own" {
        # The bug: run 1 backs up the router's DNS and applies Cloudflare;
        # run 2 backed up Cloudflare over it, and Undo restored Cloudflare.
        $original = [PSCustomObject]@{ InterfaceAlias = 'Wi-Fi'; IPv4 = @('192.168.1.1'); IPv6 = @() }
        Test-DevKitDnsBackupNeeded -ExistingBackup $original -InterfaceAlias 'Wi-Fi' `
            -CurrentServers @('1.1.1.1', '1.0.0.1', '2606:4700:4700::1111', '2606:4700:4700::1001') | Should -BeFalse
    }

    It "replaces the backup when the servers in place are someone else's" {
        $old = [PSCustomObject]@{ InterfaceAlias = 'Wi-Fi'; IPv4 = @('192.168.1.1'); IPv6 = @() }
        Test-DevKitDnsBackupNeeded -ExistingBackup $old -InterfaceAlias 'Wi-Fi' -CurrentServers @('10.20.30.40') | Should -BeTrue
    }

    It "replaces the backup when the adapter is back on automatic DNS" {
        $old = [PSCustomObject]@{ InterfaceAlias = 'Wi-Fi'; IPv4 = @('192.168.1.1'); IPv6 = @() }
        Test-DevKitDnsBackupNeeded -ExistingBackup $old -InterfaceAlias 'Wi-Fi' -CurrentServers @() | Should -BeTrue
    }

    It "replaces a backup that belongs to a different adapter" {
        $other = [PSCustomObject]@{ InterfaceAlias = 'Wi-Fi 2'; IPv4 = @('192.168.1.1'); IPv6 = @() }
        Test-DevKitDnsBackupNeeded -ExistingBackup $other -InterfaceAlias 'Wi-Fi' -CurrentServers @('1.1.1.1') | Should -BeTrue
    }

    It "replaces the backup when DNS is automatic, even if the network hands out a public resolver" {
        $old = [PSCustomObject]@{ InterfaceAlias = 'Wi-Fi'; IPv4 = @('10.20.30.40'); IPv6 = @() }
        Test-DevKitDnsBackupNeeded -ExistingBackup $old -InterfaceAlias 'Wi-Fi' -CurrentServers @('1.1.1.1') -CurrentIsStatic $false | Should -BeTrue
    }
}

Describe "Get-DevKitDnsRestorePlan" {

    It "restores automatic DNS as automatic, not as pinned addresses" {
        # The normal laptop case: DNS came from the network. Re-applying the
        # addresses as static would leave no working DNS on the next network.
        $backup = [PSCustomObject]@{ IPv4 = @('192.168.1.1'); IPv6 = @(); IPv4Static = $false; IPv6Static = $false }
        $plan = Get-DevKitDnsRestorePlan -Backup $backup
        $plan.IPv4.Count | Should -Be 0
        $plan.IPv6.Count | Should -Be 0
    }

    It "re-applies addresses that were set by hand" {
        $backup = [PSCustomObject]@{ IPv4 = @('10.0.0.53', '10.0.0.54'); IPv6 = @('fd00::53'); IPv4Static = $true; IPv6Static = $false }
        $plan = Get-DevKitDnsRestorePlan -Backup $backup
        $plan.IPv4 | Should -Be @('10.0.0.53', '10.0.0.54')
        $plan.IPv6.Count | Should -Be 0
    }

    It "re-applies the saved addresses of an undo file from before the flags existed" {
        $legacy = [PSCustomObject]@{ IPv4 = @('192.168.1.1'); IPv6 = @() }
        $plan = Get-DevKitDnsRestorePlan -Backup $legacy
        $plan.IPv4 | Should -Be @('192.168.1.1')
        $plan.IPv6.Count | Should -Be 0
    }
}

Describe "Get-DevKitDnsCandidates" {

    It "offers more than the two providers the old tool knew" {
        $names = @(Get-DevKitDnsCandidates | ForEach-Object { $_.Name })
        $names.Count | Should -BeGreaterThan 2
        $names | Should -Contain 'Cloudflare'
        $names | Should -Contain 'Google'
    }

    It "gives every provider two IPv4 and two IPv6 addresses" {
        foreach ($c in (Get-DevKitDnsCandidates)) {
            $c.IPv4.Count | Should -Be 2
            $c.IPv6.Count | Should -Be 2
            foreach ($address in ($c.IPv4 + $c.IPv6)) {
                $parsed = $null
                [System.Net.IPAddress]::TryParse($address, [ref]$parsed) | Should -BeTrue -Because $address
            }
        }
    }
}

Describe "the library's arrays survive being filtered by their callers" {

    # ConvertFrom-DevKitWlanInterface and Get-DevKitWifiChannelLoad return
    # their arrays behind a unary comma (so a 0- or 1-element result stays an
    # array for callers that index it). The price: piped STRAIGHT into
    # Where-Object, the whole array arrives as one item. Every caller must
    # assign first. These tests pin the callers that live in the library.

    It "flags a crowded 2.4 GHz channel by counting overlapping access points" {
        $networks = @(
            @{ SSID = 'Mine'; Auth = 'WPA2-Personal'; Encryption = 'CCMP'; BSSIDs = @(
                    @{ MAC = 'aa:aa:aa:aa:aa:01'; Signal = 80; Channel = 6; Band = '2.4 GHz'; RadioType = '802.11n'; Utilization = $null; Stations = $null }
                )
            }
        )
        foreach ($i in 1..5) {
            $networks += @{ SSID = "Neighbour$i"; Auth = 'WPA2-Personal'; Encryption = 'CCMP'; BSSIDs = @(
                    @{ MAC = "bb:bb:bb:bb:bb:0$i"; Signal = 50; Channel = (3 + $i); Band = '2.4 GHz'; RadioType = '802.11n'; Utilization = $null; Stations = $null }
                )
            }
        }
        # A 5 GHz bystander: with the piping bug its row was swept into the
        # same "match" and the advice named channels "4 5 6 7 8 36".
        $networks += @{ SSID = 'Far'; Auth = 'WPA2-Personal'; Encryption = 'CCMP'; BSSIDs = @(
                @{ MAC = 'cc:cc:cc:cc:cc:01'; Signal = 40; Channel = 36; Band = '5 GHz'; RadioType = '802.11ac'; Utilization = $null; Stations = $null }
            )
        }
        $current = [PSCustomObject]@{ Connected = $true; Ssid = 'Mine'; Bssid = 'aa:aa:aa:aa:aa:01'; Band = '2.4 GHz'; SignalPercent = 80 }

        $advice = Get-DevKitWifiScanAdvice -Networks $networks -Current $current
        $crowded = @($advice | Where-Object { $_.Text -match 'is crowded' })
        $crowded.Count | Should -Be 1
        $crowded[0].Text | Should -Match '^Channel 6 is crowded: \d+ access points overlap it'
    }

    It "does not call a clean 5 GHz channel crowded because a 2.4 GHz channel is" {
        $networks = @(
            @{ SSID = 'Mine'; Auth = 'WPA2-Personal'; Encryption = 'CCMP'; BSSIDs = @(
                    @{ MAC = 'aa:aa:aa:aa:aa:01'; Signal = 80; Channel = 36; Band = '5 GHz'; RadioType = '802.11ac'; Utilization = $null; Stations = $null }
                )
            }
        )
        foreach ($i in 1..6) {
            $networks += @{ SSID = "Neighbour$i"; Auth = 'WPA2-Personal'; Encryption = 'CCMP'; BSSIDs = @(
                    @{ MAC = "bb:bb:bb:bb:bb:0$i"; Signal = 50; Channel = 6; Band = '2.4 GHz'; RadioType = '802.11n'; Utilization = $null; Stations = $null }
                )
            }
        }
        $current = [PSCustomObject]@{ Connected = $true; Ssid = 'Mine'; Bssid = 'aa:aa:aa:aa:aa:01'; Band = '5 GHz'; SignalPercent = 80 }
        $advice = Get-DevKitWifiScanAdvice -Networks $networks -Current $current
        @($advice | Where-Object { $_.Text -match 'crowded' }).Count | Should -Be 0
    }
}

Describe "ConvertFrom-DevKitWlanInterface (more than the one happy adapter)" {

    It "keeps two adapters apart, so a disconnected one never borrows the other's connection" {
        $raw = @"

There are 2 interfaces on the system:

    Name                   : Wi-Fi
    Description            : Intel(R) Wi-Fi 6E AX211 160MHz
    State                  : disconnected
    Radio status           : Hardware On

    Name                   : Wi-Fi 2
    Description            : USB Wireless Adapter
    State                  : connected
    SSID                   : Office
    AP BSSID               : aa:aa:aa:aa:aa:01
    Band                   : 5 GHz
    Channel                : 44
    Signal                 : 70%

"@ -replace "`r?`n", "`r`n"
        $list = ConvertFrom-DevKitWlanInterface -RawOutput $raw
        $list.Count | Should -Be 2
        $list[0].Connected | Should -BeFalse
        $list[1].Connected | Should -BeTrue
        # The way every caller must filter it: assign, THEN pipe.
        $connected = @($list | Where-Object { $_.Connected })
        $connected.Count | Should -Be 1
        $connected[0].Name | Should -Be 'Wi-Fi 2'
        $connected[0].Ssid | Should -Be 'Office'
    }

    It "does not invent an adapter out of the header sentence on a non-English Windows" {
        $raw = @"

Es ist 1 Schnittstelle auf dem System vorhanden:

    Name                   : WLAN
    Beschreibung           : Intel(R) Wi-Fi 6E AX211 160MHz
    Status                 : Verbunden
    SSID                   : Buero
    AP-BSSID               : dd:dd:dd:dd:dd:01
    Band                   : 5 GHz
    Kanal                  : 44
    Funktyp                : 802.11ac
    Empfangsrate (Mbps)    : 866.7
    Uebertragungsrate (Mbps) : 433.3
    Signal                 : 74%

"@ -replace "`r?`n", "`r`n"
        $list = ConvertFrom-DevKitWlanInterface -RawOutput $raw
        $list.Count | Should -Be 1
        $list[0].Name | Should -Be 'WLAN'
        $list[0].Connected | Should -BeTrue
        $list[0].Channel | Should -Be 44
        $list[0].SignalPercent | Should -Be 74
        $list[0].RxMbps | Should -Be 866.7
        $list[0].TxMbps | Should -Be 433.3
    }

    It "does not let a profile named after a band overwrite the real band" {
        $raw = $script:Win11Interface -replace 'Profile                : Office', 'Profile                : Home-2.4GHz'
        (ConvertFrom-DevKitWlanInterface -RawOutput $raw)[0].Band | Should -Be '5 GHz'
    }
}

Describe "Compare-DevKitWifiSnapshot noise floors" {

    It "does not let one stray lost ping cancel out a real DNS improvement" {
        $before = New-TestSnapshot @{ DnsCurrent = [PSCustomObject]@{ MedianMs = 180; FailurePct = 0 } }
        $after = New-TestSnapshot @{
            DnsCurrent = [PSCustomObject]@{ MedianMs = 14; FailurePct = 0 }
            InternetPing = [PSCustomObject]@{ AverageLatency = 20; PacketLossPct = 10; JitterMs = 2 }
        }
        $c = Compare-DevKitWifiSnapshot -Before $before -After $after
        ($c.Rows | Where-Object { $_.Metric -eq 'Internet packet loss' }).Verdict | Should -Be 'same'
        $c.Overall | Should -Be 'better'
    }
}

Describe "tools/wifi/_module.psd1 against the scripts it runs" {

    BeforeAll {
        $script:WifiDir = Join-Path $script:RepoRoot 'tools\wifi'
        $script:WifiManifest = Import-PowerShellDataFile -Path (Join-Path $script:WifiDir '_module.psd1')

        function Get-ScriptParameterNames {
            param([string]$Script)
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:WifiDir $Script), [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0
            return @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        }
    }

    It "only passes static arguments the script declares" {
        foreach ($item in $script:WifiManifest.Items) {
            if (-not $item.StaticArgs) { continue }
            $declared = Get-ScriptParameterNames -Script $item.Script
            foreach ($key in $item.StaticArgs.Keys) {
                # The one deliberate exception: WiFi-FastMode.ps1 has no
                # CmdletBinding so that it can absorb a -Fast it does not
                # declare (see its header note).
                if ($item.Script -eq 'WiFi-FastMode.ps1' -and $key -eq 'Fast') { continue }
                $declared | Should -Contain $key -Because "$($item.Label) passes -$key to $($item.Script)"
            }
        }
    }

    It "keeps WiFi-FastMode.ps1 able to absorb -Fast (no CmdletBinding)" {
        $source = Get-Content -LiteralPath (Join-Path $script:WifiDir 'WiFi-FastMode.ps1') -Raw
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
        @($ast.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }).Count | Should -Be 0
    }

    It "flags every item that can change a setting as caution, and no read-only one" {
        # "Safety note:" in the Help is what makes the app confirm first and
        # pass -Force. Without it a fix item would run with no approval and
        # then decline (changing nothing while looking like success); with it
        # on a read-only item the user confirms an action that cannot happen.
        foreach ($item in $script:WifiManifest.Items) {
            $readOnly = ($item.Script -eq 'WiFi-Scan.ps1') -or ($item.StaticArgs -and $item.StaticArgs.ContainsKey('DiagnoseOnly'))
            if ($readOnly) {
                $item.Help | Should -Not -Match 'Safety note:' -Because $item.Label
            } else {
                $item.Help | Should -Match 'Safety note:' -Because $item.Label
            }
        }
    }

    It "declares -Force on every script behind a caution item" {
        foreach ($item in $script:WifiManifest.Items) {
            if ($item.Help -notmatch 'Safety note:') { continue }
            Get-ScriptParameterNames -Script $item.Script | Should -Contain 'Force' -Because $item.Label
        }
    }
}
