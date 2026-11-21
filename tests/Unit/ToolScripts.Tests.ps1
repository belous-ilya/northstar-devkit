#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests that pin safety properties of the destructive tool scripts
    by READING them - none of these scripts is ever executed here.
.DESCRIPTION
    Git-SyncFork, Git-Cleanup and Vite-PreviewBuild rewrite git history,
    delete objects and move build folders. They cannot be run "to see if
    they work" (AGENTS.md, Security Considerations), and they have no pure
    core to unit-test, so the properties that matter are asserted against
    the parsed script: which commands they run, with which arguments, and in
    which order.
.NOTES
    Pester 5 syntax (dashed `Should -Be`).
    Run with:
        Invoke-Pester -Path .\tests\Unit\ToolScripts.Tests.ps1
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    function Get-ScriptAst {
        param([string]$RelativePath)
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot $RelativePath), [ref]$null, [ref]$errors)
        @($errors).Count | Should -Be 0
        return $ast
    }

    # Every native `git <verb> ...` call in a script, in source order.
    function Get-GitCalls {
        param($Ast)
        return @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'git' }, $true) |
                Sort-Object { $_.Extent.StartOffset } |
                ForEach-Object { [pscustomobject]@{ Offset = $_.Extent.StartOffset; Text = $_.Extent.Text } })
    }
}

Describe "Git-SyncFork.ps1 force-push safety" {

    BeforeAll {
        $script:Calls = Get-GitCalls -Ast (Get-ScriptAst 'tools\git\Git-SyncFork.ps1')
    }

    It "pins the fork's tip to an explicit sha in the lease" {
        @($script:Calls | Where-Object { $_.Text -match '--force-with-lease=\$\{Branch\}:\$originLeaseSha' }).Count | Should -Be 1
    }

    It "checks the fork has nothing the checkout lacks, before rebasing" {
        $ancestor = @($script:Calls | Where-Object { $_.Text -match 'merge-base --is-ancestor' })[0]
        $rebase = @($script:Calls | Where-Object { $_.Text -match '^git rebase' })[0]
        $ancestor | Should -Not -BeNullOrEmpty
        $ancestor.Offset | Should -BeLessThan $rebase.Offset
    }

    It "never fetches the fork between the rebase and the push" {
        # That fetch is what made the old lease meaningless: it moved the
        # remote-tracking ref to whatever had just been pushed elsewhere,
        # and the push then overwrote it.
        $rebase = @($script:Calls | Where-Object { $_.Text -match '^git rebase' })[0]
        $fetchesAfter = @($script:Calls | Where-Object { $_.Text -match '^git fetch \$OriginRemote' -and $_.Offset -gt $rebase.Offset })
        $fetchesAfter.Count | Should -Be 0
    }

    It "never force-pushes without a lease" {
        @($script:Calls | Where-Object { $_.Text -match '^git push' -and $_.Text -match '(\s-f\b|--force(\s|$))' }).Count | Should -Be 0
    }
}

Describe "Git-Cleanup.ps1 garbage collection" {

    BeforeAll {
        $script:Ast = Get-ScriptAst 'tools\git\Git-Cleanup.ps1'
        $script:Source = $script:Ast.Extent.Text
    }

    It "declares the explicit -Aggressive switch" {
        @($script:Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) | Should -Contain 'Aggressive'
    }

    It "runs a plain gc by default, and the irreversible one only when asked" {
        $script:Source | Should -Match "\`$gcArgs = @\('gc'\)"
        $script:Source | Should -Match "\`$gcArgs = @\('gc', '--aggressive', '--prune=now'\)"
        # The everyday pass takes its strength from -Aggressive...
        $script:Source | Should -Match 'Invoke-DevKitGitGc -Thorough:\$Aggressive'
        # ...and no hard-coded aggressive gc COMMAND is left (the words still
        # appear in the help text, so this looks at commands, not text).
        @(Get-GitCalls -Ast $script:Ast | Where-Object { $_.Text -match 'gc\s+--aggressive' }).Count | Should -Be 0
        @(Get-GitCalls -Ast $script:Ast | Where-Object { $_.Text -match '^git @gcArgs' }).Count | Should -Be 1
    }
}

Describe "Vite-PreviewBuild.ps1 build-output safety" {

    BeforeAll {
        $script:Source = (Get-ScriptAst 'tools\vite\Vite-PreviewBuild.ps1').Extent.Text
    }

    It "refuses an OutDir that holds project files" {
        foreach ($name in @('src', 'public', 'node_modules', '.git')) {
            $script:Source | Should -Match ("'" + [regex]::Escape($name) + "'")
        }
        $script:Source | Should -Match 'is not a build-output folder'
    }

    It "restores the previous build when the new one landed somewhere else" {
        # The check must sit BEFORE the backup is deleted.
        $check = $script:Source.IndexOf('did not write to')
        $delete = $script:Source.IndexOf('the backup is no longer needed')
        $check | Should -BeGreaterThan 0
        $delete | Should -BeGreaterThan $check
    }

    It "serves the folder it verified" {
        @([regex]::Matches($script:Source, 'vite preview --port \$Port --outDir \$OutDir')).Count | Should -Be 4
    }
}

Describe "Git-Cleanup.ps1 branch and result safety" {

    BeforeAll {
        $script:CleanupAst = Get-ScriptAst 'tools\git\Git-Cleanup.ps1'
        $script:CleanupText = $script:CleanupAst.Extent.Text
        $script:CleanupCalls = Get-GitCalls -Ast $script:CleanupAst
    }

    It "never offers a long-lived branch for deletion" {
        $assignment = $script:CleanupAst.Find({ param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$protectedBranches' }, $true)
        $assignment | Should -Not -BeNullOrEmpty
        $protected = & ([scriptblock]::Create($assignment.Right.Extent.Text))
        foreach ($name in 'main', 'master', 'develop', 'staging', 'production', 'prod', 'release', 'gh-pages') {
            $protected | Should -Contain $name
        }
        # ...and the filter that builds the delete list actually uses it.
        $script:CleanupText.Contains('$_ -notin $protectedBranches') | Should -BeTrue
        $script:CleanupText.Contains("-notmatch '^(release|hotfix)/'") | Should -BeTrue
    }

    It "deletes branches only with -d, never the forcing -D" {
        $deletes = @($script:CleanupCalls | Where-Object { $_.Text -match '^git branch -[dD]\b' })
        $deletes.Count | Should -BeGreaterThan 0
        foreach ($call in $deletes) { $call.Text | Should -MatchExactly '^git branch -d ' }
    }

    It "asks git whether this is a repository instead of looking for a .git folder" {
        @($script:CleanupCalls | Where-Object { $_.Text -match 'rev-parse --is-inside-work-tree' }).Count | Should -Be 1
        $script:CleanupText.Contains('Join-Path $targetPath ".git"') | Should -BeFalse
    }

    It "exits non-zero when a step failed" {
        $script:CleanupText.Contains('if ($script:failures -gt 0) { exit 1 }') | Should -BeTrue
        # Every ERROR line for a failed git step is followed by a count.
        $counted = @([regex]::Matches($script:CleanupText, 'Write-Host "  ERROR[^\r\n]*\r?\n\s*\$script:failures\+\+')).Count
        $counted | Should -BeGreaterOrEqual 6
    }
}

Describe "Check-NpmCacheSize.ps1 is read-only" {

    It "runs no package-manager command that changes a cache" {
        $ast = Get-ScriptAst 'tools\node\Check-NpmCacheSize.ps1'
        $calls = @($ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('npm', 'pnpm', 'yarn', 'bun') }, $true) |
                ForEach-Object { $_.Extent.Text })
        $calls.Count | Should -BeGreaterThan 0
        foreach ($call in $calls) {
            $call | Should -Not -Match '\b(verify|clean|prune|clear|rm)\b'
        }
    }
}

Describe "Kill-Port.ps1 parameters" {

    It "has a default parameter set, so running it with no port is a message and not a binder error" {
        $ast = Get-ScriptAst 'tools\ports\Kill-Port.ps1'
        $binding = @($ast.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' })[0]
        $default = @($binding.NamedArguments | Where-Object { $_.ArgumentName -eq 'DefaultParameterSetName' })[0]
        $default.Argument.Value | Should -Be 'ByPort'
    }
}

Describe "Docker-Nuke.ps1" {

    BeforeAll {
        $script:NukeAst = Get-ScriptAst 'tools\docker\Docker-Nuke.ps1'
        $script:NukeText = $script:NukeAst.Extent.Text
        # Load ONLY the batching helper out of the script - nothing else in
        # it is ever executed here.
        $helper = $script:NukeAst.Find({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-DevKitDockerBatch' }, $true)
        $helper | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($helper.Extent.Text))
    }

    It "passes ids to docker in batches, and every id exactly once" {
        $script:DockerCalls = [System.Collections.Generic.List[object]]::new()
        function docker { $script:DockerCalls.Add(@($args)); $global:LASTEXITCODE = 0 }
        $ids = 1..120 | ForEach-Object { "vol$_" }
        $result = Invoke-DevKitDockerBatch -Command @('volume', 'rm') -Ids $ids
        $script:DockerCalls.Count | Should -Be 3
        $script:DockerCalls[0][0] | Should -Be 'volume'
        $script:DockerCalls[0][1] | Should -Be 'rm'
        $script:DockerCalls[0].Count | Should -Be 52     # 2 command words + 50 ids
        $script:DockerCalls[2].Count | Should -Be 22     # 2 command words + 20 ids
        $seen = @(foreach ($call in $script:DockerCalls) { $call | Select-Object -Skip 2 })
        $seen.Count | Should -Be 120
        @($seen | Select-Object -Unique).Count | Should -Be 120
        $result.Failed | Should -BeFalse
    }

    It "reports failure when any one batch fails, and still runs the rest" {
        $script:DockerCallCount = 0
        function docker {
            $script:DockerCallCount++
            $global:LASTEXITCODE = if ($script:DockerCallCount -eq 1) { 1 } else { 0 }
            'Error: volume is in use'
        }
        $result = Invoke-DevKitDockerBatch -Command @('volume', 'rm') -Ids (1..60 | ForEach-Object { "v$_" })
        $script:DockerCallCount | Should -Be 2
        $result.Failed | Should -BeTrue
        @($result.Output).Count | Should -Be 2
    }

    It "does nothing for an empty list" {
        $script:DockerCallCount = 0
        function docker { $script:DockerCallCount++ }
        $result = Invoke-DevKitDockerBatch -Command @('rm', '-f') -Ids @()
        $script:DockerCallCount | Should -Be 0
        $result.Failed | Should -BeFalse
    }

    It "removes the containers the user confirmed, not a fresh listing" {
        $script:NukeText.Contains('docker rm -f $(docker ps -aq)') | Should -BeFalse
        $script:NukeText.Contains("Invoke-DevKitDockerBatch -Command @('rm', '-f') -Ids @(`$containers)") | Should -BeTrue
    }

    It "names volumes and networks in the dry run" {
        $script:NukeText.Contains('Volumes that would be removed') | Should -BeTrue
        $script:NukeText.Contains('Custom networks that would be removed') | Should -BeTrue
    }

    It "builds the confirmation sentence from the Keep flags and exits non-zero on problems" {
        $script:NukeText.Contains('-Action "destroy ALL Docker containers, images, volumes, and networks"') | Should -BeFalse
        $script:NukeText.Contains('Confirm-DevKitDestructiveAction -Action $actionText') | Should -BeTrue
        $script:NukeText.Contains('if ($script:problems -gt 0) { exit 1 }') | Should -BeTrue
    }
}

Describe "Confirm-DevKitDestructiveAction" {

    BeforeAll {
        $global:DevKitCommonLoaded = $false
        . (Join-Path $script:RepoRoot 'tools\lib\DevKit-Common.ps1')
    }

    BeforeEach {
        Mock Write-Host { }
        Mock Get-DevKitSettings { return [pscustomobject]@{ preferences = [pscustomobject]@{ confirmDestructive = $true } } }
        Mock Test-DevKitCanPrompt { return $true }
        Mock Read-Host { return 'y' }
    }

    It "proceeds without asking when the caller passed -Force" {
        Confirm-DevKitDestructiveAction -Action 'x' -Force | Should -BeTrue
        Should -Invoke Read-Host -Times 0
    }

    It "proceeds without asking when the user turned confirmations off" {
        Mock Get-DevKitSettings { return [pscustomobject]@{ preferences = [pscustomobject]@{ confirmDestructive = $false } } }
        Confirm-DevKitDestructiveAction -Action 'x' | Should -BeTrue
        Should -Invoke Read-Host -Times 0
    }

    It "refuses, without calling Read-Host, where nobody can answer" {
        # The Control Center runs tools -NonInteractive with stdin closed;
        # Read-Host throws there. Declining is the only safe answer.
        Mock Test-DevKitCanPrompt { return $false }
        Mock Read-Host { throw 'PowerShell is in NonInteractive mode' }
        Confirm-DevKitDestructiveAction -Action 'x' | Should -BeFalse
        Should -Invoke Read-Host -Times 0
    }

    It "proceeds on y and on nothing else" {
        Confirm-DevKitDestructiveAction -Action 'x' | Should -BeTrue
        Mock Read-Host { return '' }
        Confirm-DevKitDestructiveAction -Action 'x' | Should -BeFalse
        Mock Read-Host { return 'yes please' }
        Confirm-DevKitDestructiveAction -Action 'x' | Should -BeFalse
    }

    It "compares a typed phrase exactly, case included" {
        Mock Read-Host { return 'NUKE' }
        Confirm-DevKitDestructiveAction -Action 'x' -TypedPhrase 'NUKE' | Should -BeTrue
        Mock Read-Host { return 'nuke' }
        Confirm-DevKitDestructiveAction -Action 'x' -TypedPhrase 'NUKE' | Should -BeFalse
        Mock Read-Host { return 'y' }
        Confirm-DevKitDestructiveAction -Action 'x' -TypedPhrase 'NUKE' | Should -BeFalse
    }
}

Describe "Confirmation prompts in the tool scripts" {

    BeforeAll {
        $script:ToolFiles = @(Get-ChildItem -Path (Join-Path $script:RepoRoot 'tools') -Recurse -Filter '*.ps1' |
                Where-Object { $_.FullName -notmatch '\\tools\\lib\\' })
        function Get-ReadHostCalls {
            param([string]$FullName)
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($FullName, [ref]$null, [ref]$errors)
            return @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Read-Host' }, $true))
        }
    }

    It "finds the tool scripts" {
        $script:ToolFiles.Count | Should -BeGreaterThan 20
    }

    It "asks through Confirm-DevKitDestructiveAction, not a hand-rolled Read-Host" {
        # The scripts below ask something other than "may I do this
        # destructive thing": a per-item choice, "continue anyway?", "press
        # Enter". Each guards its own prompt against a session that cannot
        # answer (next test). Any OTHER script with a raw Read-Host is a new
        # hand-rolled confirmation: use the shared gate, which honours the
        # confirmDestructive setting and refuses safely when headless.
        $allowed = @(
            'Find-StaleNodeModules.ps1', 'Scan-Ports.ps1', 'Vite-DevFresh.ps1',
            'Vite-PreviewBuild.ps1', 'WiFi-Optimize.ps1', 'WiFi-Scan.ps1'
        )
        $offenders = @($script:ToolFiles | Where-Object { $_.Name -notin $allowed -and (Get-ReadHostCalls $_.FullName).Count -gt 0 } |
                ForEach-Object { $_.Name })
        $offenders | Should -BeNullOrEmpty
    }

    It "guards every remaining raw prompt against a session that cannot answer" {
        foreach ($file in $script:ToolFiles) {
            if ((Get-ReadHostCalls $file.FullName).Count -eq 0) { continue }
            $text = [System.IO.File]::ReadAllText($file.FullName)
            ($text -match 'Test-DevKitCanPrompt|IsInputRedirected') | Should -BeTrue -Because "$($file.Name) reads from the console"
        }
    }

    It "keeps Scan-Ports -Kill from reaching its per-process question when headless" {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'tools\ports\Scan-Ports.ps1'))
        $guard = $text.IndexOf('if ($Kill -and -not (Test-DevKitCanPrompt))')
        $ask = $text.IndexOf('Read-Host "  Kill PID')
        $guard | Should -BeGreaterThan -1
        $ask | Should -BeGreaterThan $guard
    }
}

Describe "Docker-Cleanup.ps1 reclaimable-space reading" {

    BeforeAll {
        $script:DockerCleanupText = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'tools\docker\Docker-Cleanup.ps1'))
        # The pattern the script applies to the "Build Cache" row of
        # 'docker system df', lifted out of the script so the test runs the
        # real one.
        $found = [regex]::Match($script:DockerCleanupText, '\$builderLine -match ''([^'']+)''')
        $found.Success | Should -BeTrue
        $script:BuilderPattern = $found.Groups[1].Value
    }

    It "reads the Build Cache row, which has no percentage" {
        # Verbatim row from Docker 29.9.3. The old pattern required "(nn%)",
        # never matched this row, and the cache always counted as zero.
        'Build Cache     61        0         1.448GB   668.4MB' -match $script:BuilderPattern | Should -BeTrue
        $Matches[1] | Should -Be '668.4MB'
    }

    It "still reads a row that does carry a percentage, and takes RECLAIMABLE, not SIZE" {
        'Build Cache     12        0         2.5GB     1.2GB (48%)' -match $script:BuilderPattern | Should -BeTrue
        $Matches[1] | Should -Be '1.2GB'
    }

    It "reads zero as zero" {
        'Build Cache     0         0         0B        0B' -match $script:BuilderPattern | Should -BeTrue
        $Matches[1] | Should -Be '0B'
    }

    It "does not present unused-image space as reclaimable in a mode that keeps those images" {
        $script:DockerCleanupText.Contains('Held by unused images: $reclaimable (kept in this mode; -AllUnused removes them)') | Should -BeTrue
    }

    It "names unused volumes in the dry run" {
        $script:DockerCleanupText.Contains('Unused volumes that would be removed') | Should -BeTrue
    }
}

Describe "prompts that ask whatever the confirmDestructive setting says" {

    BeforeAll {
        $global:DevKitCommonLoaded = $false
        . (Join-Path $script:RepoRoot 'tools\lib\DevKit-Common.ps1')
    }

    BeforeEach {
        Mock Write-Host { }
        Mock Get-DevKitSettings { return [pscustomobject]@{ preferences = [pscustomobject]@{ confirmDestructive = $false } } }
        Mock Test-DevKitCanPrompt { return $true }
        Mock Read-Host { return 'n' }
    }

    It "-Always asks even with the setting off, and a 'no' is a no" {
        Confirm-DevKitDestructiveAction -Always -Action 'x' | Should -BeFalse
        Should -Invoke Read-Host -Times 1 -Exactly
    }

    It "-Always still yields to -Force and still refuses where nobody can answer" {
        Confirm-DevKitDestructiveAction -Always -Force -Action 'x' | Should -BeTrue
        Should -Invoke Read-Host -Times 0
        Mock Test-DevKitCanPrompt { return $false }
        Confirm-DevKitDestructiveAction -Always -Action 'x' | Should -BeFalse
        Should -Invoke Read-Host -Times 0
    }

    It "is what every tool that used to ask unconditionally still does" {
        # These asked with a bare Read-Host before they moved to the shared
        # gate. Without -Always, turning confirmDestructive off would have
        # made "Kill Process by Port (With Confirmation)" kill without
        # asking, and Git Cleanup run every step it used to offer as a choice.
        $tools = @(
            'nextjs\Clear-NextCache.ps1', 'nextjs\Clear-TurboCache.ps1', 'nextjs\Next-FullClean.ps1',
            'node\Remove-NodeModules.ps1', 'node\Nuke-And-Reinstall.ps1',
            'ports\Kill-AllNode.ps1', 'ports\Kill-Port.ps1',
            'git\Git-SyncFork.ps1', 'git\Git-Cleanup.ps1', 'docker\Docker-Cleanup.ps1'
        )
        foreach ($tool in $tools) {
            $ast = Get-ScriptAst "tools\$tool"
            $calls = @($ast.FindAll({ param($n)
                        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Confirm-DevKitDestructiveAction' }, $true))
            $calls.Count | Should -BeGreaterThan 0 -Because "$tool confirms before acting"
            foreach ($call in $calls) { $call.Extent.Text | Should -Match ' -Always ' -Because "$tool asked unconditionally before" }
        }
    }
}

Describe "Docker-Nuke.ps1 treats an already-removed target as removed" {

    BeforeAll {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'tools\docker\Docker-Nuke.ps1'))
        $found = [regex]::Match($text, '\$alreadyGone = ''([^'']+)''')
        $found.Success | Should -BeTrue
        $script:AlreadyGone = $found.Groups[1].Value
        $script:NukeSource = $text
    }

    It "recognizes what docker says about a container, volume or image that is gone" {
        # 'docker stop' auto-removes a --rm container; the 'docker rm' that
        # follows then gets these. Verbatim Docker CLI wording.
        'Error response from daemon: No such container: 3f2a9c1b7d44' | Should -Match $script:AlreadyGone
        'Error response from daemon: removal of container 3f2a9c1b7d44 is already in progress' | Should -Match $script:AlreadyGone
        'Error response from daemon: get 05bd650a2102: no such volume' | Should -Match $script:AlreadyGone
        'Error response from daemon: No such image: abcdef012345' | Should -Match $script:AlreadyGone
    }

    It "does not swallow a real failure" {
        'Error response from daemon: remove myapp_pgdata: volume is in use - [5d1f]' | Should -Not -Match $script:AlreadyGone
        'Error response from daemon: conflict: unable to delete 1a2b3c (cannot be forced) - image has dependent child images' | Should -Not -Match $script:AlreadyGone
    }

    It "judges each removal by what is still there afterwards" {
        $script:NukeSource.Contains('$containersLeft = @(docker ps -aq 2>$null | Where-Object { $containers -contains $_ })') | Should -BeTrue
        $script:NukeSource.Contains('$volumesLeft = @(docker volume ls -q 2>$null | Where-Object { $volumes -contains $_ })') | Should -BeTrue
        $script:NukeSource.Contains('$imagesLeft = @(docker images -q 2>$null | Where-Object { $images -contains $_ })') | Should -BeTrue
    }
}

Describe "Docker-Cleanup.ps1 previews only the volumes it can remove" {

    BeforeAll {
        $script:CleanupSource = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'tools\docker\Docker-Cleanup.ps1'))
    }

    It "counts anonymous volumes only on Docker 23+, where 'volume prune' keeps named ones" {
        $script:CleanupSource.Contains('-f "label=com.docker.volume.anonymous"') | Should -BeTrue
        $script:CleanupSource.Contains('if ($dockerMajor -ge 23) {') | Should -BeTrue
    }

    It "lists volumes in the dry run only for -Volumes, the one mode that removes any" {
        $block = $script:CleanupSource.IndexOf('Unused volumes that would be removed')
        $gate = $script:CleanupSource.LastIndexOf('if ($Volumes) {', $block)
        $gate | Should -BeGreaterThan -1
        ($block - $gate) | Should -BeLessThan 200
        $script:CleanupSource.Contains('if ($Volumes -or $AllUnused) {') | Should -BeFalse
    }
}

Describe "Git-Cleanup.ps1 names the repository it acts on" {

    It "prints the repository root and flags it when it is not the folder given" {
        $ast = Get-ScriptAst 'tools\git\Git-Cleanup.ps1'
        @(Get-GitCalls -Ast $ast | Where-Object { $_.Text -match 'rev-parse --show-toplevel' }).Count | Should -Be 1
        $ast.Extent.Text.Contains('it is the repository that CONTAINS it') | Should -BeTrue
    }
}

Describe "the elevation task's settings" {

    # DevKit is started through the NorthstarDevKit-Admin scheduled task on
    # every launch. With Task Scheduler's defaults the app and everything it
    # spawns ran at below-normal CPU, low disk-I/O and low memory priority
    # (priority 7), and launching DevKit a second time did nothing at all
    # (MultipleInstances IgnoreNew). Both were measured on throwaway tasks.

    BeforeAll {
        . (Join-Path $script:RepoRoot 'tools\lib\DevKit-Common.ps1')

        function New-TestTask([int]$Priority, [string]$MultipleInstances) {
            return [pscustomobject]@{
                TaskName = 'NorthstarDevKit-Admin'
                Settings = [pscustomobject]@{ Priority = $Priority; MultipleInstances = $MultipleInstances }
                Triggers = @('logon')
            }
        }
    }

    It "asks for normal priority and for a second launch to be allowed to start" {
        $wanted = Get-DevKitElevationTaskSettings
        $wanted.Priority | Should -Be 4
        $wanted.MultipleInstances | Should -Be 'Parallel'
    }

    It "recognizes a current task and both ways of being out of date" {
        Test-DevKitElevationTaskSettingsCurrent -Priority 4 -MultipleInstances 'Parallel' | Should -BeTrue
        Test-DevKitElevationTaskSettingsCurrent -Priority 7 -MultipleInstances 'Parallel' | Should -BeFalse
        Test-DevKitElevationTaskSettingsCurrent -Priority 4 -MultipleInstances 'IgnoreNew' | Should -BeFalse
        Test-DevKitElevationTaskSettingsCurrent -Priority 7 -MultipleInstances 'IgnoreNew' | Should -BeFalse
    }

    It "repairs a task registered with the defaults, changing nothing else" {
        $script:Saved = $null
        Mock Get-ScheduledTask { return (New-TestTask 7 'IgnoreNew') }
        Mock Set-ScheduledTask { $script:Saved = $InputObject } -RemoveParameterType InputObject
        $result = Repair-DevKitElevationTaskSettings
        $result.status | Should -Be 'repaired'
        $result.priority | Should -Be 4
        $result.multipleInstances | Should -Be 'Parallel'
        $script:Saved.Settings.Priority | Should -Be 4
        $script:Saved.Settings.MultipleInstances | Should -Be 'Parallel'
        @($script:Saved.Triggers).Count | Should -Be 1     # the SAME object goes back, trigger and all
        Should -Invoke Set-ScheduledTask -Times 1 -Exactly
    }

    It "leaves a current task untouched" {
        Mock Get-ScheduledTask { return (New-TestTask 4 'Parallel') }
        Mock Set-ScheduledTask { throw 'a current task must not be written' }
        (Repair-DevKitElevationTaskSettings).status | Should -Be 'current'
        Should -Invoke Set-ScheduledTask -Times 0
    }

    It "answers 'absent' when there is no task (a dev build), without writing" {
        Mock Get-ScheduledTask { throw 'No MSFT_ScheduledTask objects found' }
        Mock Set-ScheduledTask { }
        $result = Repair-DevKitElevationTaskSettings
        $result.status | Should -Be 'absent'
        Should -Invoke Set-ScheduledTask -Times 0
    }

    It "reports 'failed' instead of throwing when the edit is refused (not elevated)" {
        Mock Get-ScheduledTask { return (New-TestTask 7 'IgnoreNew') }
        Mock Set-ScheduledTask { throw 'Access is denied.' } -RemoveParameterType InputObject
        { $script:RepairResult = Repair-DevKitElevationTaskSettings } | Should -Not -Throw
        $script:RepairResult.status | Should -Be 'failed'
        $script:RepairResult.message | Should -Match 'denied'
        # the values reported are the ones still in force
        $script:RepairResult.priority | Should -Be 7
    }

    It "registers new tasks with the same settings the repair applies" {
        $ast = Get-ScriptAst 'tools\system\Set-DevKitAdminMode.ps1'
        $calls = @($ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'New-ScheduledTaskSettingsSet' }, $true))
        $calls.Count | Should -Be 1
        $calls[0].Extent.Text | Should -Match '-Priority \$taskSettings\.Priority'
        $calls[0].Extent.Text | Should -Match '-MultipleInstances \$taskSettings\.MultipleInstances'
        $ast.Extent.Text.Contains('$taskSettings = Get-DevKitElevationTaskSettings') | Should -BeTrue
    }

    It "is reachable from the app as system.repairElevationTask" {
        $methods = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'core\RpcMethods.ps1'))
        $methods | Should -Match "'system\.repairElevationTask' \{"
        $hook = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'app\src\hooks\useElevationTaskRepair.ts'))
        $hook.Contains('"system.repairElevationTask"') | Should -BeTrue
    }
}

Describe "dev-server tools report a failed start" {

    # Next-DevFresh and Vite-DevFresh end by running the project's dev
    # server. Neither looked at how that ended, so a server that never came
    # up (no "dev" script, a config that does not load) finished as exit 0
    # and the app showed it as a success. These scripts start servers and
    # cannot be executed here; the property is read from the parsed script.

    BeforeDiscovery {
        $script:DevServerTools = @(
            @{ Script = 'tools\nextjs\Next-DevFresh.ps1' },
            @{ Script = 'tools\vite\Vite-DevFresh.ps1' }
        )
    }

    It "<Script> exits with the dev server's own code when it comes back with an error" -ForEach $script:DevServerTools {
        $ast = Get-ScriptAst $Script
        $launch = @($ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.InvocationOperator -eq 'Ampersand' -and
                    $n.Extent.Text -match '^& \$manager\.Command @devArgs' }, $true))
        $launch.Count | Should -Be 1

        # The first statement after the launch, in the same block.
        $block = $launch[0].Parent
        while ($block -and $block -isnot [System.Management.Automation.Language.StatementBlockAst] -and
            $block -isnot [System.Management.Automation.Language.NamedBlockAst]) { $block = $block.Parent }
        $after = @($block.Statements | Where-Object { $_.Extent.StartOffset -gt $launch[0].Extent.EndOffset }) | Select-Object -First 1
        $after | Should -Not -BeNullOrEmpty
        $after | Should -BeOfType ([System.Management.Automation.Language.IfStatementAst])
        $after.Extent.Text | Should -Match '\$LASTEXITCODE -ne 0'
        $after.Extent.Text | Should -Match 'exit \$LASTEXITCODE'
    }

    It "Next-DevFresh.ps1 does not end as a success when the start throws" {
        $ast = Get-ScriptAst 'tools\nextjs\Next-DevFresh.ps1'
        $catches = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true) |
                Where-Object { $_.Parent.Body.Extent.Text -match '& \$manager\.Command @devArgs' })
        $catches.Count | Should -Be 1
        $catches[0].Body.Extent.Text | Should -Match 'exit 1'
    }
}

Describe "Find-StaleNodeModules.ps1 measures how long the PROJECT has been idle" {

    # It used to show the age of the node_modules folder itself. That
    # timestamp only moves when a dependency is added or removed, so a
    # project worked on every day with unchanged dependencies was listed as
    # months old - in a tool whose next question is "delete these?".

    BeforeAll {
        $ast = Get-ScriptAst 'tools\node\Find-StaleNodeModules.ps1'
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-DevKitProjectLastActivity' }, $true)
        . ([scriptblock]::Create($fn.Extent.Text))

        function New-AgedProject {
            param([string]$Name, [hashtable]$DaysAgo)
            $project = Join-Path $TestDrive $Name
            $modules = Join-Path $project 'node_modules'
            $null = New-Item -ItemType Directory -Path $modules -Force
            # Create everything first, date it afterwards: creating a file
            # moves its folder's own timestamp to now.
            foreach ($relative in $DaysAgo.Keys) {
                if ($relative -eq 'node_modules') { continue }
                $full = Join-Path $project $relative
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force
                [System.IO.File]::WriteAllText($full, 'x')
            }
            foreach ($relative in $DaysAgo.Keys) {
                $full = if ($relative -eq 'node_modules') { $modules } else { Join-Path $project $relative }
                (Get-Item -LiteralPath $full -Force).LastWriteTime = (Get-Date).AddDays(-$DaysAgo[$relative])
            }
            return $modules
        }
        function Get-IdleDays { param([string]$Modules) [int][math]::Round(((Get-Date) - (Get-DevKitProjectLastActivity -NodeModulesPath $Modules)).TotalDays) }
    }

    It "calls a project idle for 0 days when it was committed to today, however old its node_modules is" {
        $modules = New-AgedProject 'active' @{ 'node_modules' = 200; 'package.json' = 200; '.git\logs\HEAD' = 0 }
        Get-IdleDays $modules | Should -Be 0
    }

    It "counts a recent install, by each package manager's own marker file" {
        Get-IdleDays (New-AgedProject 'npm' @{ 'node_modules' = 90; 'node_modules\.package-lock.json' = 3 }) | Should -Be 3
        Get-IdleDays (New-AgedProject 'pnpm' @{ 'node_modules' = 90; 'node_modules\.modules.yaml' = 4 }) | Should -Be 4
        Get-IdleDays (New-AgedProject 'yarn' @{ 'node_modules' = 90; 'node_modules\.yarn-integrity' = 5 }) | Should -Be 5
    }

    It "counts a package.json or lock file change" {
        Get-IdleDays (New-AgedProject 'pkg' @{ 'node_modules' = 90; 'package.json' = 7 }) | Should -Be 7
        Get-IdleDays (New-AgedProject 'lock' @{ 'node_modules' = 90; 'package.json' = 80; 'pnpm-lock.yaml' = 6 }) | Should -Be 6
    }

    It "still calls a project stale when nothing in it has moved" {
        $modules = New-AgedProject 'stale' @{ 'node_modules' = 150; 'package.json' = 160; 'package-lock.json' = 150; '.git\logs\HEAD' = 170; '.git\HEAD' = 170 }
        Get-IdleDays $modules | Should -Be 150
    }

    It "does not treat a refreshed .git\index as activity (git status rewrites it)" {
        $modules = New-AgedProject 'polled' @{ 'node_modules' = 120; '.git\index' = 0; '.git\logs\HEAD' = 120 }
        Get-IdleDays $modules | Should -Be 120
    }

    It "counts work in the repository a nested package belongs to (a monorepo)" {
        $modules = New-AgedProject 'mono\packages\web' @{ 'node_modules' = 100; 'package.json' = 100 }
        $repoLog = Join-Path $TestDrive 'mono\.git\logs\HEAD'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $repoLog) -Force
        [System.IO.File]::WriteAllText($repoLog, 'x')
        (Get-Item -LiteralPath $repoLog).LastWriteTime = (Get-Date).AddDays(-1)
        Get-IdleDays $modules | Should -Be 1
    }

    It "works for a project folder with brackets in its name" {
        Get-IdleDays (New-AgedProject 'app [v2]' @{ 'node_modules' = 60; 'package.json' = 2 }) | Should -Be 2
    }

    It "is what the report's age column is computed from" {
        $text = (Get-ScriptAst 'tools\node\Find-StaleNodeModules.ps1').Extent.Text
        $text | Should -Match 'Get-DevKitProjectLastActivity -NodeModulesPath \$dir\.FullName'
        $text | Should -Match 'AgeDays\s+= \[int\]\[math\]::Round\(\(\(Get-Date\) - \$lastActivity\)\.TotalDays\)'
    }
}
