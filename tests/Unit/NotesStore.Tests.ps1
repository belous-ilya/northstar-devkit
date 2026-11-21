#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for the widget's per-project sticky-notes store
    (Get/Save-DevKitProjectNotes in core/DevKit-WidgetCore.ps1)
.DESCRIPTION
    Exercises the JSON round-trip against a temp store file: array-shape
    guarantees (including the single-note member-unroll trap), project key
    canonicalization, cross-project isolation on save, empty-list pruning,
    and the corrupt-store recovery posture.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    # See Get-DevKitPackageManager.Tests.ps1 for why these load-once flags
    # get reset when several test files share one Pester process.
    $global:DevKitCommonLoaded = $false
    . (Join-Path $script:RepoRoot 'tools\lib\DevKit-Common.ps1')
    $global:DevKitWidgetCoreLoaded = $false
    . (Join-Path $script:RepoRoot 'core\DevKit-WidgetCore.ps1')

    function New-TestNote {
        param([string]$Text, [string]$Color = 'amber')
        return [PSCustomObject]@{
            Id        = [guid]::NewGuid().ToString('N')
            Text      = $Text
            Color     = $Color
            UpdatedAt = [DateTime]::UtcNow.ToString('o')
        }
    }
}

Describe "Get-DevKitNotesProjectKey" {

    It "canonicalizes trailing separators and casing to one key" {
        $a = Get-DevKitNotesProjectKey -ProjectPath 'D:\Work\MyApp\'
        $b = Get-DevKitNotesProjectKey -ProjectPath 'd:\work\myapp'
        $a | Should -Be $b
    }
}

Describe "Get-DevKitProjectNotes" {

    BeforeEach {
        $script:StoreFile = Join-Path $TestDrive "notes-$([guid]::NewGuid().ToString('N')).json"
    }

    It "returns an empty array when the store file does not exist" {
        $r = @(Get-DevKitProjectNotes -ProjectPath 'D:\Work\MyApp' -NotesFile $script:StoreFile)
        $r.Count | Should -Be 0
    }

    It "returns an empty array for a project with no saved notes" {
        Save-DevKitProjectNotes -ProjectPath 'D:\Other' -Notes @((New-TestNote 'x')) -NotesFile $script:StoreFile
        $r = @(Get-DevKitProjectNotes -ProjectPath 'D:\Work\MyApp' -NotesFile $script:StoreFile)
        $r.Count | Should -Be 0
    }

    It "returns an empty array (not a crash) for a corrupt store file" {
        Set-Content -LiteralPath $script:StoreFile -Value '{ not valid json !!'
        $r = @(Get-DevKitProjectNotes -ProjectPath 'D:\Work\MyApp' -NotesFile $script:StoreFile)
        $r.Count | Should -Be 0
    }
}

Describe "Save-DevKitProjectNotes round-trip" {

    BeforeEach {
        $script:StoreFile = Join-Path $TestDrive "notes-$([guid]::NewGuid().ToString('N')).json"
    }

    It "round-trips notes preserving order, ids, colors, and text" {
        $notes = @((New-TestNote 'first' 'amber'), (New-TestNote "second`nmultiline" 'blue'))
        Save-DevKitProjectNotes -ProjectPath 'D:\Work\MyApp' -Notes $notes -NotesFile $script:StoreFile
        $r = @(Get-DevKitProjectNotes -ProjectPath 'D:\Work\MyApp' -NotesFile $script:StoreFile)
        $r.Count | Should -Be 2
        $r[0].Id | Should -Be $notes[0].Id
        $r[0].Text | Should -Be 'first'
        $r[0].Color | Should -Be 'amber'
        $r[1].Text | Should -Be "second`nmultiline"
        $r[1].Color | Should -Be 'blue'
    }

    It "keeps a SINGLE saved note as an array through a second save cycle" {
        # ConvertFrom-Json member access unrolls one-element arrays; a lone
        # note must not round-trip into a bare object when an unrelated
        # project's save rewrites the store around it.
        Save-DevKitProjectNotes -ProjectPath 'D:\Solo' -Notes @((New-TestNote 'only note')) -NotesFile $script:StoreFile
        Save-DevKitProjectNotes -ProjectPath 'D:\Other' -Notes @((New-TestNote 'elsewhere')) -NotesFile $script:StoreFile
        $r = @(Get-DevKitProjectNotes -ProjectPath 'D:\Solo' -NotesFile $script:StoreFile)
        $r.Count | Should -Be 1
        $r[0].Text | Should -Be 'only note'
    }

    It "does not disturb other projects' notes when saving one project" {
        Save-DevKitProjectNotes -ProjectPath 'D:\A' -Notes @((New-TestNote 'a-note')) -NotesFile $script:StoreFile
        Save-DevKitProjectNotes -ProjectPath 'D:\B' -Notes @((New-TestNote 'b-note')) -NotesFile $script:StoreFile
        Save-DevKitProjectNotes -ProjectPath 'D:\A' -Notes @((New-TestNote 'a-rewritten')) -NotesFile $script:StoreFile
        $b = @(Get-DevKitProjectNotes -ProjectPath 'D:\B' -NotesFile $script:StoreFile)
        $b.Count | Should -Be 1
        $b[0].Text | Should -Be 'b-note'
        $a = @(Get-DevKitProjectNotes -ProjectPath 'D:\A' -NotesFile $script:StoreFile)
        $a.Count | Should -Be 1
        $a[0].Text | Should -Be 'a-rewritten'
    }

    It "reads back through a differently-cased path with a trailing slash" {
        Save-DevKitProjectNotes -ProjectPath 'D:\Work\MyApp' -Notes @((New-TestNote 'hello')) -NotesFile $script:StoreFile
        $r = @(Get-DevKitProjectNotes -ProjectPath 'd:\WORK\myapp\' -NotesFile $script:StoreFile)
        $r.Count | Should -Be 1
        $r[0].Text | Should -Be 'hello'
    }

    It "removes a project's entry entirely when saved with an empty list" {
        Save-DevKitProjectNotes -ProjectPath 'D:\Work\MyApp' -Notes @((New-TestNote 'temp')) -NotesFile $script:StoreFile
        Save-DevKitProjectNotes -ProjectPath 'D:\Work\MyApp' -Notes @() -NotesFile $script:StoreFile
        $raw = Get-Content -LiteralPath $script:StoreFile -Raw | ConvertFrom-Json
        @($raw.projects.PSObject.Properties).Count | Should -Be 0
    }

    It "recovers from a corrupt store by rebuilding it around the new save" {
        Set-Content -LiteralPath $script:StoreFile -Value 'garbage {{{{'
        Save-DevKitProjectNotes -ProjectPath 'D:\Work\MyApp' -Notes @((New-TestNote 'fresh')) -NotesFile $script:StoreFile
        $r = @(Get-DevKitProjectNotes -ProjectPath 'D:\Work\MyApp' -NotesFile $script:StoreFile)
        $r.Count | Should -Be 1
        $r[0].Text | Should -Be 'fresh'
    }

    It "creates the parent directory when missing" {
        $nested = Join-Path $TestDrive "sub\dir\notes.json"
        Save-DevKitProjectNotes -ProjectPath 'D:\Work\MyApp' -Notes @((New-TestNote 'deep')) -NotesFile $nested
        Test-Path -LiteralPath $nested | Should -BeTrue
    }

    It "keeps a copy of a corrupt store before rebuilding it" {
        # A rebuild throws away every OTHER project's notes. That is only
        # acceptable when the bytes it replaces are still on disk somewhere.
        Set-Content -LiteralPath $script:StoreFile -Value 'garbage {{{{'
        Save-DevKitProjectNotes -ProjectPath 'D:\Work\MyApp' -Notes @((New-TestNote 'fresh')) -NotesFile $script:StoreFile
        $copies = @(Get-ChildItem -LiteralPath (Split-Path -Parent $script:StoreFile) -Filter ((Split-Path -Leaf $script:StoreFile) + '.corrupt-*'))
        $copies.Count | Should -Be 1
        (Get-Content -LiteralPath $copies[0].FullName -Raw) | Should -Match 'garbage'
    }

    It "refuses to overwrite a store it cannot read, so other projects' notes survive" {
        # The data-loss path this guards: the store exists but the read fails
        # (antivirus or a sync client holding it, a write still in flight).
        # Treating that like "empty store" and saving rewrote the file with
        # ONLY the project being saved - every other project's notes gone.
        #
        # The READ is faulted through its seam rather than with a real file
        # lock: a lock would block the write too, and the test would pass
        # against the broken code for the wrong reason.
        Save-DevKitProjectNotes -ProjectPath 'D:\A' -Notes @((New-TestNote 'a-note')) -NotesFile $script:StoreFile
        $before = [System.IO.File]::ReadAllText($script:StoreFile)
        Mock Read-DevKitProjectStoreText { throw [System.IO.IOException]::new('being used by another process') }
        { Save-DevKitProjectNotes -ProjectPath 'D:\B' -Notes @((New-TestNote 'b-note')) -NotesFile $script:StoreFile } | Should -Throw
        [System.IO.File]::ReadAllText($script:StoreFile) | Should -Be $before
        $a = @(Get-DevKitProjectNotes -ProjectPath 'D:\A' -NotesFile $script:StoreFile)
        $a.Count | Should -Be 1
        $a[0].Text | Should -Be 'a-note'
    }

    It "leaves no temp file behind after a save" {
        Save-DevKitProjectNotes -ProjectPath 'D:\A' -Notes @((New-TestNote 'one')) -NotesFile $script:StoreFile
        Save-DevKitProjectNotes -ProjectPath 'D:\A' -Notes @((New-TestNote 'two')) -NotesFile $script:StoreFile
        $leaf = Split-Path -Leaf $script:StoreFile
        $siblings = @(Get-ChildItem -LiteralPath (Split-Path -Parent $script:StoreFile) | Where-Object { $_.Name -like "$leaf*" })
        $siblings.Count | Should -Be 1
    }
}

Describe "Save-DevKitProjectOnDeck store safety" {

    BeforeEach {
        $script:DeckFile = Join-Path $TestDrive "ondeck-$([guid]::NewGuid().ToString('N')).json"
        $script:DeckItem = [PSCustomObject]@{ Id = 'i1'; Text = 'ship it'; Status = 'todo'; UpdatedAt = [DateTime]::UtcNow.ToString('o') }
    }

    It "refuses to overwrite a store it cannot read, so other projects' items survive" {
        Save-DevKitProjectOnDeck -ProjectPath 'D:\A' -Items @($script:DeckItem) -OnDeckFile $script:DeckFile
        $before = [System.IO.File]::ReadAllText($script:DeckFile)
        Mock Read-DevKitProjectStoreText { throw [System.IO.IOException]::new('being used by another process') }
        { Save-DevKitProjectOnDeck -ProjectPath 'D:\B' -Items @($script:DeckItem) -OnDeckFile $script:DeckFile } | Should -Throw
        [System.IO.File]::ReadAllText($script:DeckFile) | Should -Be $before
    }

    It "really does retry and then throw when the file stays locked" {
        # The un-mocked read, against a genuine exclusive lock.
        Save-DevKitProjectOnDeck -ProjectPath 'D:\A' -Items @($script:DeckItem) -OnDeckFile $script:DeckFile
        $lock = [System.IO.File]::Open($script:DeckFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        try {
            { Read-DevKitProjectStoreText -Path $script:DeckFile } | Should -Throw -ExpectedMessage '*nothing was saved*'
        } finally {
            $lock.Dispose()
        }
        Read-DevKitProjectStoreText -Path $script:DeckFile | Should -Match 'ship it'
    }

    It "keeps a copy of a corrupt store before rebuilding it" {
        Set-Content -LiteralPath $script:DeckFile -Value '{ not json'
        Save-DevKitProjectOnDeck -ProjectPath 'D:\A' -Items @($script:DeckItem) -OnDeckFile $script:DeckFile
        $copies = @(Get-ChildItem -LiteralPath (Split-Path -Parent $script:DeckFile) -Filter ((Split-Path -Leaf $script:DeckFile) + '.corrupt-*'))
        $copies.Count | Should -Be 1
        @(Get-DevKitProjectOnDeck -ProjectPath 'D:\A' -OnDeckFile $script:DeckFile).Count | Should -Be 1
    }
}

Describe "store encoding and shape" {

    BeforeEach {
        $script:StoreFile = Join-Path $TestDrive "notes-$([guid]::NewGuid().ToString('N')).json"
    }

    It "round-trips non-ASCII text exactly" {
        # The store is written as UTF-8 without a BOM. The readers must
        # decode it the same way: Windows PowerShell 5.1's Get-Content reads
        # a BOM-less file as ANSI, and the mojibake would then be saved back.
        # Built from code points so this test file's own encoding is not
        # part of the test.
        $text = "caf$([char]0x00E9) $([char]0x2014) $([char]0x043F)$([char]0x0440)$([char]0x0438)$([char]0x0432)$([char]0x0435)$([char]0x0442)"
        Save-DevKitProjectNotes -ProjectPath 'D:\A' -Notes @((New-TestNote $text)) -NotesFile $script:StoreFile
        $r = @(Get-DevKitProjectNotes -ProjectPath 'D:\A' -NotesFile $script:StoreFile)
        $r[0].Text | Should -Be $text
        # And on disk it is real UTF-8 with no BOM.
        $bytes = [System.IO.File]::ReadAllBytes($script:StoreFile)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        [System.Text.Encoding]::UTF8.GetString($bytes) | Should -Match ([regex]::Escape($text))
    }

    It "copies aside a store that is valid JSON of the wrong shape before rebuilding it" {
        Set-Content -LiteralPath $script:StoreFile -Value '{ "notes": [ "from some other tool" ] }'
        Save-DevKitProjectNotes -ProjectPath 'D:\A' -Notes @((New-TestNote 'fresh')) -NotesFile $script:StoreFile
        $copies = @(Get-ChildItem -LiteralPath (Split-Path -Parent $script:StoreFile) -Filter ((Split-Path -Leaf $script:StoreFile) + '.corrupt-*'))
        $copies.Count | Should -Be 1
        (Get-Content -LiteralPath $copies[0].FullName -Raw) | Should -Match 'from some other tool'
    }

    It "does not copy aside an empty but well-formed store" {
        Save-DevKitProjectNotes -ProjectPath 'D:\A' -Notes @((New-TestNote 'x')) -NotesFile $script:StoreFile
        Save-DevKitProjectNotes -ProjectPath 'D:\A' -Notes @() -NotesFile $script:StoreFile
        Save-DevKitProjectNotes -ProjectPath 'D:\B' -Notes @((New-TestNote 'y')) -NotesFile $script:StoreFile
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $script:StoreFile) -Filter ((Split-Path -Leaf $script:StoreFile) + '.corrupt-*')).Count | Should -Be 0
    }
}

Describe "date-looking text survives the stores" {

    # PowerShell 7's ConvertFrom-Json turns any string shaped like an ISO
    # date into a [datetime]; the readers then cast it with [string], which
    # gives "11/21/2026 10:00:00" - zone lost, an offset stamp shifted to
    # local time - and the next save wrote that back for good. Windows
    # PowerShell 5.1 never converted, so these pass there either way; on 7
    # they failed before Get-DevKitJsonReadArgs / ConvertTo-DevKitStoredText.

    BeforeEach {
        $script:DateNotesFile = Join-Path $TestDrive "notes-dates-$([guid]::NewGuid().ToString('N')).json"
        $script:DateDeckFile = Join-Path $TestDrive "ondeck-dates-$([guid]::NewGuid().ToString('N')).json"
        $script:Stamp = '2026-11-21T10:00:00.0000000Z'
        $script:DateText = '2026-11-21T10:00:00+02:00'
    }

    It "keeps a note's timestamp and a timestamp-shaped note exactly as written, across save -> read -> save -> read" {
        $note = [PSCustomObject]@{ Id = 'n1'; Text = $script:DateText; Color = 'amber'; UpdatedAt = $script:Stamp }
        Save-DevKitProjectNotes -ProjectPath 'D:\A' -Notes @($note) -NotesFile $script:DateNotesFile
        $first = @(Get-DevKitProjectNotes -ProjectPath 'D:\A' -NotesFile $script:DateNotesFile)
        $first[0].Text | Should -BeExactly $script:DateText
        $first[0].UpdatedAt | Should -BeExactly $script:Stamp
        Save-DevKitProjectNotes -ProjectPath 'D:\A' -Notes $first -NotesFile $script:DateNotesFile
        $second = @(Get-DevKitProjectNotes -ProjectPath 'D:\A' -NotesFile $script:DateNotesFile)
        $second[0].Text | Should -BeExactly $script:DateText
        $second[0].UpdatedAt | Should -BeExactly $script:Stamp
        [System.IO.File]::ReadAllText($script:DateNotesFile) | Should -Not -Match '11/21/2026'
    }

    It "leaves ANOTHER project's timestamps alone when one project saves" {
        $other = [PSCustomObject]@{ Id = 'o1'; Text = $script:DateText; Color = 'amber'; UpdatedAt = $script:Stamp }
        Save-DevKitProjectNotes -ProjectPath 'D:\Other' -Notes @($other) -NotesFile $script:DateNotesFile
        $mine = [PSCustomObject]@{ Id = 'm1'; Text = 'plain'; Color = 'amber'; UpdatedAt = $script:Stamp }
        Save-DevKitProjectNotes -ProjectPath 'D:\Mine' -Notes @($mine) -NotesFile $script:DateNotesFile
        $back = @(Get-DevKitProjectNotes -ProjectPath 'D:\Other' -NotesFile $script:DateNotesFile)
        $back[0].Text | Should -BeExactly $script:DateText
        $back[0].UpdatedAt | Should -BeExactly $script:Stamp
    }

    It "keeps an On-Deck item's timestamp and timestamp-shaped text exactly as written" {
        $item = [PSCustomObject]@{ Id = 'i1'; Text = $script:DateText; Status = 'todo'; UpdatedAt = $script:Stamp }
        Save-DevKitProjectOnDeck -ProjectPath 'D:\A' -Items @($item) -OnDeckFile $script:DateDeckFile
        $first = @(Get-DevKitProjectOnDeck -ProjectPath 'D:\A' -OnDeckFile $script:DateDeckFile)
        Save-DevKitProjectOnDeck -ProjectPath 'D:\A' -Items $first -OnDeckFile $script:DateDeckFile
        $second = @(Get-DevKitProjectOnDeck -ProjectPath 'D:\A' -OnDeckFile $script:DateDeckFile)
        $second[0].Text | Should -BeExactly $script:DateText
        $second[0].UpdatedAt | Should -BeExactly $script:Stamp
    }

    It "writes a value that arrives as a DateTime back as ISO text, never culture-style" {
        # What an RPC request parsed by PowerShell 7.0 - 7.4 hands the writer.
        $asDate = [datetime]::new(2026, 11, 21, 10, 0, 0, [System.DateTimeKind]::Utc)
        ConvertTo-DevKitStoredText $asDate | Should -BeExactly '2026-11-21T10:00:00.0000000Z'
        ConvertTo-DevKitStoredText 'plain text' | Should -BeExactly 'plain text'
        ConvertTo-DevKitStoredText $null | Should -BeExactly ''
        $note = [PSCustomObject]@{ Id = 'n1'; Text = 'x'; Color = 'amber'; UpdatedAt = $asDate }
        Save-DevKitProjectNotes -ProjectPath 'D:\A' -Notes @($note) -NotesFile $script:DateNotesFile
        [System.IO.File]::ReadAllText($script:DateNotesFile) | Should -Match '"updatedAt":\s*"2026-11-21T10:00:00\.0000000Z"'
    }

    It "asks ConvertFrom-Json to keep date strings wherever this PowerShell can" {
        $jsonArgs = Get-DevKitJsonReadArgs
        $jsonArgs | Should -BeOfType [hashtable]
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
            $jsonArgs.DateKind | Should -Be 'String'
            ('{"t":"2026-11-21T10:00:00+02:00"}' | ConvertFrom-Json @jsonArgs).t | Should -BeOfType [string]
        } else {
            $jsonArgs.Count | Should -Be 0
        }
    }

    It "parses RPC request lines the same way" {
        $sidecar = Join-Path $script:RepoRoot 'core\Invoke-DevKitRpc.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($sidecar, [ref]$null, [ref]$null)
        $parses = @($ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'ConvertFrom-Json' }, $true))
        $parses.Count | Should -BeGreaterThan 0
        foreach ($call in $parses) { $call.Extent.Text | Should -Match '@script:RequestJsonArgs' }
        [System.IO.File]::ReadAllText($sidecar) | Should -Match "RequestJsonArgs = @\{ DateKind = 'String' \}"
    }
}
