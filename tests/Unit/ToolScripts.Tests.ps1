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
