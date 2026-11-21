#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for ConvertTo-DevKitMcpEntryMap (lib/DevKit-McpList.ps1)
.DESCRIPTION
    Exercises the 'claude mcp list' plain-text parser in isolation against
    fixture text - no real 'claude' process is invoked. Covers the exact bug
    fixed this sprint (a server name containing a space, e.g. a real
    connector named 'claude.ai Notion', being silently dropped by an
    over-restrictive regex) plus header/blank/non-matching line handling and
    insertion order.

    Dot-sourcing lib/DevKit-McpList.ps1 here is safe: it only defines
    Invoke-DevKitMcpList, ConvertTo-DevKitMcpEntryMap, and
    Get-DevKitMcpScopeDiff, guarded by its own $global:DevKitMcpListLoaded
    "load once per process" flag. It never calls 'claude' or prompts at
    dot-source time - only Invoke-DevKitMcpList/Get-DevKitMcpScopeDiff do
    that, and this file never calls those.
.NOTES
    Pester 5 syntax (dashed `Should -Be`).
    Run with:
        Invoke-Pester -Path .\tests\Unit\McpEntryMap-Parser.Tests.ps1
#>

BeforeAll {
    $script:McpListScript = (Resolve-Path (Join-Path $PSScriptRoot "..\..\tools\lib\DevKit-McpList.ps1")).Path

    # lib/*.ps1 files guard themselves with a $global:...Loaded "load once
    # per process" flag. That's correct for the real app, but when Pester
    # runs multiple test files in one process, an earlier file can set the
    # flag first, silently no-op'ing this dot-source and leaving
    # ConvertTo-DevKitMcpEntryMap undefined in THIS file's scope. Reset the
    # flag so this file always gets a real, fresh load regardless of run
    # order (same pattern as Get-DevKitPackageManager.Tests.ps1).
    $global:DevKitMcpListLoaded = $false
    . $script:McpListScript

    # Realistic sample matching real `claude mcp list` output: a health-check
    # header line, a blank line, several normal 'name: line' entries, and a
    # server name containing a space (the connector-style name this sprint's
    # regex fix specifically targets).
    $script:SampleListOutput = @(
        "Checking MCP server health...",
        "",
        "github: https://api.githubcopilot.com/mcp (HTTP) - Connected",
        "supabase: npx -y @supabase/mcp-server-supabase@latest - Connected",
        "claude.ai Notion: https://mcp.notion.com/mcp - Connected",
        "sequential-thinking: npx -y @modelcontextprotocol/server-sequential-thinking - Connected"
    )
}

Describe "ConvertTo-DevKitMcpEntryMap" {

    It "parses every well-formed 'name: line' entry from realistic multi-line output" {
        $map = ConvertTo-DevKitMcpEntryMap -Output $script:SampleListOutput
        $map.Keys | Should -Contain "github"
        $map.Keys | Should -Contain "supabase"
        $map.Keys | Should -Contain "claude.ai Notion"
        $map.Keys | Should -Contain "sequential-thinking"
    }

    It "returns exactly 4 entries for the 6-line sample (2 non-matching lines ignored)" {
        $map = ConvertTo-DevKitMcpEntryMap -Output $script:SampleListOutput
        $map.Count | Should -Be 4
    }

    It "regression: parses a server name containing a space instead of dropping it (the connector-name bug fixed this sprint)" {
        $map = ConvertTo-DevKitMcpEntryMap -Output $script:SampleListOutput
        $map.Keys | Should -Contain "claude.ai Notion"
        $map["claude.ai Notion"] | Should -Be "claude.ai Notion: https://mcp.notion.com/mcp - Connected"
    }

    It "ignores the non-colon header line ('Checking MCP server health...')" {
        $map = ConvertTo-DevKitMcpEntryMap -Output $script:SampleListOutput
        $map.Keys | Should -Not -Contain "Checking MCP server health..."
    }

    It "ignores blank lines without throwing" {
        { ConvertTo-DevKitMcpEntryMap -Output $script:SampleListOutput } | Should -Not -Throw
    }

    It "splits on the first ': ' rather than a restricted character class (period in the name is preserved)" {
        $map = ConvertTo-DevKitMcpEntryMap -Output $script:SampleListOutput
        $map.Keys | Should -Contain "sequential-thinking"
        $map["sequential-thinking"] | Should -Match "^sequential-thinking: "
    }

    It "preserves insertion order matching the input order" {
        $map = ConvertTo-DevKitMcpEntryMap -Output $script:SampleListOutput
        $keys = @($map.Keys)
        $keys[0] | Should -Be "github"
        $keys[1] | Should -Be "supabase"
        $keys[2] | Should -Be "claude.ai Notion"
        $keys[3] | Should -Be "sequential-thinking"
    }

    It "returns an empty (not null) map for empty input" {
        $map = ConvertTo-DevKitMcpEntryMap -Output @()
        $map.Count | Should -Be 0
    }

    It "does not match a line with a colon but no following space (e.g. a URL-like fragment)" {
        $map = ConvertTo-DevKitMcpEntryMap -Output @("https://example.com/no-space-after-colon")
        $map.Count | Should -Be 0
    }

    It "trims trailing whitespace from the stored line" {
        $map = ConvertTo-DevKitMcpEntryMap -Output @("github: https://api.githubcopilot.com/mcp - Connected   ")
        $map["github"] | Should -Be "github: https://api.githubcopilot.com/mcp - Connected"
    }
}

Describe "Get-DevKitMcpScopeDiff reuses the neutral-directory listing" {

    # Every 'claude mcp list' makes Claude Code connect to every configured
    # server, which starts each stdio server as a real process. The scope
    # diff used to do that twice per call. The neutral listing only answers
    # WHICH servers are user scope, so it can be kept; the statuses always
    # come from the project listing, which is fresh every time.

    BeforeEach {
        $script:DevKitMcpNeutralCache = $null
        $script:ListCalls = [System.Collections.Generic.List[string]]::new()
        $script:NeutralLines = @('github: https://api.githubcopilot.com/mcp (HTTP) - Connected')
        $script:ProjectLines = @(
            'github: https://api.githubcopilot.com/mcp (HTTP) - Connected',
            'supabase: npx -y @supabase/mcp-server-supabase - Connected'
        )
        $script:NeutralSucceeds = $true
        Mock Invoke-DevKitMcpList {
            $script:ListCalls.Add($Path)
            if ($Path -eq $env:TEMP) {
                if (-not $script:NeutralSucceeds) {
                    return [PSCustomObject]@{ Success = $false; ExitCode = $null; ErrorMessage = 'timed out'; Output = @() }
                }
                return [PSCustomObject]@{ Success = $true; ExitCode = 0; ErrorMessage = $null; Output = $script:NeutralLines }
            }
            return [PSCustomObject]@{ Success = $true; ExitCode = 0; ErrorMessage = $null; Output = $script:ProjectLines }
        }
    }

    It "takes both listings every time when reuse is off, neutral first (the default)" {
        $null = Get-DevKitMcpScopeDiff -ProjectPath 'C:\proj'
        $null = Get-DevKitMcpScopeDiff -ProjectPath 'C:\proj'
        $script:ListCalls.Count | Should -Be 4
        $script:ListCalls[0] | Should -Be $env:TEMP
        $script:ListCalls[1] | Should -Be 'C:\proj'
    }

    It "takes the neutral listing once and the project listing every time when reuse is on" {
        $first = Get-DevKitMcpScopeDiff -ProjectPath 'C:\proj' -NeutralMaxAgeSeconds 600
        $second = Get-DevKitMcpScopeDiff -ProjectPath 'C:\proj' -NeutralMaxAgeSeconds 600
        $third = Get-DevKitMcpScopeDiff -ProjectPath 'C:\proj' -NeutralMaxAgeSeconds 600
        @($script:ListCalls | Where-Object { $_ -eq $env:TEMP }).Count | Should -Be 1
        @($script:ListCalls | Where-Object { $_ -eq 'C:\proj' }).Count | Should -Be 3
        foreach ($diff in $first, $second, $third) {
            $diff.Success | Should -BeTrue
            @($diff.UserScope.Keys) | Should -Be @('github')
            @($diff.ProjectScope.Keys) | Should -Be @('supabase')
        }
    }

    It "reports a status change at once: statuses come from the fresh project listing" {
        $null = Get-DevKitMcpScopeDiff -ProjectPath 'C:\proj' -NeutralMaxAgeSeconds 600
        $script:ProjectLines = @(
            'github: https://api.githubcopilot.com/mcp (HTTP) - Failed to connect',
            'supabase: npx -y @supabase/mcp-server-supabase - Connected'
        )
        $diff = Get-DevKitMcpScopeDiff -ProjectPath 'C:\proj' -NeutralMaxAgeSeconds 600
        $diff.UserScope['github'] | Should -Match 'Failed to connect'
        @($script:ListCalls | Where-Object { $_ -eq $env:TEMP }).Count | Should -Be 1
    }

    It "takes a new neutral listing when the project's server names change" {
        # A server was added. Whether it is user scope or project scope is
        # exactly what the kept listing cannot say.
        $null = Get-DevKitMcpScopeDiff -ProjectPath 'C:\proj' -NeutralMaxAgeSeconds 600
        $script:NeutralLines += 'notion: https://mcp.notion.com/mcp - Connected'
        $script:ProjectLines += 'notion: https://mcp.notion.com/mcp - Connected'
        $diff = Get-DevKitMcpScopeDiff -ProjectPath 'C:\proj' -NeutralMaxAgeSeconds 600
        @($script:ListCalls | Where-Object { $_ -eq $env:TEMP }).Count | Should -Be 2
        @($diff.UserScope.Keys) | Should -Contain 'notion'
        @($diff.ProjectScope.Keys) | Should -Not -Contain 'notion'
    }

    It "reuses the neutral listing for a second project (it does not depend on the project)" {
        $null = Get-DevKitMcpScopeDiff -ProjectPath 'C:\proj' -NeutralMaxAgeSeconds 600
        $null = Get-DevKitMcpScopeDiff -ProjectPath 'C:\other' -NeutralMaxAgeSeconds 600
        @($script:ListCalls | Where-Object { $_ -eq $env:TEMP }).Count | Should -Be 1
    }

    It "takes a new neutral listing once the kept one is too old" {
        $null = Get-DevKitMcpScopeDiff -ProjectPath 'C:\proj' -NeutralMaxAgeSeconds 600
        $script:DevKitMcpNeutralCache.At = (Get-Date).AddSeconds(-601)
        $null = Get-DevKitMcpScopeDiff -ProjectPath 'C:\proj' -NeutralMaxAgeSeconds 600
        @($script:ListCalls | Where-Object { $_ -eq $env:TEMP }).Count | Should -Be 2
    }

    It "does not keep a failed neutral listing, and says which listing failed" {
        $script:NeutralSucceeds = $false
        $diff = Get-DevKitMcpScopeDiff -ProjectPath 'C:\proj' -NeutralMaxAgeSeconds 600
        $diff.Success | Should -BeFalse
        $diff.ErrorMessage | Should -Match '^Neutral-directory listing failed'
        $script:DevKitMcpNeutralCache | Should -BeNullOrEmpty

        $script:NeutralSucceeds = $true
        $again = Get-DevKitMcpScopeDiff -ProjectPath 'C:\proj' -NeutralMaxAgeSeconds 600
        $again.Success | Should -BeTrue
        @($script:ListCalls | Where-Object { $_ -eq $env:TEMP }).Count | Should -Be 2
    }

    It "stops at a failed project listing without taking a neutral one" {
        Mock Invoke-DevKitMcpList {
            $script:ListCalls.Add($Path)
            return [PSCustomObject]@{ Success = $false; ExitCode = 1; ErrorMessage = 'exited with code 1'; Output = @() }
        }
        $diff = Get-DevKitMcpScopeDiff -ProjectPath 'C:\proj' -NeutralMaxAgeSeconds 600
        $diff.Success | Should -BeFalse
        $diff.ErrorMessage | Should -Match '^Project-directory listing failed'
        $script:ListCalls.Count | Should -Be 1
    }
}

Describe "Test-DevKitMcpNeutralListingReusable" {

    BeforeAll {
        $script:Now = [datetime]'2026-11-21T12:00:00'
        $script:Kept = @{ At = $script:Now.AddSeconds(-100); Result = $null; ProjectNames = @{ 'c:\proj' = "github`nsupabase" } }
    }

    It "is false when nothing is kept or reuse is off" {
        Test-DevKitMcpNeutralListingReusable -Cache $null -Now $script:Now -MaxAgeSeconds 600 -ProjectPath 'C:\proj' -ProjectNames 'x' | Should -BeFalse
        Test-DevKitMcpNeutralListingReusable -Cache $script:Kept -Now $script:Now -MaxAgeSeconds 0 -ProjectPath 'C:\proj' -ProjectNames "github`nsupabase" | Should -BeFalse
    }

    It "is true for the same project showing the same names, whatever the path's case" {
        Test-DevKitMcpNeutralListingReusable -Cache $script:Kept -Now $script:Now -MaxAgeSeconds 600 -ProjectPath 'C:\PROJ' -ProjectNames "github`nsupabase" | Should -BeTrue
    }

    It "is false exactly at the age limit and beyond, and for a clock that went backwards" {
        Test-DevKitMcpNeutralListingReusable -Cache $script:Kept -Now $script:Now -MaxAgeSeconds 100 -ProjectPath 'C:\proj' -ProjectNames "github`nsupabase" | Should -BeFalse
        Test-DevKitMcpNeutralListingReusable -Cache $script:Kept -Now $script:Now -MaxAgeSeconds 101 -ProjectPath 'C:\proj' -ProjectNames "github`nsupabase" | Should -BeTrue
        Test-DevKitMcpNeutralListingReusable -Cache $script:Kept -Now $script:Now.AddSeconds(-500) -MaxAgeSeconds 600 -ProjectPath 'C:\proj' -ProjectNames "github`nsupabase" | Should -BeFalse
    }

    It "is false when the project's names differ, including by case" {
        Test-DevKitMcpNeutralListingReusable -Cache $script:Kept -Now $script:Now -MaxAgeSeconds 600 -ProjectPath 'C:\proj' -ProjectNames "github`nnotion`nsupabase" | Should -BeFalse
        Test-DevKitMcpNeutralListingReusable -Cache $script:Kept -Now $script:Now -MaxAgeSeconds 600 -ProjectPath 'C:\proj' -ProjectNames "GitHub`nsupabase" | Should -BeFalse
    }

    It "is true for a project not seen before: only age decides" {
        Test-DevKitMcpNeutralListingReusable -Cache $script:Kept -Now $script:Now -MaxAgeSeconds 600 -ProjectPath 'C:\other' -ProjectNames 'anything' | Should -BeTrue
    }
}
