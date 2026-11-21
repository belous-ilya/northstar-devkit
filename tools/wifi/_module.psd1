@{
    Name        = "WiFi Tools"
    Description = "Check, fix and scan a WiFi connection. The check measures signal, the router, the internet and DNS speed and says in plain words what is wrong; the fix applies only what those measurements call for and then measures again to show whether it helped. Checking and scanning are read-only and need no administrator rights; applying a fix does."
    Items       = @(
        @{
            Key        = '1'
            Label      = 'WiFi Check (Measure and Diagnose)'
            Script     = 'WiFi-Optimize.ps1'
            StaticArgs = @{ DiagnoseOnly = $true }
            Help       = "Measures the connection and reports what it finds, changing nothing: signal strength, band and link rate; response time, packet loss and jitter to the router and to the internet; whether a hotel/cafe style sign-in page is in the way; how fast the DNS servers in use really answer compared with Cloudflare, Google, Quad9 and OpenDNS (real lookups, not pings); then a download and upload speed test. Ends with the findings in plain words and the exact steps a fix run would take - or 'nothing to fix'. Fully read-only and needs no administrator rights. Run this first whenever WiFi feels slow."
        }
        @{
            Key    = '2'
            Label  = 'WiFi Fix (Diagnose, Then Fix Only What Is Wrong)'
            Script = 'WiFi-Optimize.ps1'
            Help   = "Runs the same measurements as WiFi Check, then applies ONLY the fixes they call for, least invasive first: clear the DNS cache, switch DNS to the fastest resolver that answered every lookup, renew the address, restart the WiFi adapter. Afterwards it measures again and shows before and after side by side; a DNS switch that made things worse is rolled back automatically. A healthy connection gets no changes at all, and problems no setting can repair (weak signal, a crowded channel, an outage past the router) are reported rather than 'fixed'. Safety note: when something is wrong this changes real network settings and can briefly disconnect you - requires administrator privileges, lists the exact steps and asks for y/n confirmation before applying anything unless -Force is passed, and never changes DNS behind a sign-in page. DNS settings from before DevKit's first change are saved once and kept across runs; undo with the Undo DNS Change item. -KeepDNS leaves DNS untouched; -Fast skips the speed test."
        }
        @{
            Key        = '3'
            Label      = 'WiFi Fix (Fast Mode)'
            Script     = 'WiFi-FastMode.ps1'
            StaticArgs = @{ Fast = $true }
            Help       = "The same diagnose-then-fix run as WiFi Fix without the download/upload speed test at the end, for a quicker pass - internally it calls WiFi-Optimize.ps1 -Fast. Safety note: identical to WiFi Fix - it changes real network settings only when the measurements call for it, requires administrator privileges, and asks for y/n confirmation before applying anything unless -Force is passed. Supports -KeepDNS; undo a DNS change with the Undo DNS Change item."
        }
        @{
            Key        = '4'
            Label      = 'WiFi Deep Reset (Network Stack)'
            Script     = 'WiFi-Optimize.ps1'
            StaticArgs = @{ Deep = $true }
            Help       = "The last resort, for a connection that stays broken after WiFi Fix: on top of whatever the diagnosis calls for, it renews the address and resets Winsock and TCP/IP to their defaults. Safety note: this drops the connection and requires a Windows restart to complete - requires administrator privileges and asks for y/n confirmation unless -Force is passed. It does not make a working connection faster; use WiFi Check first to see whether a reset is even relevant."
        }
        @{
            Key        = '5'
            Label      = 'Undo DNS Change'
            Script     = 'WiFi-Optimize.ps1'
            StaticArgs = @{ RestoreDns = $true }
            Help       = "Puts the WiFi adapter's DNS back to what it was before DevKit first changed it, and touches nothing else. Automatic DNS (handed out by the network, the normal case on a laptop) is restored as automatic rather than pinned to one network's addresses. Safety note: changes real DNS settings on the adapter - requires administrator privileges. Reports clearly, and changes nothing, when there is no saved state to restore."
        }
        @{
            Key    = '6'
            Label  = 'WiFi Scanner'
            Script = 'WiFi-Scan.ps1'
            Help   = "Asks the adapter for a fresh scan (it does not drop the connection), then lists every network in range sorted by signal, with security type, band (2.4 / 5 / 6 GHz) and channel, and marks the one this PC is connected to. Adds which channels are crowded - counting 2.4 GHz neighbours that overlap, and the airtime the access points themselves report - and what is worth changing: a faster 5 GHz access point of the same network in range, a much stronger access point nearby, a weak signal. Read-only - makes no changes. If Windows refuses the scan request it says so and shows the cached list instead. -NoRescan skips the fresh scan."
        }
    )
}
