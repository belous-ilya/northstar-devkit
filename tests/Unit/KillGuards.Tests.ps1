#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for the shared "may this process be stopped?" guards in
    tools/lib/DevKit-Common.ps1 and for the port tools that must use them.
.DESCRIPTION
    DevKit always runs elevated, so its kill tools can stop ANYTHING -
    including the svchost that hosts the RPC endpoint mapper on port 135,
    whose death makes Windows force a shutdown. Kill-Port, Kill-AllNode and
    Scan-Ports -Kill used to guard only pids 0 and 4 and the script's own
    pid; these tests hold them to the same refusal rules Close-OutSession
    already had.

    NOTHING HERE STOPS A PROCESS. The predicates are pure, the port lookup
    is tested against a mocked Get-NetTCPConnection, and the three tool
    scripts are checked by parsing them, never by running them.
.NOTES
    Pester 5 syntax (dashed `Should -Be`).
    Run with:
        Invoke-Pester -Path .\tests\Unit\KillGuards.Tests.ps1
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    # See Get-DevKitPackageManager.Tests.ps1 for why this load-once flag gets
    # reset when several test files share one Pester process.
    $global:DevKitCommonLoaded = $false
    . (Join-Path $script:RepoRoot 'tools\lib\DevKit-Common.ps1')

    $script:SampleProcesses = @(
        [PSCustomObject]@{ ProcessId = 4200; ParentProcessId = 3100 }
        [PSCustomObject]@{ ProcessId = 3100; ParentProcessId = 2200 }
        [PSCustomObject]@{ ProcessId = 2200; ParentProcessId = 1100 }
        [PSCustomObject]@{ ProcessId = 1100; ParentProcessId = 0 }
        [PSCustomObject]@{ ProcessId = 9999; ParentProcessId = 1100 }
    )
}

Describe "Get-DevKitProcessAncestry" {

    It "returns self first, then each ancestor nearest first" {
        $chain = Get-DevKitProcessAncestry -ProcessId 4200 -Processes $script:SampleProcesses
        $chain | Should -Be @(4200, 3100, 2200, 1100)
    }

    It "does not include siblings or unrelated processes" {
        $chain = Get-DevKitProcessAncestry -ProcessId 4200 -Processes $script:SampleProcesses
        $chain | Should -Not -Contain 9999
    }

    It "returns just the pid itself for an empty table" {
        $chain = Get-DevKitProcessAncestry -ProcessId 4200 -Processes @()
        @($chain).Count | Should -Be 1
        @($chain)[0] | Should -Be 4200
    }

    It "terminates on a pid-reuse cycle" {
        $cyclic = @(
            [PSCustomObject]@{ ProcessId = 10; ParentProcessId = 20 }
            [PSCustomObject]@{ ProcessId = 20; ParentProcessId = 10 }
        )
        $chain = Get-DevKitProcessAncestry -ProcessId 10 -Processes $cyclic
        $chain | Should -Be @(10, 20)
    }
}

Describe "Get-DevKitKillRefusalReason" {

    It "allows an ordinary process" {
        Get-DevKitKillRefusalReason -ProcessId 5555 -Name 'node' | Should -BeNullOrEmpty
        Get-DevKitKillRefusalReason -ProcessId 5555 -Name 'sqlservr' | Should -BeNullOrEmpty
    }

    It "refuses the reserved pids" {
        Get-DevKitKillRefusalReason -ProcessId 0 -Name 'Idle' | Should -Match 'reserved system process'
        Get-DevKitKillRefusalReason -ProcessId 4 -Name 'System' | Should -Match 'reserved system process'
        Get-DevKitKillRefusalReason -ProcessId -1 -Name 'node' | Should -Match 'reserved system process'
    }

    It "refuses DevKit's own process tree" {
        Get-DevKitKillRefusalReason -ProcessId 2200 -Name 'node' -ProtectedPids @(4200, 3100, 2200) |
            Should -Match "DevKit's own process tree"
    }

    It "refuses the processes Windows dies without - <name>" -ForEach @(
        @{ name = 'svchost' }, @{ name = 'csrss' }, @{ name = 'wininit' }, @{ name = 'services' },
        @{ name = 'lsass' }, @{ name = 'winlogon' }, @{ name = 'smss' }, @{ name = 'dwm' }
    ) {
        Get-DevKitKillRefusalReason -ProcessId 800 -Name $name | Should -Match 'protected system process'
    }

    It "matches names case-insensitively and with a .exe suffix" {
        Get-DevKitKillRefusalReason -ProcessId 800 -Name 'SvcHost.EXE' | Should -Match 'protected system process'
    }

    It "treats an unknown name as stoppable (the caller named the target itself)" {
        Get-DevKitKillRefusalReason -ProcessId 5555 -Name '' | Should -BeNullOrEmpty
    }
}

Describe "Get-DevKitProcessByPort" {

    It "reports nothing when only closed-connection leftovers remain on the port" {
        # For about two minutes after a dev server stops, TIME_WAIT rows with
        # OwningProcess 0 linger. Falling back to them made every port tool
        # announce "PID 0 (Idle)" as the owner of a port nothing listens on.
        Mock Get-NetTCPConnection {
            @(
                [PSCustomObject]@{ LocalPort = 3000; State = 'TimeWait'; OwningProcess = 0 }
                [PSCustomObject]@{ LocalPort = 3000; State = 'TimeWait'; OwningProcess = 0 }
            )
        }
        Get-DevKitProcessByPort -Port 3000 | Should -BeNullOrEmpty
    }

    It "reports the listener even when a leftover row sorts ahead of it" {
        Mock Get-NetTCPConnection {
            @(
                [PSCustomObject]@{ LocalPort = 3000; State = 'TimeWait'; OwningProcess = 0 }
                [PSCustomObject]@{ LocalPort = 3000; State = 'Listen'; OwningProcess = $PID }
            )
        }
        $owner = Get-DevKitProcessByPort -Port 3000
        $owner.PID | Should -Be $PID
        $owner.Port | Should -Be 3000
    }

    It "reports nothing for a port with no connections at all" {
        Mock Get-NetTCPConnection { @() }
        Get-DevKitProcessByPort -Port 3000 | Should -BeNullOrEmpty
    }
}

Describe "the port tools use the guards" {

    BeforeDiscovery {
        $script:KillTools = @(
            @{ tool = 'Kill-Port.ps1' }
            @{ tool = 'Kill-AllNode.ps1' }
            @{ tool = 'Scan-Ports.ps1' }
        )
    }

    BeforeAll {
        function Get-ToolAst {
            param([string]$Tool)
            $path = Join-Path (Join-Path $script:RepoRoot 'tools\ports') $Tool
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0
            return $ast
        }

        function Get-ToolCommands {
            param($Ast, [string]$Name)
            return @($Ast.FindAll({
                        param($n)
                        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Name
                    }, $true))
        }
    }

    It "<tool> asks Get-DevKitKillRefusalReason before it stops anything" -ForEach $script:KillTools {
        $ast = Get-ToolAst -Tool $tool
        @(Get-ToolCommands -Ast $ast -Name 'Get-DevKitKillRefusalReason').Count | Should -BeGreaterThan 0
    }

    It "<tool> never calls Stop-Process without -ErrorAction Stop" -ForEach $script:KillTools {
        # Stop-Process failures are non-terminating by default, so a try/catch
        # around a bare call never fires: an access-denied kill printed
        # "DONE: Process killed." and exited 0.
        $ast = Get-ToolAst -Tool $tool
        $stops = @(Get-ToolCommands -Ast $ast -Name 'Stop-Process')
        $stops.Count | Should -BeGreaterThan 0
        foreach ($stop in $stops) {
            $stop.Extent.Text | Should -Match '-ErrorAction\s+Stop'
        }
    }
}

Describe "the guard comes before the kill" {

    It "<tool> asks for a refusal reason earlier in the file than its first Stop-Process" -ForEach @(
        @{ tool = 'Kill-Port.ps1' }
        @{ tool = 'Kill-AllNode.ps1' }
        @{ tool = 'Scan-Ports.ps1' }
    ) {
        # Presence alone would be satisfied by a guard placed after the kill.
        $path = Join-Path (Join-Path $script:RepoRoot 'tools\ports') $tool
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $commands = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
        $firstGuard = @($commands | Where-Object { $_.GetCommandName() -eq 'Get-DevKitKillRefusalReason' } | ForEach-Object { $_.Extent.StartOffset } | Sort-Object)[0]
        $firstKill = @($commands | Where-Object { $_.GetCommandName() -eq 'Stop-Process' } | ForEach-Object { $_.Extent.StartOffset } | Sort-Object)[0]
        $firstGuard | Should -BeLessThan $firstKill
    }
}

Describe "the widget's kill button (Stop-DevKitProcessById)" {

    BeforeAll {
        . (Join-Path $script:RepoRoot 'core\DevKit-WidgetCore.ps1')
    }

    It "refuses to stop DevKit's own process tree, and never reaches Stop-Process" {
        # Inside the app this code runs in the sidecar, so "own tree" is the
        # sidecar and the app above it - the rows a user is most likely to
        # mis-click in the Top Memory list. Stop-Process is mocked so that a
        # broken guard fails the assertion instead of killing the test run.
        Mock Stop-Process { }
        $result = Stop-DevKitProcessById -ProcessId $PID
        $result.Stopped | Should -BeFalse
        $result.Note | Should -Match "DevKit's own process tree"
        Should -Invoke Stop-Process -Times 0 -Exactly
    }

    It "still stops an ordinary process" {
        Mock Stop-Process { }
        Mock Get-DevKitOwnProcessTreeIds { , @(1) }
        $result = Stop-DevKitProcessById -ProcessId $PID
        $result.Stopped | Should -BeTrue
        Should -Invoke Stop-Process -Times 1 -Exactly
    }
}
