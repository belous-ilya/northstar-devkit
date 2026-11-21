#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for the companion widget's pure logic (core/DevKit-WidgetCore.ps1)
.DESCRIPTION
    Covers the nvidia-smi output parser, the 'claude mcp list' line parser
    (which drives the Connected/Disconnected/Requires Auth badges), the Kimi
    Code mcp.json config mapper (Configured/Disabled/RequiresAuth per the
    documented schema), and the port-by-process grouping used by the node
    snapshot.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    # See Get-DevKitPackageManager.Tests.ps1 for why these load-once flags
    # get reset when several test files share one Pester process.
    $global:DevKitCommonLoaded = $false
    . (Join-Path $script:RepoRoot 'tools\lib\DevKit-Common.ps1')
    $global:DevKitWidgetCoreLoaded = $false
    . (Join-Path $script:RepoRoot 'core\DevKit-WidgetCore.ps1')
}

Describe "ConvertFrom-DevKitNvidiaSmiOutput" {

    It "parses 'temp, util' output" {
        $r = ConvertFrom-DevKitNvidiaSmiOutput -Output '44, 0'
        $r.TempC | Should -Be 44
        $r.Percent | Should -Be 0
    }

    It "tolerates extra whitespace and trailing lines" {
        $r = ConvertFrom-DevKitNvidiaSmiOutput -Output "  53 ,  12 `nignored"
        $r.TempC | Should -Be 53
        $r.Percent | Should -Be 12
    }

    It "returns $null for unparsable output" {
        ConvertFrom-DevKitNvidiaSmiOutput -Output '' | Should -BeNullOrEmpty
        ConvertFrom-DevKitNvidiaSmiOutput -Output 'N/A' | Should -BeNullOrEmpty
    }
}

Describe "ConvertFrom-DevKitClaudeMcpLine" {

    It "parses a connected stdio server" {
        $r = ConvertFrom-DevKitClaudeMcpLine -Line "sequential-thinking: cmd /c npx -y @modelcontextprotocol/server-sequential-thinking - $([char]0x2714) Connected"
        $r.Name | Should -Be 'sequential-thinking'
        $r.Status | Should -Be 'Connected'
        $r.Target | Should -Be 'cmd /c npx -y @modelcontextprotocol/server-sequential-thinking'
    }

    It "parses a connected remote server whose name contains spaces and periods" {
        $r = ConvertFrom-DevKitClaudeMcpLine -Line "claude.ai Stripe: https://mcp.stripe.com - $([char]0x2714) Connected"
        $r.Name | Should -Be 'claude.ai Stripe'
        $r.Status | Should -Be 'Connected'
        $r.Target | Should -Be 'https://mcp.stripe.com'
    }

    It "maps failures to Disconnected" {
        $r = ConvertFrom-DevKitClaudeMcpLine -Line "broken-server: https://example.com/mcp - $([char]0x2717) Failed to connect"
        $r.Status | Should -Be 'Disconnected'
    }

    It "maps 'Disconnected' wording to Disconnected, not Connected" {
        # Regression: a bare '(?i)connected' matches the substring inside
        # 'Disconnected' - the widget badged a dead server green.
        $r = ConvertFrom-DevKitClaudeMcpLine -Line "gone-server: https://example.com/mcp - $([char]0x2717) Disconnected"
        $r.Status | Should -Be 'Disconnected'
    }

    It "maps 'Not connected' wording to Disconnected, not Connected" {
        $r = ConvertFrom-DevKitClaudeMcpLine -Line "idle-server: npx -y @modelcontextprotocol/server-filesystem - $([char]0x2717) Not connected"
        $r.Status | Should -Be 'Disconnected'
    }

    It "classifies the STATUS portion only - a target containing 'error' with a healthy status stays Connected" {
        # Regression on the reorder fix: matching the failure words against
        # the whole rest-of-line badged servers dead just because their
        # command/URL contains 'error' (e.g. an error-tracker service).
        $r = ConvertFrom-DevKitClaudeMcpLine -Line "error-tracker: cmd /c npx -y @someorg/mcp-error-tracker - $([char]0x2714) Connected"
        $r.Name | Should -Be 'error-tracker'
        $r.Status | Should -Be 'Connected'
        $r.Target | Should -Be 'cmd /c npx -y @someorg/mcp-error-tracker'
    }

    It "maps auth-needed to RequiresAuth" {
        $r = ConvertFrom-DevKitClaudeMcpLine -Line "private-api: https://example.com/mcp - Needs authentication"
        $r.Status | Should -Be 'RequiresAuth'
    }

    It "returns $null for header/blank lines" {
        ConvertFrom-DevKitClaudeMcpLine -Line '' | Should -BeNullOrEmpty
        ConvertFrom-DevKitClaudeMcpLine -Line 'Checking MCP server health...' | Should -BeNullOrEmpty
    }
}

Describe "ConvertFrom-DevKitKimiMcpConfig" {

    BeforeAll {
        $script:doc = [PSCustomObject]@{
            filesystem = [PSCustomObject]@{ command = 'npx'; args = @('-y', '@modelcontextprotocol/server-filesystem') }
            linear     = [PSCustomObject]@{ url = 'https://mcp.linear.app/mcp' }
            legacy     = [PSCustomObject]@{ transport = 'sse'; url = 'https://mcp.example.com/sse' }
            switchedOff = [PSCustomObject]@{ command = 'npx'; enabled = $false }
            needsToken = [PSCustomObject]@{ url = 'https://mcp.example.com/api'; bearerTokenEnvVar = 'DEVKIT_TEST_TOKEN_9F8E7D' }
        }
    }

    It "detects transport per documented field rules" {
        $rows = @(ConvertFrom-DevKitKimiMcpConfig -McpServers $script:doc -Scope 'User')
        ($rows | Where-Object Name -eq 'filesystem').Transport | Should -Be 'stdio'
        ($rows | Where-Object Name -eq 'linear').Transport | Should -Be 'http'
        ($rows | Where-Object Name -eq 'legacy').Transport | Should -Be 'sse'
    }

    It "marks enabled=false as Disabled" {
        $rows = @(ConvertFrom-DevKitKimiMcpConfig -McpServers $script:doc -Scope 'User')
        ($rows | Where-Object Name -eq 'switchedOff').Status | Should -Be 'Disabled'
    }

    It "marks a missing bearer-token env var as RequiresAuth, present as Configured" {
        [Environment]::SetEnvironmentVariable('DEVKIT_TEST_TOKEN_9F8E7D', $null)
        $rows = @(ConvertFrom-DevKitKimiMcpConfig -McpServers $script:doc -Scope 'User')
        ($rows | Where-Object Name -eq 'needsToken').Status | Should -Be 'RequiresAuth'

        [Environment]::SetEnvironmentVariable('DEVKIT_TEST_TOKEN_9F8E7D', 'x')
        try {
            $rows = @(ConvertFrom-DevKitKimiMcpConfig -McpServers $script:doc -Scope 'User')
            ($rows | Where-Object Name -eq 'needsToken').Status | Should -Be 'Configured'
        } finally {
            [Environment]::SetEnvironmentVariable('DEVKIT_TEST_TOKEN_9F8E7D', $null)
        }
    }

    It "returns no rows for a missing/empty mcpServers object" {
        @(ConvertFrom-DevKitKimiMcpConfig -McpServers $null -Scope 'User').Count | Should -Be 0
    }

    It "badges via the helper so a User-scope token set after the sidecar started counts" {
        # Regression: the env var was read process-scope only, so a token set
        # while the long-lived sidecar was already running read as missing
        # and a configured server showed "Requires Auth". The Mock stands in
        # for the helper's Process->User fallback (the real User scope would
        # mean writing the registry inside a test).
        Mock Get-DevKitKimiBearerToken { return $null }
        $rows = @(ConvertFrom-DevKitKimiMcpConfig -McpServers $script:doc -Scope 'User')
        ($rows | Where-Object Name -eq 'needsToken').Status | Should -Be 'RequiresAuth'

        Mock Get-DevKitKimiBearerToken { return 'tok' }
        $rows = @(ConvertFrom-DevKitKimiMcpConfig -McpServers $script:doc -Scope 'User')
        ($rows | Where-Object Name -eq 'needsToken').Status | Should -Be 'Configured'
    }
}

Describe "Get-DevKitKimiBearerToken" {

    It "returns the process-scope value when set" {
        $name = 'DEVKIT_TEST_TOKEN_PROC_9F8E7D'
        [Environment]::SetEnvironmentVariable($name, 'proc-tok')   # 2-arg = Process scope
        try {
            Get-DevKitKimiBearerToken -Name $name | Should -Be 'proc-tok'
        } finally {
            [Environment]::SetEnvironmentVariable($name, $null)
        }
    }

    It "returns empty for a variable set in neither scope" {
        Get-DevKitKimiBearerToken -Name 'DEVKIT_TEST_TOKEN_ABSENT_9F8E7D' | Should -BeNullOrEmpty
    }
}

Describe "Group-DevKitPortsByProcess" {

    It "groups, de-duplicates, and sorts ports per process" {
        $rows = @(
            [PSCustomObject]@{ OwningProcess = 100; LocalPort = 5173 }
            [PSCustomObject]@{ OwningProcess = 100; LocalPort = 3000 }
            [PSCustomObject]@{ OwningProcess = 100; LocalPort = 3000 }
            [PSCustomObject]@{ OwningProcess = 200; LocalPort = 8080 }
        )
        $map = Group-DevKitPortsByProcess -ListenRows $rows
        $map[100] | Should -Be @(3000, 5173)
        $map[200] | Should -Be @(8080)
    }

    It "keys by [int] so a UInt32 OwningProcess (Get-NetTCPConnection's real type) is still found by an Int32 PID (Get-Process's real type)" {
        $rows = @(
            [PSCustomObject]@{ OwningProcess = [uint32]4242; LocalPort = 5173 }
        )
        $map = Group-DevKitPortsByProcess -ListenRows $rows
        $map.ContainsKey([int]4242) | Should -BeTrue
        $map[[int]4242] | Should -Be @(5173)
    }
}

Describe "Get-DevKitKimiMcpStatus (project scope file handling)" {

    It "reads <project>/.kimi-code/mcp.json and lets project entries override user entries" {
        $projectDir = Join-Path $env:TEMP "devkit_kimi_status_test_$(Get-Random)"
        New-Item -ItemType Directory -Path $projectDir -Force | Out-Null
        try {
            Mock Get-DevKitWindowsExecutable { return @{ Source = 'C:\fake\kimi.exe' } }
            Mock Read-DevKitKimiMcpFile {
                param($Path)
                if ($Path -like "$projectDir*") {
                    # project-level file
                    return [PSCustomObject]@{ shared = [PSCustomObject]@{ url = 'https://project.example.com/mcp' } }
                }
                # user-level file
                return [PSCustomObject]@{
                    shared = [PSCustomObject]@{ url = 'https://user.example.com/mcp' }
                    userOnly = [PSCustomObject]@{ command = 'npx' }
                }
            }

            $status = Get-DevKitKimiMcpStatus -ProjectPath $projectDir
            $status.CliInstalled | Should -BeTrue
            $shared = $status.Servers | Where-Object Name -eq 'shared'
            $shared.Scope | Should -Be 'Project'
            $shared.Target | Should -Be 'https://project.example.com/mcp'
            ($status.Servers | Where-Object Name -eq 'userOnly').Scope | Should -Be 'User'
        } finally {
            Remove-Item -Path $projectDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}


Describe "ConvertFrom-DevKitGitDecorations" {

    It "parses 'HEAD -> branch' as the head ref" {
        $refs = ConvertFrom-DevKitGitDecorations -Raw ' (HEAD -> main, origin/main)'
        $refs.Count | Should -Be 2
        $refs[0].Kind | Should -Be 'head'
        $refs[0].Name | Should -Be 'main'
        $refs[1].Kind | Should -Be 'branch'
    }

    It "parses tags" {
        $refs = ConvertFrom-DevKitGitDecorations -Raw ' (tag: v1.2.0, main)'
        $refs[0].Kind | Should -Be 'tag'
        $refs[0].Name | Should -Be 'v1.2.0'
    }

    It "parses bare HEAD (detached checkout)" {
        $refs = ConvertFrom-DevKitGitDecorations -Raw ' (HEAD)'
        $refs.Count | Should -Be 1
        $refs[0].Kind | Should -Be 'head'
    }

    It "returns empty for empty/undecorated input" {
        ConvertFrom-DevKitGitDecorations -Raw '' | Should -BeNullOrEmpty
        ConvertFrom-DevKitGitDecorations -Raw ' ()' | Should -BeNullOrEmpty
    }
}

Describe "ConvertFrom-DevKitGitLogOutput" {

    BeforeAll {
        $script:rs = [char]0x1e; $script:us = [char]0x1f
        $script:h1 = 'a' * 40; $script:h2 = 'b' * 40
        $script:rec = { param($hash, $parents, $author, $when, $deco, $subject)
            return ('{0}{1}{2}{3}{4}{5}{6}{7}{8}{9}{10}' -f $rs, $hash, $us, $parents, $us, $author, $us, $when, $us, $deco, $us) + $subject
        }
    }

    It "parses a decorated record into all fields" {
        $out = & $rec $h1 $h2 'Jane Dev' '2 days ago' ' (HEAD -> main, tag: v1.0)' 'feat: shiny graph'
        $c = ConvertFrom-DevKitGitLogOutput -Output $out
        $c.Count | Should -Be 1
        $c[0].Hash | Should -Be $h1
        $c[0].ShortHash | Should -Be 'aaaaaaa'
        $c[0].Parents[0] | Should -Be $h2
        $c[0].Author | Should -Be 'Jane Dev'
        $c[0].When | Should -Be '2 days ago'
        $c[0].Subject | Should -Be 'feat: shiny graph'
        $c[0].Refs.Count | Should -Be 2
        $c[0].IsHead | Should -BeTrue
    }

    It "parses multiple records and multiple parents (merge)" {
        $out = ((& $rec $h1 "$h2 $h2" 'A' '1 day ago' '' 'merge') + "`n") + (& $rec $h2 '' 'B' '2 days ago' '' 'root')
        $c = ConvertFrom-DevKitGitLogOutput -Output $out
        $c.Count | Should -Be 2
        $c[0].Parents.Count | Should -Be 2
        $c[1].Parents.Count | Should -Be 0
        $c[1].IsHead | Should -BeFalse
    }

    It "returns empty for empty output" {
        ConvertFrom-DevKitGitLogOutput -Output '' | Should -BeNullOrEmpty
    }

    It "skips malformed records" {
        $out = ('{0}{1}{2}too-few-fields' -f $rs, $h1, $us)
        ConvertFrom-DevKitGitLogOutput -Output $out | Should -BeNullOrEmpty
    }
}

Describe "ConvertTo-DevKitGitGraphLayout" {

    BeforeAll {
        function New-TestCommit([string]$Hash, [string[]]$Parents) {
            return @{ Hash = $Hash; ShortHash = $Hash; Parents = $Parents; Refs = @(); Subject = 's'; Author = 'a'; When = 'w'; IsHead = $false }
        }
    }

    It "keeps linear history on one lane with straight links" {
        $commits = @( (New-TestCommit 'c3' @('c2')), (New-TestCommit 'c2' @('c1')), (New-TestCommit 'c1' @()) )
        $g = ConvertTo-DevKitGitGraphLayout -Commits $commits
        $g.LaneCount | Should -Be 1
        ($g.Nodes | ForEach-Object Lane) | Should -Be @(0, 0, 0)
        $g.Links.Count | Should -Be 2
        foreach ($l in $g.Links) { $l.FromLane | Should -Be $l.ToLane }
    }

    It "opens a lane for a merge's second parent and keeps the trunk straight" {
        # M merges B into A; B and A both descend from C (the fork point).
        $commits = @(
            (New-TestCommit 'M' @('A', 'B')),
            (New-TestCommit 'B' @('C')),
            (New-TestCommit 'A' @('C')),
            (New-TestCommit 'C' @())
        )
        $g = ConvertTo-DevKitGitGraphLayout -Commits $commits
        $g.LaneCount | Should -Be 2
        ($g.Nodes | Where-Object Hash -eq 'M').Lane | Should -Be 0
        ($g.Nodes | Where-Object Hash -eq 'B').Lane | Should -Be 1
        ($g.Nodes | Where-Object Hash -eq 'A').Lane | Should -Be 0
        # The first-parent trunk M -> A -> C never leaves lane 0...
        ($g.Nodes | Where-Object Hash -eq 'C').Lane | Should -Be 0
        # ...so the side branch B bends into it at the fork point C.
        ($g.Links | Where-Object { $_.FromRow -eq 1 -and $_.ToRow -eq 3 }).FromLane | Should -Be 1
        ($g.Links | Where-Object { $_.FromRow -eq 1 -and $_.ToRow -eq 3 }).ToLane | Should -Be 0
        # M -> B is the merge link.
        $mergeLinks = @($g.Links | Where-Object IsMerge)
        $mergeLinks.Count | Should -Be 1
        $mergeLinks[0].ToLane | Should -Be 1
    }

    It "opens one lane per extra parent for an octopus merge" {
        $commits = @(
            (New-TestCommit 'M' @('A', 'B', 'D')),
            (New-TestCommit 'B' @()),
            (New-TestCommit 'D' @()),
            (New-TestCommit 'A' @())
        )
        $g = ConvertTo-DevKitGitGraphLayout -Commits $commits
        $g.LaneCount | Should -Be 3
        (($g.Links | Where-Object IsMerge).Count) | Should -Be 2
    }

    It "skips parents outside the displayed set without inventing links" {
        $commits = @( (New-TestCommit 'c1' @('missing-parent')) )
        $g = ConvertTo-DevKitGitGraphLayout -Commits $commits
        $g.Nodes.Count | Should -Be 1
        $g.Links.Count | Should -Be 0
    }

    It "handles empty input" {
        $g = ConvertTo-DevKitGitGraphLayout -Commits @()
        $g.Nodes.Count | Should -Be 0
        $g.Links.Count | Should -Be 0
        $g.LaneCount | Should -Be 0
    }

    It "colors nodes and links from the lane palette" {
        $commits = @(
            (New-TestCommit 'M' @('A', 'B')),
            (New-TestCommit 'B' @()),
            (New-TestCommit 'A' @())
        )
        $g = ConvertTo-DevKitGitGraphLayout -Commits $commits
        ($g.Nodes | Where-Object Hash -eq 'M').Color | Should -Be (Get-DevKitGitLaneColor -Lane 0)
        ($g.Nodes | Where-Object Hash -eq 'B').Color | Should -Be (Get-DevKitGitLaneColor -Lane 1)
        $merge = $g.Links | Where-Object IsMerge
        $merge.FromColor | Should -Be (Get-DevKitGitLaneColor -Lane 0)
        $merge.ToColor | Should -Be (Get-DevKitGitLaneColor -Lane 1)
    }
}

Describe "Test-DevKitGitAutoFetchDue" {

    BeforeAll {
        $script:now = [DateTime]::new(2026, 8, 30, 12, 0, 0, [DateTimeKind]::Utc)
    }

    It "is due when the repo was never fetched" {
        Test-DevKitGitAutoFetchDue -LastAttemptUtc $null -NowUtc $script:now | Should -BeTrue
    }

    It "is due once the interval has elapsed" {
        $last = $script:now.AddSeconds(-61)
        Test-DevKitGitAutoFetchDue -LastAttemptUtc $last -NowUtc $script:now -MinIntervalSeconds 60 | Should -BeTrue
    }

    It "is not due inside the interval" {
        $last = $script:now.AddSeconds(-30)
        Test-DevKitGitAutoFetchDue -LastAttemptUtc $last -NowUtc $script:now -MinIntervalSeconds 60 | Should -BeFalse
    }

    It "is due when the stamp is in the future (clock skew must not starve fetches)" {
        $last = $script:now.AddMinutes(5)
        Test-DevKitGitAutoFetchDue -LastAttemptUtc $last -NowUtc $script:now -MinIntervalSeconds 60 | Should -BeTrue
    }
}

Describe "Test-DevKitGitSha" {

    It "accepts a full 40-hex id, either case" {
        Test-DevKitGitSha -Value ('a' * 40) | Should -BeTrue
        Test-DevKitGitSha -Value ('A1b2' * 10) | Should -BeTrue
    }

    It "rejects short ids, non-hex, and empty values" {
        Test-DevKitGitSha -Value 'a54151d' | Should -BeFalse
        Test-DevKitGitSha -Value ('g' * 40) | Should -BeFalse
        Test-DevKitGitSha -Value '' | Should -BeFalse
        Test-DevKitGitSha -Value $null | Should -BeFalse
    }

    It "rejects anything with extra characters around a valid id" {
        Test-DevKitGitSha -Value ("x" + ('a' * 40)) | Should -BeFalse
        Test-DevKitGitSha -Value (('a' * 40) + ' ') | Should -BeFalse
    }
}

Describe "Select-DevKitGitWantedTips" {

    BeforeAll {
        $script:tipA = 'a' * 40
        $script:tipB = 'b' * 40
    }

    It "keeps valid ids, lowercased" {
        $got = Select-DevKitGitWantedTips -ExtraTips @(('A' * 40)) -UnreachableTips $null
        $got | Should -Be @($script:tipA)
    }

    It "drops invalid ids rather than passing them to git" {
        $got = Select-DevKitGitWantedTips -ExtraTips @('deadbeef', '', ('g' * 40), $script:tipA) -UnreachableTips $null
        $got | Should -Be @($script:tipA)
    }

    It "dedupes ids that differ only by case" {
        $got = Select-DevKitGitWantedTips -ExtraTips @($script:tipA, ('A' * 40), $script:tipA) -UnreachableTips $null
        @($got).Count | Should -Be 1
    }

    It "drops tips already proven absent from this clone" {
        $memo = @{ $script:tipA = $true }
        $got = Select-DevKitGitWantedTips -ExtraTips @($script:tipA, $script:tipB) -UnreachableTips $memo
        $got | Should -Be @($script:tipB)
    }

    It "returns an empty array when every tip is unreachable (so the window stays at 40)" {
        $memo = @{ $script:tipA = $true; $script:tipB = $true }
        $got = Select-DevKitGitWantedTips -ExtraTips @($script:tipA, $script:tipB) -UnreachableTips $memo
        @($got).Count | Should -Be 0
    }

    It "returns a true 1-element array, not a bare string (regression: .Count would be 40)" {
        $got = Select-DevKitGitWantedTips -ExtraTips @($script:tipA) -UnreachableTips $null
        $got.Count | Should -Be 1
        , $got | Should -BeOfType [System.Object[]]
    }

    It "handles null and empty input without throwing" {
        # Assigned first, deliberately: the helper returns ,$array, and
        # @(call) would re-wrap an empty result into a 1-element array. The
        # production caller assigns for exactly this reason.
        $fromNull = Select-DevKitGitWantedTips -ExtraTips $null -UnreachableTips $null
        $fromEmpty = Select-DevKitGitWantedTips -ExtraTips @() -UnreachableTips @{}
        $fromNull.Count | Should -Be 0
        $fromEmpty.Count | Should -Be 0
    }

    It "reports Count 0 for an all-unreachable set the way the caller reads it (regression: the escalation re-armed)" {
        $memo = @{ $script:tipA = $true }
        $wanted = Select-DevKitGitWantedTips -ExtraTips @($script:tipA) -UnreachableTips $memo
        $wanted.Count | Should -Be 0
    }
}


Describe "ConvertFrom-DevKitGitShow" {

    BeforeAll {
        $script:rs = [char]0x1e; $script:us = [char]0x1f
        $script:h1 = 'a' * 40
    }

    It "parses hash, author, email, date and the full multi-line message" {
        # The '1\t2\tnot-a-file-line' body line looks exactly like a numstat
        # row - the record separator (not the line shape) must be what keeps
        # it out of the Files list.
        $msg = "feat: subject line`n`nBody paragraph.`n`n1`t2`tnot-a-file-line"
        $out = "$h1$us" + "Jane Dev$us" + "jane@example.com$us" + "2026-08-01T10:20:30-06:00$us" + $msg + $rs +
               "`n`n3`t2`tsrc/app.ps1`n10`t0`tsrc/new file.ps1`n`n 2 files changed, 13 insertions(+), 2 deletions(-)`n"
        $d = ConvertFrom-DevKitGitShow -Output $out
        $d.Hash | Should -Be $h1
        $d.Author | Should -Be 'Jane Dev'
        $d.Email | Should -Be 'jane@example.com'
        $d.Date | Should -Be '2026-08-01T10:20:30-06:00'
        $d.Message | Should -Be $msg
        $d.Files.Count | Should -Be 2
        $d.Files[0].Path | Should -Be 'src/app.ps1'
        $d.Files[0].Added | Should -Be 3
        $d.Files[0].Deleted | Should -Be 2
        $d.FilesChanged | Should -Be 2
        $d.Insertions | Should -Be 13
        $d.Deletions | Should -Be 2
    }

    It "handles a merge commit with no stat block" {
        $msg = "Merge branch 'feature/x'`n`nConflicts resolved in app.ps1."
        $out = "$h1$us" + "Jane Dev$us" + "jane@example.com$us" + "2026-08-01T10:20:30-06:00$us" + $msg + $rs + "`n"
        $d = ConvertFrom-DevKitGitShow -Output $out
        $d.Message | Should -Be $msg
        $d.Files.Count | Should -Be 0
        $d.FilesChanged | Should -Be 0
        $d.Insertions | Should -Be 0
        $d.Deletions | Should -Be 0
    }

    It "parses a subject-only message (empty body) with a singular shortstat" {
        $out = "$h1$us" + "A$us" + "a@b.c$us" + "2026-01-01T00:00:00+00:00$us" + "chore: bump version" + $rs +
               "`n`n1`t1`tf.txt`n`n 1 file changed, 1 insertion(+), 1 deletion(-)`n"
        $d = ConvertFrom-DevKitGitShow -Output $out
        $d.Message | Should -Be 'chore: bump version'
        $d.FilesChanged | Should -Be 1
        $d.Insertions | Should -Be 1
        $d.Deletions | Should -Be 1
    }

    It "flags binary files and sums counts when the shortstat line is missing" {
        $out = "$h1$us" + "A$us" + "a@b.c$us" + "2026-01-01T00:00:00+00:00$us" + "add logo" + $rs +
               "`n`n-`t-`tassets/logo.png`n4`t1`tREADME.md`n"
        $d = ConvertFrom-DevKitGitShow -Output $out
        $d.Files.Count | Should -Be 2
        $d.Files[0].IsBinary | Should -BeTrue
        $d.Files[1].IsBinary | Should -BeFalse
        $d.FilesChanged | Should -Be 2
        $d.Insertions | Should -Be 4
        $d.Deletions | Should -Be 1
    }

    It "returns null for empty or separator-less output" {
        ConvertFrom-DevKitGitShow -Output '' | Should -BeNullOrEmpty
        ConvertFrom-DevKitGitShow -Output "   `n  " | Should -BeNullOrEmpty
        ConvertFrom-DevKitGitShow -Output "fatal: bad object deadbeef" | Should -BeNullOrEmpty
    }
}


Describe "Get-DevKitEnvKeyNames" {

    It "extracts names, skipping comments, blanks, and export prefixes" {
        $lines = @('# comment', '', 'API_URL=https://x', 'export LOG_LEVEL=debug', '  SPACED_KEY = 1', 'not a var line')
        $names = Get-DevKitEnvKeyNames -Lines $lines
        $names.Count | Should -Be 3
        $names -contains 'API_URL' | Should -BeTrue
        $names -contains 'LOG_LEVEL' | Should -BeTrue
        $names -contains 'SPACED_KEY' | Should -BeTrue
    }

    It "dedupes repeated keys and returns a true array for one key" {
        $names = Get-DevKitEnvKeyNames -Lines @('A=1', 'A=2')
        $names.Count | Should -Be 1
    }

    It "returns empty for empty input" {
        Get-DevKitEnvKeyNames -Lines @() | Should -BeNullOrEmpty
    }
}

Describe "Compare-DevKitEnvKeys" {

    It "reports missing, empty, and extra keys" {
        $template = @('A=1', 'B=2', 'C=3')
        $env = @('A=1', 'B=', 'D=4')
        $diff = Compare-DevKitEnvKeys -TemplateLines $template -EnvLines $env
        $diff.Missing | Should -Be @('C')
        $diff.Empty | Should -Be @('B')
        $diff.Extra | Should -Be @('D')
        $diff.TemplateKeyCount | Should -Be 3
    }

    It "treats quoted-empty values as empty" {
        $diff = Compare-DevKitEnvKeys -TemplateLines @('A=1') -EnvLines @('A=""')
        $diff.Empty | Should -Be @('A')
    }

    It "reports a missing .env file as all-missing" {
        $diff = Compare-DevKitEnvKeys -TemplateLines @('A=1', 'B=2') -EnvLines @()
        $diff.Missing.Count | Should -Be 2
    }
}

Describe "Test-DevKitPortExcluded" {

    It "finds ports inside ranges and rejects ports outside" {
        $ranges = @(@{ Start = 50000; End = 50059 }, @{ Start = 5357; End = 5357 })
        Test-DevKitPortExcluded -Port 50050 -Ranges $ranges | Should -BeTrue
        Test-DevKitPortExcluded -Port 5357 -Ranges $ranges | Should -BeTrue
        Test-DevKitPortExcluded -Port 3000 -Ranges $ranges | Should -BeFalse
        Test-DevKitPortExcluded -Port 50060 -Ranges $ranges | Should -BeFalse
    }

    It "handles an empty range list" {
        Test-DevKitPortExcluded -Port 3000 -Ranges @() | Should -BeFalse
    }
}

Describe "Get-DevKitDirChildren" {

    It "returns folders first, then files, alphabetical case-insensitive" {
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'beta') | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'Alpha') | Out-Null
        New-Item -ItemType File -Path (Join-Path $TestDrive 'Zebra.txt') | Out-Null
        New-Item -ItemType File -Path (Join-Path $TestDrive 'apple.ps1') | Out-Null
        $r = Get-DevKitDirChildren -Path $TestDrive
        $r.Error | Should -BeNullOrEmpty
        ($r.Children | ForEach-Object Name) | Should -Be @('Alpha', 'beta', 'apple.ps1', 'Zebra.txt')
        $r.Children[0].IsDirectory | Should -BeTrue
        $r.Children[2].IsDirectory | Should -BeFalse
    }

    It "captures enumeration errors instead of throwing" {
        $missing = Join-Path $TestDrive 'no-such-folder'
        $r = Get-DevKitDirChildren -Path $missing
        $r.Error | Should -Not -BeNullOrEmpty
        $r.Children.Count | Should -Be 0
    }

    It "returns empty children for an empty folder" {
        $empty = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'empty')
        $r = Get-DevKitDirChildren -Path $empty.FullName
        $r.Error | Should -BeNullOrEmpty
        $r.Children.Count | Should -Be 0
    }
}

Describe "Test-DevKitPathWithinRoot" {

    It "accepts the root itself and nested paths" {
        Test-DevKitPathWithinRoot -Root $TestDrive -Path $TestDrive | Should -BeTrue
        Test-DevKitPathWithinRoot -Root $TestDrive -Path (Join-Path $TestDrive 'a\b\c.txt') | Should -BeTrue
    }

    It "rejects siblings with a shared name prefix" {
        $root = Join-Path $TestDrive 'proj'
        $outside = Join-Path $TestDrive 'proj2'
        Test-DevKitPathWithinRoot -Root $root -Path $outside | Should -BeFalse
    }

    It "rejects '..' escapes after normalization" {
        $root = Join-Path $TestDrive 'proj'
        $escape = Join-Path $root 'sub\..\..\elsewhere'
        Test-DevKitPathWithinRoot -Root $root -Path $escape | Should -BeFalse
        $staysIn = Join-Path $root 'sub\..\file.txt'
        Test-DevKitPathWithinRoot -Root $root -Path $staysIn | Should -BeTrue
    }

    It "rejects a null/empty root" {
        Test-DevKitPathWithinRoot -Root '' -Path $TestDrive | Should -BeFalse
        Test-DevKitPathWithinRoot -Root $null -Path $TestDrive | Should -BeFalse
    }
}

Describe "On-Deck store (Get/Save-DevKitProjectOnDeck)" {

    BeforeEach {
        $script:OnDeckFile = Join-Path $TestDrive 'ondeck.json'
        $script:ProjA = Join-Path $TestDrive 'ProjectA'
        $script:ProjB = Join-Path $TestDrive 'ProjectB'
    }

    It "returns empty for a missing file" {
        @(Get-DevKitProjectOnDeck -ProjectPath $ProjA -OnDeckFile $OnDeckFile).Count | Should -Be 0
    }

    It "returns empty for a corrupt store" {
        Set-Content -LiteralPath $OnDeckFile -Value '{ not json' -Encoding UTF8
        @(Get-DevKitProjectOnDeck -ProjectPath $ProjA -OnDeckFile $OnDeckFile).Count | Should -Be 0
    }

    It "round-trips items with their statuses" {
        $items = @(
            [PSCustomObject]@{ Id = 'a1'; Text = 'task one'; Status = 'notStarted'; UpdatedAt = '2026-01-01T00:00:00Z' },
            [PSCustomObject]@{ Id = 'a2'; Text = 'task two'; Status = 'done'; UpdatedAt = '2026-01-01T00:00:00Z' }
        )
        Save-DevKitProjectOnDeck -ProjectPath $ProjA -Items $items -OnDeckFile $OnDeckFile
        $loaded = @(Get-DevKitProjectOnDeck -ProjectPath $ProjA -OnDeckFile $OnDeckFile)
        $loaded.Count | Should -Be 2
        $loaded[0].Id | Should -Be 'a1'
        $loaded[0].Text | Should -Be 'task one'
        $loaded[0].Status | Should -Be 'notStarted'
        $loaded[1].Status | Should -Be 'done'
    }

    It "keeps projects isolated (same canonical key rules as notes)" {
        Save-DevKitProjectOnDeck -ProjectPath $ProjA -Items @([PSCustomObject]@{ Id = 'a1'; Text = 'a'; Status = 'notStarted'; UpdatedAt = '' }) -OnDeckFile $OnDeckFile
        Save-DevKitProjectOnDeck -ProjectPath $ProjB -Items @([PSCustomObject]@{ Id = 'b1'; Text = 'b'; Status = 'done'; UpdatedAt = '' }) -OnDeckFile $OnDeckFile
        @(Get-DevKitProjectOnDeck -ProjectPath $ProjA -OnDeckFile $OnDeckFile).Count | Should -Be 1
        # Trailing separator + casing still resolve to the same project.
        @(Get-DevKitProjectOnDeck -ProjectPath ($ProjA.ToUpperInvariant() + '\') -OnDeckFile $OnDeckFile)[0].Id | Should -Be 'a1'
    }

    It "keeps a one-item project a JSON array on save" {
        Save-DevKitProjectOnDeck -ProjectPath $ProjA -Items @([PSCustomObject]@{ Id = 'a1'; Text = 'a'; Status = 'notStarted'; UpdatedAt = '' }) -OnDeckFile $OnDeckFile
        Save-DevKitProjectOnDeck -ProjectPath $ProjB -Items @([PSCustomObject]@{ Id = 'b1'; Text = 'b'; Status = 'notStarted'; UpdatedAt = '' }) -OnDeckFile $OnDeckFile
        $raw = Get-Content -LiteralPath $OnDeckFile -Raw | ConvertFrom-Json
        $key = (Get-DevKitNotesProjectKey -ProjectPath $ProjA)
        # A bare object here would mean the single item unrolled out of its
        # array (the round-trip bug the @(...) in the save path guards).
        ($raw.projects.$key -is [array]) | Should -BeTrue
        @($raw.projects.$key).Count | Should -Be 1
    }

    It "removes the project entry when saved empty" {
        Save-DevKitProjectOnDeck -ProjectPath $ProjA -Items @([PSCustomObject]@{ Id = 'a1'; Text = 'a'; Status = 'notStarted'; UpdatedAt = '' }) -OnDeckFile $OnDeckFile
        Save-DevKitProjectOnDeck -ProjectPath $ProjA -Items @() -OnDeckFile $OnDeckFile
        @(Get-DevKitProjectOnDeck -ProjectPath $ProjA -OnDeckFile $OnDeckFile).Count | Should -Be 0
    }

    It "normalizes unknown statuses to notStarted on load" {
        Save-DevKitProjectOnDeck -ProjectPath $ProjA -Items @([PSCustomObject]@{ Id = 'a1'; Text = 'a'; Status = 'notStarted'; UpdatedAt = '' }) -OnDeckFile $OnDeckFile
        $raw = Get-Content -LiteralPath $OnDeckFile -Raw | ConvertFrom-Json
        $key = (Get-DevKitNotesProjectKey -ProjectPath $ProjA)
        $raw.projects.$key[0].status = 'bogus'
        Set-Content -LiteralPath $OnDeckFile -Value ($raw | ConvertTo-Json -Depth 6) -Encoding UTF8
        @(Get-DevKitProjectOnDeck -ProjectPath $ProjA -OnDeckFile $OnDeckFile)[0].Status | Should -Be 'notStarted'
    }
}

Describe "On-Deck list helpers" {

    BeforeEach {
        $script:Items = @(
            [PSCustomObject]@{ Id = 'n1'; Text = 'ns one'; Status = 'notStarted'; UpdatedAt = 't' },
            [PSCustomObject]@{ Id = 'n2'; Text = 'ns two'; Status = 'notStarted'; UpdatedAt = 't' },
            [PSCustomObject]@{ Id = 'p1'; Text = 'prog'; Status = 'inProgress'; UpdatedAt = 't' },
            [PSCustomObject]@{ Id = 'd1'; Text = 'done'; Status = 'done'; UpdatedAt = 't' }
        )
    }

    It "Add-DevKitOnDeckItem prepends a notStarted item" {
        $r = @(Add-DevKitOnDeckItem -Items $Items -Text '  new task  ')
        $r.Count | Should -Be 5
        $r[0].Text | Should -Be 'new task'
        $r[0].Status | Should -Be 'notStarted'
        $r[0].Id | Should -Not -BeNullOrEmpty
    }

    It "Add-DevKitOnDeckItem ignores blank text" {
        @(Add-DevKitOnDeckItem -Items $Items -Text '   ').Count | Should -Be 4
    }

    It "Set-DevKitOnDeckItemStatus moves the item into its new section" {
        $r = @(Set-DevKitOnDeckItemStatus -Items $Items -Id 'n2' -Status 'done')
        $r.Count | Should -Be 4
        # Regrouped stably: notStarted (n1), inProgress (p1), done (n2, d1 -
        # n2 keeps its original relative position ahead of d1).
        ($r | Select-Object -ExpandProperty Id) -join ',' | Should -Be 'n1,p1,n2,d1'
        ($r | Where-Object Id -eq 'n2').Status | Should -Be 'done'
    }

    It "Set-DevKitOnDeckItemStatus stamps UpdatedAt and leaves the input array untouched" {
        $before = ($Items | Where-Object Id -eq 'n1').Status
        $r = @(Set-DevKitOnDeckItemStatus -Items $Items -Id 'n1' -Status 'inProgress')
        ($Items | Where-Object Id -eq 'n1').Status | Should -Be $before
        ($r | Where-Object Id -eq 'n1').UpdatedAt | Should -Not -Be 't'
    }

    It "Set-DevKitOnDeckItemStatus with an unknown id changes nothing" {
        $r = @(Set-DevKitOnDeckItemStatus -Items $Items -Id 'nope' -Status 'done')
        ($r | Select-Object -ExpandProperty Id) -join ',' | Should -Be 'n1,n2,p1,d1'
    }

    It "Set-DevKitOnDeckItemStatus normalizes an unknown status to notStarted" {
        $r = @(Set-DevKitOnDeckItemStatus -Items $Items -Id 'd1' -Status 'bogus')
        ($r | Where-Object Id -eq 'd1').Status | Should -Be 'notStarted'
        # Regrouped stably: d1 joins the END of the notStarted section.
        ($r | Select-Object -ExpandProperty Id) -join ',' | Should -Be 'n1,n2,d1,p1'
    }

    It "Remove-DevKitOnDeckItem drops exactly one item" {
        $r = @(Remove-DevKitOnDeckItem -Items $Items -Id 'p1')
        $r.Count | Should -Be 3
        @($r | Where-Object Id -eq 'p1').Count | Should -Be 0
    }

    It "Clear-DevKitOnDeckDone removes only done items" {
        $r = @(Clear-DevKitOnDeckDone -Items $Items)
        $r.Count | Should -Be 3
        @($r | Where-Object Status -eq 'done').Count | Should -Be 0
    }

    It "Group-DevKitOnDeckItems orders by section, stable within a section" {
        $messy = @($Items[3], $Items[0], $Items[2], $Items[1])
        $r = @(Group-DevKitOnDeckItems -Items $messy)
        ($r | Select-Object -ExpandProperty Id) -join ',' | Should -Be 'n1,n2,p1,d1'
    }
}

Describe "Get-DevKitProcessClassification" {

    It "classifies Windows system processes as System" {
        Get-DevKitProcessClassification -Name 'system' | Should -Be 'System'
        Get-DevKitProcessClassification -Name 'svchost' | Should -Be 'System'
        Get-DevKitProcessClassification -Name 'lsass' | Should -Be 'System'
        Get-DevKitProcessClassification -Name 'Memory Compression' | Should -Be 'System'
        Get-DevKitProcessClassification -Name 'csrss' | Should -Be 'System'
        Get-DevKitProcessClassification -Name 'dwm' | Should -Be 'System'
    }

    It "classifies well-known user/dev apps as Safe" {
        Get-DevKitProcessClassification -Name 'node' | Should -Be 'Safe'
        Get-DevKitProcessClassification -Name 'code' | Should -Be 'Safe'
        Get-DevKitProcessClassification -Name 'chrome' | Should -Be 'Safe'
        Get-DevKitProcessClassification -Name 'spotify' | Should -Be 'Safe'
    }

    It "classifies anything unknown as Caution" {
        Get-DevKitProcessClassification -Name 'mysteryproc' | Should -Be 'Caution'
        # conhost is killable, but not a well-known user app - Caution, not Safe.
        Get-DevKitProcessClassification -Name 'conhost' | Should -Be 'Caution'
    }

    It "strips a trailing .exe and matches case-insensitively" {
        Get-DevKitProcessClassification -Name 'NODE.EXE' | Should -Be 'Safe'
        Get-DevKitProcessClassification -Name 'Svchost.exe' | Should -Be 'System'
        Get-DevKitProcessClassification -Name 'Code.EXE' | Should -Be 'Safe'
        Get-DevKitProcessClassification -Name 'LSASS' | Should -Be 'System'
    }
}

Describe "ConvertFrom-DevKitGpuEngineInstance" {

    It "parses a plain 3D engine instance" {
        $r = ConvertFrom-DevKitGpuEngineInstance -InstanceName 'pid_4056_engtype_3D'
        $r.Pid | Should -Be 4056
        $r.EngineType | Should -Be '3D'
    }

    It "parses a compute engine variant (engine type contains an underscore)" {
        $r = ConvertFrom-DevKitGpuEngineInstance -InstanceName 'pid_1234_engtype_Compute_0'
        $r.Pid | Should -Be 1234
        $r.EngineType | Should -Be 'Compute_0'
    }

    It "parses a luid-prefixed variant" {
        $r = ConvertFrom-DevKitGpuEngineInstance -InstanceName 'luid_0x00000000_0x0000974E_phys_0_eng_2_pid_4056_engtype_VideoEncode'
        $r.Pid | Should -Be 4056
        $r.EngineType | Should -Be 'VideoEncode'
    }

    It "returns $null for a luid-only instance with no pid" {
        ConvertFrom-DevKitGpuEngineInstance -InstanceName 'luid_0x00000000_0x0000974E_phys_0_eng_2_engtype_3D' |
            Should -BeNullOrEmpty
    }

    It "returns $null for garbage and empty input" {
        ConvertFrom-DevKitGpuEngineInstance -InstanceName '' | Should -BeNullOrEmpty
        ConvertFrom-DevKitGpuEngineInstance -InstanceName 'not-an-instance' | Should -BeNullOrEmpty
        ConvertFrom-DevKitGpuEngineInstance -InstanceName 'engtype_3D' | Should -BeNullOrEmpty
        ConvertFrom-DevKitGpuEngineInstance -InstanceName 'pid_abc_engtype_3D' | Should -BeNullOrEmpty
        ConvertFrom-DevKitGpuEngineInstance -InstanceName 'pid_4056_engtype_' | Should -BeNullOrEmpty
    }
}

Describe "ConvertFrom-DevKitNvidiaSmiAdapterOutput" {

    It "parses 'name, temp, util, memUsed, memTotal' output" {
        $r = ConvertFrom-DevKitNvidiaSmiAdapterOutput -Output 'NVIDIA GeForce RTX 3080, 44, 12, 2048, 10240'
        $r.Name | Should -Be 'NVIDIA GeForce RTX 3080'
        $r.TempC | Should -Be 44
        $r.Percent | Should -Be 12
        $r.MemUsedMB | Should -Be 2048
        $r.MemTotalMB | Should -Be 10240
    }

    It "returns $null for unparsable output" {
        ConvertFrom-DevKitNvidiaSmiAdapterOutput -Output '' | Should -BeNullOrEmpty
        ConvertFrom-DevKitNvidiaSmiAdapterOutput -Output 'N/A, N/A, N/A, N/A, N/A' | Should -BeNullOrEmpty
    }
}

Describe "background git calls do not run programs named in the project's git config" {

    # The installed app is admin-only, so its polls run elevated inside the
    # active project - and git obeys that project's .git/config, which
    # anything running as the user can write. core.fsmonitor=<path> makes
    # 'git status' run that program: without the override this was a way to
    # be run as Administrator with no click at all.

    BeforeAll {
        $script:GitExe = Get-DevKitWindowsExecutable -Name 'git'
        $script:HookRepo = Join-Path $TestDrive "fsmonitor-repo-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        $script:HookMarker = Join-Path $TestDrive "fsmonitor-ran-$([guid]::NewGuid().ToString('N').Substring(0, 8)).txt"
        $hook = Join-Path $TestDrive "fsmonitor-hook-$([guid]::NewGuid().ToString('N').Substring(0, 8)).cmd"
        if ($script:GitExe) {
            [void](New-Item -ItemType Directory -Path $script:HookRepo)
            & $script:GitExe.Source -C $script:HookRepo init -q -b main
            & $script:GitExe.Source -C $script:HookRepo -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m first
            [System.IO.File]::WriteAllText($hook, "@echo off`r`necho ran > `"$($script:HookMarker)`"`r`n")
            & $script:GitExe.Source -C $script:HookRepo config core.fsmonitor ($hook -replace '\\', '/')
        }
    }

    It "has git available for these tests" {
        $script:GitExe | Should -Not -BeNullOrEmpty
    }

    It "the overview poll does not execute the configured program" {
        if (Test-Path -LiteralPath $script:HookMarker) { Remove-Item -LiteralPath $script:HookMarker }
        $overview = Get-DevKitRepoOverview -Path $script:HookRepo -IncludeGraph $false
        $overview.IsRepo | Should -BeTrue
        $overview.Error | Should -BeNullOrEmpty
        Start-Sleep -Milliseconds 400
        Test-Path -LiteralPath $script:HookMarker | Should -BeFalse
    }

    It "control: a plain 'git status' in that same repository DOES execute it (so the test above can fail)" {
        if (Test-Path -LiteralPath $script:HookMarker) { Remove-Item -LiteralPath $script:HookMarker }
        $null = & $script:GitExe.Source -C $script:HookRepo status --porcelain 2>&1
        Start-Sleep -Milliseconds 400
        Test-Path -LiteralPath $script:HookMarker | Should -BeTrue
    }

    It "commit details do not execute it either, and still answer" {
        if (Test-Path -LiteralPath $script:HookMarker) { Remove-Item -LiteralPath $script:HookMarker }
        $head = (& $script:GitExe.Source -c core.fsmonitor=false -C $script:HookRepo rev-parse HEAD | Out-String).Trim()
        $details = Get-DevKitCommitDetails -Path $script:HookRepo -Hash $head
        $details.Error | Should -BeNullOrEmpty
        Start-Sleep -Milliseconds 400
        Test-Path -LiteralPath $script:HookMarker | Should -BeFalse
    }

    It "forces both settings off for every git call the app makes on its own" {
        $joined = $script:DevKitGitBackgroundArgs -join ' '
        foreach ($setting in 'core.fsmonitor=false', 'protocol.ext.allow=never', 'protocol.git.allow=never', 'remote.origin.uploadpack=git-upload-pack') {
            $joined | Should -Match ([regex]::Escape("-c $setting"))
        }
        $joined | Should -Match ([regex]::Escape("-c core.hooksPath=$($script:DevKitGitNoHooksPath)"))
        # every element is a '-c' followed by one setting: nothing else rides along
        ($script:DevKitGitBackgroundArgs.Count % 2) | Should -Be 0
        for ($i = 0; $i -lt $script:DevKitGitBackgroundArgs.Count; $i += 2) { $script:DevKitGitBackgroundArgs[$i] | Should -Be '-c' }
        $source = Join-Path $script:RepoRoot 'core\DevKit-WidgetCore.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$null)
        foreach ($name in 'Get-DevKitRepoOverview', 'Invoke-DevKitGitAutoFetch', 'Get-DevKitCommitDetails') {
            $function = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
            $function | Should -Not -BeNullOrEmpty
            # every "& $git.Source ..." / "& $Git.Source ..." in the function
            $spawns = @($function.FindAll({ param($n)
                        $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq 'Ampersand' -and
                        $n.CommandElements[0].Extent.Text -match '^\$git\.Source$' }, $true))
            $spawns.Count | Should -BeGreaterThan 0 -Because "$name spawns git"
            foreach ($spawn in $spawns) {
                $spawn.CommandElements[1].Extent.Text | Should -Be '@script:DevKitGitBackgroundArgs' -Because "a git call in $name must carry the override first"
            }
        }
    }

    It "points hooks at a folder only an administrator could create - not at '/dev/null'" {
        # Started from PowerShell, Git for Windows reads '/dev/null' as
        # '\dev\null' on the repository's drive: a folder any user can create
        # at a drive root, which would have moved hooks to one place every
        # repository on that drive shares instead of disabling them.
        $script:DevKitGitNoHooksPath | Should -Not -Match '^/'
        $expectedRoot = ($env:SystemRoot -replace '\\', '/') + '/System32/'
        $script:DevKitGitNoHooksPath.StartsWith($expectedRoot, [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        Test-Path -LiteralPath ($script:DevKitGitNoHooksPath -replace '/', '\') | Should -BeFalse
        # ...and that is where git itself says it will look.
        $where = (& $script:GitExe.Source @script:DevKitGitBackgroundArgs -C $script:HookRepo rev-parse --git-path hooks/reference-transaction | Out-String).Trim()
        $where.StartsWith($expectedRoot, [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        $where | Should -Not -Match '^/dev/'
    }

    It "never runs a diff driver, text converter or signature checker the repository configures" {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'core\DevKit-WidgetCore.ps1'))
        $text.Contains("'show' '--no-show-signature' '--no-ext-diff' '--no-textconv'") | Should -BeTrue
        $text.Contains("'log' '--no-show-signature' '--all'") | Should -BeTrue
    }

    Context "a hook planted in the project's .git\hooks" {

        # .git/hooks/reference-transaction runs on any fetch that moves a ref,
        # with no configuration at all - and the app fetches in the
        # background, elevated, about once a minute.

        BeforeAll {
            $script:HookBase = Join-Path $TestDrive "hook-probe-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
            $script:HookOrigin = Join-Path $script:HookBase 'origin.git'
            $script:HookWork = Join-Path $script:HookBase 'work'
            $script:HookClone = Join-Path $script:HookBase 'clone'
            $script:HookRan = Join-Path $script:HookBase 'hook-ran.txt'
            if ($script:GitExe) {
                $g = $script:GitExe.Source
                [void](New-Item -ItemType Directory -Path $script:HookBase)
                & $g init -q --bare -b main $script:HookOrigin
                & $g clone -q $script:HookOrigin $script:HookWork 2>$null
                & $g -C $script:HookWork -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m one
                & $g -C $script:HookWork push -q origin HEAD:main 2>$null
                & $g clone -q $script:HookOrigin $script:HookClone 2>$null
                [System.IO.File]::WriteAllText((Join-Path $script:HookClone '.git\hooks\reference-transaction'),
                    "#!/bin/sh`necho ran > '$($script:HookRan -replace '\\', '/')'`n")
            }
            function Push-TestCommit {
                $g = $script:GitExe.Source
                & $g -C $script:HookWork -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m more
                & $g -C $script:HookWork push -q origin HEAD:main 2>$null
            }
        }

        It "is not executed by the background fetch, which still fetches" {
            Push-TestCommit
            $before = (& $script:GitExe.Source -c core.hooksPath=/dev/null -C $script:HookClone rev-parse origin/main | Out-String).Trim()
            if (Test-Path -LiteralPath $script:HookRan) { Remove-Item -LiteralPath $script:HookRan }
            Invoke-DevKitGitAutoFetch -Path $script:HookClone -Git $script:GitExe
            $after = (& $script:GitExe.Source -c core.hooksPath=/dev/null -C $script:HookClone rev-parse origin/main | Out-String).Trim()
            $after | Should -Not -Be $before          # the fetch really happened
            Test-Path -LiteralPath $script:HookRan | Should -BeFalse
        }

        It "control: a plain 'git fetch' in that same clone DOES execute it" {
            Push-TestCommit
            if (Test-Path -LiteralPath $script:HookRan) { Remove-Item -LiteralPath $script:HookRan }
            $null = & $script:GitExe.Source -C $script:HookClone fetch -q origin 2>&1
            Test-Path -LiteralPath $script:HookRan | Should -BeTrue
        }
    }
}

Describe "Get-DevKitCliVersionCached" {

    # The MCP report asked 'claude --version' and 'kimi --version' on every
    # poll: two process starts to read back strings that only change when
    # the tool is updated.

    BeforeEach {
        $script:CliVersionCache = @{}
        # A stand-in CLI that counts how often it was started.
        $script:FakeCli = Join-Path $TestDrive 'fakecli.cmd'
        $script:CallLog = Join-Path $TestDrive 'calls.log'
        if (Test-Path -LiteralPath $script:CallLog) { Remove-Item -LiteralPath $script:CallLog -Force }
        Set-Content -LiteralPath $script:FakeCli -Encoding Ascii -Value @(
            '@echo off',
            "echo called>>`"$($script:CallLog)`"",
            'echo 2.1.5 (Fake CLI)',
            'echo a second line that is not the version'
        )
        $script:FakeCommand = [PSCustomObject]@{ Source = $script:FakeCli }
        function script:Get-FakeCliCalls {
            if (Test-Path -LiteralPath $script:CallLog) { return @(Get-Content -LiteralPath $script:CallLog).Count }
            return 0
        }
    }

    It "returns the first line of the tool's version output" {
        Get-DevKitCliVersionCached -Command $script:FakeCommand | Should -Be '2.1.5 (Fake CLI)'
    }

    It "starts the tool once for any number of asks" {
        1..5 | ForEach-Object { $null = Get-DevKitCliVersionCached -Command $script:FakeCommand }
        Get-FakeCliCalls | Should -Be 1
    }

    It "asks again after the tool's file changes (an update)" {
        $null = Get-DevKitCliVersionCached -Command $script:FakeCommand
        (Get-Item -LiteralPath $script:FakeCli).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(5)
        $null = Get-DevKitCliVersionCached -Command $script:FakeCommand
        Get-FakeCliCalls | Should -Be 2
    }

    It "asks again once the kept answer is older than the limit" {
        $null = Get-DevKitCliVersionCached -Command $script:FakeCommand -MaxAgeMinutes 30
        foreach ($key in @($script:CliVersionCache.Keys)) { $script:CliVersionCache[$key].At = (Get-Date).AddMinutes(-31) }
        $null = Get-DevKitCliVersionCached -Command $script:FakeCommand -MaxAgeMinutes 30
        Get-FakeCliCalls | Should -Be 2
    }

    It "does not keep a failed read, so the next ask tries again" {
        $missing = [PSCustomObject]@{ Source = (Join-Path $TestDrive 'not-installed.cmd') }
        Get-DevKitCliVersionCached -Command $missing | Should -BeNullOrEmpty
        $script:CliVersionCache.Count | Should -Be 0
    }
}

Describe "Get-DevKitCpuTempReading" {

    # The thermal-zone read used to go through Get-Counter, which waits a
    # full sample interval per call (1.2 s measured) - on the metrics lane,
    # so the gauges stalled each time the cached value expired.

    BeforeEach {
        $script:CpuTempCache = $null
        $script:ZoneReads = 0
    }

    It "converts the thermal zone's Kelvin reading to Celsius" {
        Mock Get-DevKitThermalZoneKelvin { $script:ZoneReads++; return 320.15 }
        Mock Get-CimInstance { throw 'the WMI fallback must not run when the counter answered' }
        Get-DevKitCpuTempReading | Should -Be 47
    }

    It "reads the zone once for many asks inside the cache window" {
        Mock Get-DevKitThermalZoneKelvin { $script:ZoneReads++; return 320.15 }
        1..10 | ForEach-Object { $null = Get-DevKitCpuTempReading }
        $script:ZoneReads | Should -Be 1
    }

    It "reads again once the kept value is older than the window" {
        Mock Get-DevKitThermalZoneKelvin { $script:ZoneReads++; return 320.15 }
        $null = Get-DevKitCpuTempReading
        $script:CpuTempCache.At = (Get-Date).AddSeconds(-16)
        $null = Get-DevKitCpuTempReading
        $script:ZoneReads | Should -Be 2
    }

    It "falls back to the ACPI WMI class (tenths of Kelvin) when there is no counter" {
        Mock Get-DevKitThermalZoneKelvin { return $null }
        Mock Get-CimInstance { return [PSCustomObject]@{ CurrentTemperature = 3231.5 } }
        Get-DevKitCpuTempReading | Should -Be 50
    }

    It "answers nothing rather than a made-up number when neither source has a plausible value" {
        # 30 is not Kelvin for anything a computer survives; 0 is what a
        # zone with no sensor behind it reports.
        Mock Get-DevKitThermalZoneKelvin { return 30 }
        Mock Get-CimInstance { return [PSCustomObject]@{ CurrentTemperature = 0 } }
        Get-DevKitCpuTempReading | Should -BeNullOrEmpty
    }

    It "keeps a 'nothing available' answer for the window too, instead of asking every cycle" {
        Mock Get-DevKitThermalZoneKelvin { $script:ZoneReads++; return $null }
        Mock Get-CimInstance { throw 'access denied' }
        1..5 | ForEach-Object { Get-DevKitCpuTempReading | Should -BeNullOrEmpty }
        $script:ZoneReads | Should -Be 1
    }
}

Describe "Get-DevKitThermalZoneKelvin" {

    It "answers nothing or a plausible Kelvin value on whatever machine runs this, without throwing" {
        $script:ThermalZoneCounters = $null
        $value = Get-DevKitThermalZoneKelvin
        if ($null -ne $value) {
            $value | Should -BeGreaterThan 200
            $value | Should -BeLessThan 500
        }
        # Whatever the answer, the lookup is not repeated: the counters are
        # either built or known to be absent.
        $null -ne $script:ThermalZoneCounters | Should -BeTrue
    }

    It "answers a second read from the same counter objects, quickly" {
        $null = Get-DevKitThermalZoneKelvin
        $before = $script:ThermalZoneCounters
        $elapsed = Measure-Command { 1..20 | ForEach-Object { $null = Get-DevKitThermalZoneKelvin } }
        [object]::ReferenceEquals($before, $script:ThermalZoneCounters) | Should -BeTrue
        # Twenty reads. The old way took over a second for ONE.
        $elapsed.TotalMilliseconds | Should -BeLessThan 1000
    }
}
