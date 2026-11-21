#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for the polled collectors that read Windows directly
    instead of through WMI (core/DevKit-WidgetCore.ps1).
.DESCRIPTION
    metrics.system, process.topCpu and metrics.node are the three busiest
    polls in the app (every 2-3 seconds). They used to spend about a second
    each inside WMI or a fixed sleep. These tests pin the arithmetic that
    replaced that, the WMI fallback for a host where the native type cannot
    be compiled, and the "no sleep on a steady-state poll" promise.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $global:DevKitCommonLoaded = $false
    . (Join-Path $script:RepoRoot 'tools\lib\DevKit-Common.ps1')
    $global:DevKitWidgetCoreLoaded = $false
    . (Join-Path $script:RepoRoot 'core\DevKit-WidgetCore.ps1')
}

Describe "Get-DevKitCpuPercentFromTimes" {

    It "subtracts idle from kernel + user, because kernel time includes idle time" {
        # 1000 ticks passed on the clock: kernel 800 (of which 750 idle), user 200.
        $percent = Get-DevKitCpuPercentFromTimes -Previous @(0, 0, 0) -Current @(750, 800, 200)
        $percent | Should -Be 25
    }

    It "reads 0 for a fully idle window and 100 for a fully busy one" {
        Get-DevKitCpuPercentFromTimes -Previous @(100, 100, 0) -Current @(600, 600, 0) | Should -Be 0
        Get-DevKitCpuPercentFromTimes -Previous @(100, 100, 0) -Current @(100, 300, 300) | Should -Be 100
    }

    It "answers null when no time passed between the samples" {
        Get-DevKitCpuPercentFromTimes -Previous @(5, 9, 4) -Current @(5, 9, 4) | Should -BeNullOrEmpty
    }

    It "answers null when a counter went backwards" {
        Get-DevKitCpuPercentFromTimes -Previous @(500, 900, 400) -Current @(400, 1000, 500) | Should -BeNullOrEmpty
    }

    It "clamps a reading that rounding pushed outside 0-100" {
        # idle delta larger than the total: would be negative.
        Get-DevKitCpuPercentFromTimes -Previous @(0, 0, 0) -Current @(1200, 800, 200) | Should -Be 0
    }
}

Describe "Get-DevKitNativeCpuPercent and Get-DevKitNativeMemory (live)" {

    It "reads a CPU percentage between 0 and 100 without WMI" {
        Mock Get-CimInstance { throw 'WMI must not be asked' }
        $script:CpuTimesPrevious = $null
        $first = Get-DevKitNativeCpuPercent
        $first | Should -Not -BeNullOrEmpty
        $first | Should -BeGreaterOrEqual 0
        $first | Should -BeLessOrEqual 100
        Should -Invoke Get-CimInstance -Times 0
    }

    It "keeps the older sample when two polls land with no time between them" {
        $script:CpuTimesPrevious = [long[]]@(1, 2, 3)
        Mock Get-DevKitCpuPercentFromTimes { return $null }
        Get-DevKitNativeCpuPercent | Should -BeNullOrEmpty
        $script:CpuTimesPrevious[0] | Should -Be 1
    }

    It "reads physical memory that agrees with what Windows reports" {
        $memory = Get-DevKitNativeMemory
        $memory.TotalBytes | Should -BeGreaterThan 0
        $memory.AvailableBytes | Should -BeGreaterThan 0
        $memory.AvailableBytes | Should -BeLessOrEqual $memory.TotalBytes
        $wmiTotalBytes = [double](Get-CimInstance Win32_OperatingSystem -Property TotalVisibleMemorySize).TotalVisibleMemorySize * 1KB
        # Same figure from two APIs: allow 1% for rounding and reserved pages.
        [math]::Abs($memory.TotalBytes - $wmiTotalBytes) | Should -BeLessThan ($wmiTotalBytes * 0.01)
    }
}

Describe "Get-DevKitSystemMetrics" {

    BeforeEach {
        Mock Get-DevKitGpuReading { return @{ Percent = $null; TempC = $null; Source = 'None' } }
        Mock Get-DevKitCpuTempReading { return $null }
        $script:BootTimeCache = $null
        $script:RebootPendingCache = @{ Value = $false; At = Get-Date }
    }

    It "does not ask WMI for CPU or memory on a normal poll" {
        Mock Get-CimInstance { return [PSCustomObject]@{ LastBootUpTime = (Get-Date).AddDays(-2) } }
        $script:CpuTimesPrevious = $null
        $metrics = Get-DevKitSystemMetrics
        $metrics.CpuPercent | Should -Not -BeNullOrEmpty
        $metrics.MemoryTotalGB | Should -BeGreaterThan 0
        $metrics.MemoryPercent | Should -BeGreaterThan 0
        Should -Invoke Get-CimInstance -Times 0 -ParameterFilter { $ClassName -eq 'Win32_Processor' }
        Should -Invoke Get-CimInstance -Times 0 -ParameterFilter { $Property -contains 'FreePhysicalMemory' }
    }

    It "asks for the boot time once, not on every poll" {
        Mock Get-CimInstance { return [PSCustomObject]@{ LastBootUpTime = (Get-Date).AddDays(-2) } }
        $first = Get-DevKitSystemMetrics
        $second = Get-DevKitSystemMetrics
        $first.UptimeDays | Should -Be 2
        $second.UptimeDays | Should -Be 2
        Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter { $Property -contains 'LastBootUpTime' }
    }

    It "falls back to WMI when the native type cannot be compiled" {
        Mock Initialize-DevKitNativeMetrics { return $false }
        Mock Get-CimInstance { return [PSCustomObject]@{ LoadPercentage = 40 } } -ParameterFilter { $ClassName -eq 'Win32_Processor' }
        Mock Get-CimInstance {
            # 16 GB total, 4 GB free, in the kilobytes WMI reports.
            return [PSCustomObject]@{ TotalVisibleMemorySize = 16MB; FreePhysicalMemory = 4MB; LastBootUpTime = (Get-Date).AddDays(-1) }
        } -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' }
        $metrics = Get-DevKitSystemMetrics
        $metrics.CpuPercent | Should -Be 40
        $metrics.MemoryTotalGB | Should -Be 16
        $metrics.MemoryUsedGB | Should -Be 12
        $metrics.MemoryPercent | Should -Be 75
        $metrics.UptimeDays | Should -Be 1
    }

    It "reports n/a (null), never zero, when neither source answers" {
        Mock Initialize-DevKitNativeMetrics { return $false }
        Mock Get-CimInstance { throw 'WMI is broken' }
        $metrics = Get-DevKitSystemMetrics
        $metrics.CpuPercent | Should -BeNullOrEmpty
        $metrics.MemoryPercent | Should -BeNullOrEmpty
        $metrics.MemoryTotalGB | Should -BeNullOrEmpty
        $metrics.UptimeDays | Should -BeNullOrEmpty
    }
}

Describe "Get-DevKitProcessCpuRows" {

    BeforeAll {
        function New-TestProcess($Id, $Name, $Cpu, $MemoryMB = 10) {
            [PSCustomObject]@{ Id = $Id; Name = $Name; Cpu = $Cpu; MemoryMB = $MemoryMB }
        }
    }

    It "computes percent as CPU seconds used over window x cores" {
        # 2 CPU-seconds in a 2-second window on 4 cores = 25%.
        $rows = Get-DevKitProcessCpuRows -Processes @(New-TestProcess 10 'node' 5.0 300) -Earlier @{ 10 = 3.0 } -WindowSeconds 2 -Cores 4
        $rows.Count | Should -Be 1
        $rows[0].CpuPercent | Should -Be 25
        $rows[0].Pid | Should -Be 10
        $rows[0].Name | Should -Be 'node'
        $rows[0].MemoryMB | Should -Be 300
        $rows[0].Classification | Should -Not -BeNullOrEmpty
    }

    It "skips a process that started after the earlier snapshot" {
        $rows = Get-DevKitProcessCpuRows -Processes @(New-TestProcess 11 'new' 1.0) -Earlier @{ 10 = 3.0 } -WindowSeconds 1 -Cores 1
        $rows.Count | Should -Be 0
    }

    It "skips a recycled PID (CPU total went down)" {
        $rows = Get-DevKitProcessCpuRows -Processes @(New-TestProcess 10 'recycled' 0.5) -Earlier @{ 10 = 30.0 } -WindowSeconds 1 -Cores 1
        $rows.Count | Should -Be 0
    }

    It "skips a process that will not report its CPU time" {
        $rows = Get-DevKitProcessCpuRows -Processes @(New-TestProcess 4 'System' $null) -Earlier @{ 4 = 1.0 } -WindowSeconds 1 -Cores 1
        $rows.Count | Should -Be 0
    }

    It "caps at 100 and returns nothing for a window with no length" {
        $capped = Get-DevKitProcessCpuRows -Processes @(New-TestProcess 10 'busy' 9.0) -Earlier @{ 10 = 1.0 } -WindowSeconds 1 -Cores 1
        $capped[0].CpuPercent | Should -Be 100
        $none = Get-DevKitProcessCpuRows -Processes @(New-TestProcess 10 'busy' 9.0) -Earlier @{ 10 = 1.0 } -WindowSeconds 0 -Cores 1
        $none.Count | Should -Be 0
    }
}

Describe "Get-DevKitTopCpuProcesses" {

    BeforeEach {
        $script:TestCpu = 10.0
        Mock Start-Sleep { }
        Mock Get-DevKitProcessCpuSnapshot {
            $script:TestCpu += 0.5
            $list = @(
                [PSCustomObject]@{ Id = 10; Name = 'node'; Cpu = $script:TestCpu; MemoryMB = 100 }
                [PSCustomObject]@{ Id = 20; Name = 'idle-app'; Cpu = 1.0; MemoryMB = 50 }
            )
            return , $list
        }
    }

    It "samples twice with a pause when it has no earlier snapshot" {
        $script:TopCpuPrevious = $null
        $rows = @(Get-DevKitTopCpuProcesses -Count 5)
        Should -Invoke Start-Sleep -Times 1 -Exactly
        Should -Invoke Get-DevKitProcessCpuSnapshot -Times 2 -Exactly
        $rows.Count | Should -Be 2
        $rows[0].Name | Should -Be 'node'
        $script:TopCpuPrevious | Should -Not -BeNullOrEmpty
    }

    It "reuses the previous poll's snapshot instead of pausing" {
        $twoSecondsAgo = [System.Diagnostics.Stopwatch]::GetTimestamp() - (2 * [System.Diagnostics.Stopwatch]::Frequency)
        $script:TopCpuPrevious = @{ Stamp = $twoSecondsAgo; Cpu = @{ 10 = 10.0; 20 = 1.0 } }
        $rows = @(Get-DevKitTopCpuProcesses -Count 5)
        Should -Invoke Start-Sleep -Times 0
        Should -Invoke Get-DevKitProcessCpuSnapshot -Times 1 -Exactly
        $rows[0].Name | Should -Be 'node'
        $rows[0].CpuPercent | Should -BeGreaterThan 0
    }

    It "does not trust a snapshot older than ten seconds" {
        $longAgo = [System.Diagnostics.Stopwatch]::GetTimestamp() - (60 * [System.Diagnostics.Stopwatch]::Frequency)
        $script:TopCpuPrevious = @{ Stamp = $longAgo; Cpu = @{ 10 = 0.0 } }
        $null = Get-DevKitTopCpuProcesses -Count 5
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }

    It "honors -Count and sorts busiest first" {
        $script:TopCpuPrevious = $null
        $rows = @(Get-DevKitTopCpuProcesses -Count 1)
        $rows.Count | Should -Be 1
        $rows[0].Name | Should -Be 'node'
    }
}

Describe "Get-DevKitTopMemoryProcesses" {

    It "reads the totals without WMI" {
        Mock Get-CimInstance { throw 'WMI must not be asked' }
        $result = Get-DevKitTopMemoryProcesses -Count 3
        $result.TotalGB | Should -BeGreaterThan 0
        $result.UsedGB | Should -BeGreaterThan 0
        [math]::Round($result.UsedGB + $result.FreeGB, 1) | Should -Be $result.TotalGB
        @($result.Processes).Count | Should -Be 3
    }

    It "falls back to WMI when the native type is unavailable" {
        Mock Initialize-DevKitNativeMetrics { return $false }
        Mock Get-CimInstance { return [PSCustomObject]@{ TotalVisibleMemorySize = 8MB; FreePhysicalMemory = 2MB } }
        $result = Get-DevKitTopMemoryProcesses -Count 1
        $result.TotalGB | Should -Be 8
        $result.FreeGB | Should -Be 2
        $result.UsedGB | Should -Be 6
    }
}

Describe "Get-DevKitTcpListenRows" {

    It "reads listening sockets as integer port / pid rows without the WMI cmdlet" {
        Mock Get-NetTCPConnection { throw 'the WMI cmdlet must not be asked' }
        $rows = Get-DevKitTcpListenRows
        # Every Windows machine listens on something (RPC on 135 at the least).
        $rows.Count | Should -BeGreaterThan 0
        foreach ($row in $rows) {
            $row.LocalPort | Should -BeOfType [int]
            $row.OwningProcess | Should -BeOfType [int]
            $row.LocalPort | Should -BeGreaterThan 0
            $row.LocalPort | Should -BeLessOrEqual 65535
        }
        Should -Invoke Get-NetTCPConnection -Times 0
    }

    It "names a port this test opened, under this process's PID" {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
            $rows = Get-DevKitTcpListenRows
            $mine = @($rows | Where-Object { $_.LocalPort -eq $port })
            $mine.Count | Should -Be 1
            $mine[0].OwningProcess | Should -Be $PID
            # And the grouping the widget does on top of these rows finds it.
            (Group-DevKitPortsByProcess -ListenRows $rows)[[int]$PID] | Should -Contain $port
        } finally {
            $listener.Stop()
        }
    }

    It "falls back to Get-NetTCPConnection, keeping a single row an array" {
        Mock Initialize-DevKitNativeMetrics { return $false }
        Mock Get-NetTCPConnection { return [PSCustomObject]@{ LocalPort = 5173; OwningProcess = [uint32]77 } }
        $rows = Get-DevKitTcpListenRows
        $rows.Count | Should -Be 1
        $rows[0].LocalPort | Should -Be 5173
    }
}
