#!/usr/bin/env pwsh
<#
.SYNOPSIS
    End-to-end test of the sidecar's lanes (core/Invoke-DevKitRpc.ps1):
    which ones exist at boot, and that the rest start on their first request.
.DESCRIPTION
    Starts a REAL sidecar process, the way the app's host does, and talks
    NDJSON to it over its pipes. Only read-only methods are called
    (ping, catalog.get, errors.app, wifi.status), then it is shut down.

    Why a real process: the lanes are runspaces created by the script's main
    thread, and "a request queued for a lane that is not running yet is
    answered once the lane is up" is a property of that whole arrangement.
    No function lifted out of the script can show it.
.EXAMPLE
    Invoke-Pester -Path .\tests\Unit\SidecarLanes.Tests.ps1
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    function Start-TestSidecar {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = (Get-Process -Id $PID).Path
        $psi.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script:RepoRoot\core\Invoke-DevKitRpc.ps1`""
        $psi.WorkingDirectory = $script:RepoRoot
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $process = [System.Diagnostics.Process]::Start($psi)
        return @{
            Process = $process
            # Read continuously, so a chatty sidecar can never fill the pipe
            # and stall itself.
            Stderr  = $process.StandardError.ReadToEndAsync()
            NextId  = 0
        }
    }

    function Invoke-TestRpc {
        param([Parameter(Mandatory = $true)]$Sidecar, [Parameter(Mandatory = $true)][string]$Method, [int]$TimeoutMs = 60000)
        $Sidecar.NextId++
        $id = $Sidecar.NextId
        $Sidecar.Process.StandardInput.WriteLine("{`"id`":$id,`"method`":`"$Method`"}")
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        while ([DateTime]::UtcNow -lt $deadline) {
            $read = $Sidecar.Process.StandardOutput.ReadLineAsync()
            if (-not $read.Wait($TimeoutMs)) { return $null }
            if ($null -eq $read.Result) { return $null }
            $message = $read.Result | ConvertFrom-Json
            if ($message.id -eq $id) { return $message }
        }
        return $null
    }

    function Stop-TestSidecar {
        param([Parameter(Mandatory = $true)]$Sidecar)
        try { $null = Invoke-TestRpc -Sidecar $Sidecar -Method 'shutdown' -TimeoutMs 5000 } catch { }
        if (-not $Sidecar.Process.WaitForExit(15000)) { try { $Sidecar.Process.Kill() } catch { } }
        # The diagnostics the sidecar wrote, one line per array element.
        return @($Sidecar.Stderr.Result -split "`r?`n")
    }
}

Describe "the sidecar's lanes" {

    BeforeAll {
        $script:Sidecar = Start-TestSidecar
        $script:Ping = Invoke-TestRpc -Sidecar $script:Sidecar -Method 'ping'
        # 'work' lane: one of the two that exist from boot.
        $script:Catalog = Invoke-TestRpc -Sidecar $script:Sidecar -Method 'catalog.get'
        # 'errors' lane: not running until this request arrives.
        $script:FirstErrors = Invoke-TestRpc -Sidecar $script:Sidecar -Method 'errors.app'
        $script:SecondErrors = Invoke-TestRpc -Sidecar $script:Sidecar -Method 'errors.app'
        # 'network' lane: the WiFi tray's. Reads the adapter list only, so it
        # answers on a machine with no WiFi at all (a build server).
        $script:WifiStatus = Invoke-TestRpc -Sidecar $script:Sidecar -Method 'wifi.status'
        $script:Log = Stop-TestSidecar -Sidecar $script:Sidecar
        $script:ExitCode = $script:Sidecar.Process.ExitCode
    }

    It "answers ping, which needs no lane at all" {
        $script:Ping.ok | Should -BeTrue
        $script:Ping.result | Should -Be 'pong'
    }

    It "starts only the metrics and work lanes at boot" {
        $script:Log | Where-Object { $_ -match 'lanes started \(metrics, work\)' } | Should -Not -BeNullOrEmpty
        $script:Log | Where-Object { $_ -match '\[metrics\] ready after' } | Should -Not -BeNullOrEmpty
        $script:Log | Where-Object { $_ -match '\[work\] ready after' } | Should -Not -BeNullOrEmpty
    }

    It "answers a request for a lane that exists from boot" {
        $script:Catalog.ok | Should -BeTrue
        @($script:Catalog.result.modules).Count | Should -BeGreaterThan 0
    }

    It "starts a lane for its first request, and answers that request" {
        $script:FirstErrors | Should -Not -BeNullOrEmpty -Because 'a request queued before its lane was running must still be answered'
        $script:FirstErrors.ok | Should -BeTrue
        $script:Log | Where-Object { $_ -match "starting lane 'errors' for its first request \(errors\.app\)" } | Should -Not -BeNullOrEmpty
        $script:Log | Where-Object { $_ -match '\[errors\] ready after' } | Should -Not -BeNullOrEmpty
    }

    It "starts that lane once, not once per request" {
        $script:SecondErrors.ok | Should -BeTrue
        @($script:Log | Where-Object { $_ -match "starting lane 'errors'" }).Count | Should -Be 1
    }

    It "starts the network lane for the WiFi tray's first request, loading the WiFi library there" {
        $script:WifiStatus | Should -Not -BeNullOrEmpty
        $script:WifiStatus.ok | Should -BeTrue
        $script:WifiStatus.result.AdapterPresent | Should -BeOfType ([bool])
        $script:WifiStatus.result.PSObject.Properties.Name | Should -Contain 'DnsServers'
        $script:Log | Where-Object { $_ -match "starting lane 'network' for its first request \(wifi\.status\)" } | Should -Not -BeNullOrEmpty
    }

    It "never starts a lane nothing asked for" {
        foreach ($lane in 'slow', 'mcp', 'tool') {
            $script:Log | Where-Object { $_ -match "starting lane '$lane'" } | Should -BeNullOrEmpty
            $script:Log | Where-Object { $_ -match "\[$lane\] ready after" } | Should -BeNullOrEmpty
        }
    }

    It "shuts down cleanly with lanes that were never started" {
        $script:ExitCode | Should -Be 0
        $script:Log | Where-Object { $_ -match 'shutdown complete' } | Should -Not -BeNullOrEmpty
    }
}
