#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for the update-time cleanup: core/ShippedFiles.txt,
    core/RemovedFiles.txt, core/Export-ShippedFiles.ps1 and
    core/Remove-StaleInstallFiles.ps1.
.DESCRIPTION
    The installer only adds and overwrites, so a script a release deletes
    used to stay in every install that updated - and DevKit builds its
    catalog from the manifests on disk, so the removed tool stayed listed.
    After installing, the installer now runs Remove-StaleInstallFiles.ps1,
    which deletes the files named in RemovedFiles.txt: paths an earlier
    DevKit release shipped and this one does not.

    What is pinned here: the lists matching the tree and the release
    history, and - above all - that the cleanup deletes NOTHING it was not
    told a DevKit release once shipped. The install folder is whatever the
    user picked; a tools\ or core\ directory there may hold files that were
    never DevKit's. Every run in this file is against a throwaway folder
    under TestDrive.
.NOTES
    Pester 5 syntax.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:CleanupScript = Join-Path $script:RepoRoot 'core\Remove-StaleInstallFiles.ps1'
    $script:ShippedPath = Join-Path $script:RepoRoot 'core\ShippedFiles.txt'
    $script:RemovedPath = Join-Path $script:RepoRoot 'core\RemovedFiles.txt'
    # Dot-sourced: both scripts define their functions and run nothing.
    . $script:CleanupScript -InstallRoot 'unused'
    . (Join-Path $script:RepoRoot 'core\Export-ShippedFiles.ps1')

    function Get-ListEntries([string]$Path) {
        return @([System.IO.File]::ReadAllLines($Path) | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    }

    # A folder that looks like an installed DevKit: every shipped file exists
    # (empty - only names matter), plus both lists with their real content.
    function New-FakeInstall {
        $root = Join-Path $TestDrive "install-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        foreach ($entry in (Get-ListEntries $script:ShippedPath)) {
            $target = Join-Path $root $entry
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force)
            [System.IO.File]::WriteAllText($target, '')
        }
        Copy-Item -LiteralPath $script:ShippedPath -Destination (Join-Path $root 'core\ShippedFiles.txt') -Force
        Copy-Item -LiteralPath $script:RemovedPath -Destination (Join-Path $root 'core\RemovedFiles.txt') -Force
        return $root
    }

    function Add-File([string]$Root, [string]$Relative, [switch]$ReadOnly) {
        $target = Join-Path $Root $Relative
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force)
        [System.IO.File]::WriteAllText($target, 'old')
        if ($ReadOnly) { (Get-Item -LiteralPath $target).IsReadOnly = $true }
        return $target
    }

    function Get-AllFiles([string]$Root) {
        return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($Root.Length + 1).ToLowerInvariant() } | Sort-Object)
    }
}

Describe "core/ShippedFiles.txt matches what the installer ships" {

    BeforeAll {
        $script:Listed = @(Get-ListEntries $script:ShippedPath | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
        $script:OnDisk = @(foreach ($folder in 'core', 'tools') {
                Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot $folder) -Recurse -File -Force |
                    ForEach-Object { $_.FullName.Substring($script:RepoRoot.Length + 1).ToLowerInvariant() }
            }) | Sort-Object
    }

    It "names every file under core\ and tools\" {
        $missing = @($script:OnDisk | Where-Object { $script:Listed -notcontains $_ })
        $missing | Should -BeNullOrEmpty -Because 'run core/Export-ShippedFiles.ps1 after adding or renaming a file'
    }

    It "names nothing that is not there (this is what forces a deletion to be recorded)" {
        # A deleted file leaves its line behind until Export-ShippedFiles.ps1
        # is run - and running it is what adds the path to RemovedFiles.txt.
        $extra = @($script:Listed | Where-Object { $script:OnDisk -notcontains $_ })
        $extra | Should -BeNullOrEmpty -Because 'run core/Export-ShippedFiles.ps1 after deleting or renaming a file'
    }

    It "names itself, the removed list, the cleanup script and the files the cleanup requires" {
        foreach ($required in 'core\shippedfiles.txt', 'core\removedfiles.txt', 'core\remove-staleinstallfiles.ps1', 'core\devkit.core.psm1', 'tools\lib\devkit-common.ps1') {
            $script:Listed | Should -Contain $required
        }
        foreach ($required in $script:RequiredShippedEntries) { $script:Listed | Should -Contain $required.ToLowerInvariant() }
    }

    It "is long enough to pass the cleanup's own plausibility floor, with room to spare" {
        $script:Listed.Count | Should -BeGreaterThan ($script:MinimumShippedEntries + 20)
    }
}

Describe "core/RemovedFiles.txt names what earlier releases shipped and this one does not" {

    BeforeAll {
        $script:Removed = @(Get-ListEntries $script:RemovedPath)
        $script:ShippedNow = @(Get-ListEntries $script:ShippedPath | ForEach-Object { $_.ToLowerInvariant() })
    }

    It "never names a file that ships now (that would delete it on every update)" {
        $both = @($script:Removed | Where-Object { $script:ShippedNow -contains $_.ToLowerInvariant() })
        $both | Should -BeNullOrEmpty
    }

    It "names only plain paths inside core\ or tools\" {
        foreach ($entry in $script:Removed) {
            Test-DevKitManagedRelativePath $entry | Should -BeTrue -Because "'$entry' must be a relative path under core\ or tools\"
        }
    }

    It "covers the categories this release removed" {
        foreach ($expected in 'tools\maintenance\_module.psd1', 'tools\agents\_module.psd1', 'tools\system\_module.psd1',
            'tools\workflow\_module.psd1', 'tools\diagnostics\_module.psd1', 'tools\lib\DevKit-McpCatalog.ps1') {
            $script:Removed | Should -Contain $expected
        }
    }

    It "covers every core\ and tools\ file of every release tag that is gone from the tree" {
        $git = Get-Command git -ErrorAction SilentlyContinue
        $tags = @()
        if ($git) { $tags = @(& git -C $script:RepoRoot tag --list 'v*' 2>$null) }
        if ($tags.Count -eq 0) {
            Set-ItResult -Skipped -Because 'no release tags in this clone (a shallow checkout)'
            return
        }
        $removedSet = @($script:Removed | ForEach-Object { $_.ToLowerInvariant() })
        $uncovered = @(foreach ($tag in $tags) {
                & git -C $script:RepoRoot ls-tree -r --name-only $tag -- core tools | ForEach-Object { ($_ -replace '/', '\').ToLowerInvariant() }
            }) | Sort-Object -Unique | Where-Object { $script:ShippedNow -notcontains $_ -and $removedSet -notcontains $_ }
        $uncovered | Should -BeNullOrEmpty -Because 'run core/Export-ShippedFiles.ps1 -SeedFromTags'
    }
}

Describe "Get-DevKitRemovedFileList (how a deletion gets remembered)" {

    It "adds what the previous shipped list named and the tree no longer has" {
        $result = Get-DevKitRemovedFileList -PreviousRemoved @('tools\old\a.ps1') -PreviousShipped @('core\x.ps1', 'tools\gone\b.ps1') -NowShipped @('core\x.ps1')
        $result | Should -Be @('tools\gone\b.ps1', 'tools\old\a.ps1')
    }

    It "takes a path off the list when it ships again" {
        $result = Get-DevKitRemovedFileList -PreviousRemoved @('tools\back\a.ps1', 'tools\old\b.ps1') -PreviousShipped @() -NowShipped @('tools\back\a.ps1')
        $result | Should -Be @('tools\old\b.ps1')
    }

    It "is case-insensitive, accepts either slash, and never lists a path twice" {
        $result = Get-DevKitRemovedFileList -PreviousRemoved @('tools\Old\A.ps1') -PreviousShipped @('tools/old/a.ps1', 'CORE\Keep.ps1') -NowShipped @('core\keep.ps1')
        @($result).Count | Should -Be 1
    }

    It "keeps nothing outside core\ and tools\, whatever it is handed" {
        $result = Get-DevKitRemovedFileList -PreviousRemoved @('app\src\x.ts', '..\outside.txt', 'C:\Windows\x.dll') -PreviousShipped @('README.md') -NowShipped @() -Historical @('gui\Old.ps1', 'tools\was\here.ps1')
        $result | Should -Be @('tools\was\here.ps1')
    }
}

Describe "Remove-StaleInstallFiles.ps1" {

    It "removes the files an earlier release left behind, and the folders they emptied" {
        $root = New-FakeInstall
        $before = Get-AllFiles $root
        [void](Add-File $root 'tools\maintenance\_module.psd1')
        [void](Add-File $root 'tools\maintenance\Clear-DiskJunk.ps1')
        [void](Add-File $root 'tools\agents\Add-McpServer.ps1')
        [void](Add-File $root 'tools\system\Edit-Path.ps1')
        [void](Add-File $root 'tools\lib\DevKit-McpCatalog.ps1' -ReadOnly)

        $result = Invoke-DevKitStaleInstallCleanup -Root $root
        $result.Stale | Should -Be 5
        $result.Removed | Should -Be 5
        $result.Failed | Should -Be 0
        (Get-AllFiles $root) | Should -Be $before
        Test-Path -LiteralPath (Join-Path $root 'tools\maintenance') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root 'tools\agents') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root 'tools\system') | Should -BeTrue     # still holds a shipped file
        Test-Path -LiteralPath (Join-Path $root 'tools\lib') | Should -BeTrue
    }

    It "is what makes a removed category disappear from the catalog" {
        $root = New-FakeInstall
        foreach ($folder in 'maintenance', 'agents', 'workflow', 'diagnostics') { [void](Add-File $root "tools\$folder\_module.psd1") }
        [void](Invoke-DevKitStaleInstallCleanup -Root $root)
        $manifests = @(Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Recurse -Filter '_module.psd1' | ForEach-Object { $_.Directory.Name })
        $manifests.Count | Should -Be 7
        $manifests | Should -Not -Contain 'maintenance'
    }

    It "does NOT delete a file DevKit never shipped, even inside tools\ and core\" {
        # The install folder is whatever the user chose. If it already had a
        # tools\ directory of their own, or they dropped files into DevKit's,
        # those are not ours: an earlier draft deleted "everything not on the
        # shipped list" and would have wiped them.
        $root = New-FakeInstall
        $theirs1 = Add-File $root 'tools\my-own-script.ps1'
        $theirs2 = Add-File $root 'tools\my-stuff\notes.txt'
        $theirs3 = Add-File $root 'core\local-experiment.ps1'
        $theirs4 = Add-File $root 'tools\ports\My-Extra-Port-Tool.ps1'
        [void](Add-File $root 'tools\maintenance\_module.psd1')

        $result = Invoke-DevKitStaleInstallCleanup -Root $root
        $result.Removed | Should -Be 1
        foreach ($kept in $theirs1, $theirs2, $theirs3, $theirs4) { Test-Path -LiteralPath $kept | Should -BeTrue }
    }

    It "keeps a folder that still holds something of the user's" {
        $root = New-FakeInstall
        [void](Add-File $root 'tools\maintenance\_module.psd1')
        $theirs = Add-File $root 'tools\maintenance\my-notes.txt'
        [void](Invoke-DevKitStaleInstallCleanup -Root $root)
        Test-Path -LiteralPath $theirs | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $root 'tools\maintenance\_module.psd1') | Should -BeFalse
    }

    It "touches nothing outside core\ and tools\" {
        $root = New-FakeInstall
        $keep1 = Add-File $root 'devkit-app.exe'
        $keep2 = Add-File $root 'notes\tools\maintenance\_module.psd1'
        $keep3 = Add-File $root 'uninstall.exe'
        [void](Add-File $root 'tools\maintenance\x.ps1')
        [void](Invoke-DevKitStaleInstallCleanup -Root $root)
        foreach ($kept in $keep1, $keep2, $keep3) { Test-Path -LiteralPath $kept | Should -BeTrue }
    }

    It "leaves a clean install exactly as it is" {
        $root = New-FakeInstall
        $before = Get-AllFiles $root
        $result = Invoke-DevKitStaleInstallCleanup -Root $root
        $result.Stale | Should -Be 0
        (Get-AllFiles $root) | Should -Be $before
    }

    It "lists but deletes nothing with -DryRun" {
        $root = New-FakeInstall
        $stale = Add-File $root 'tools\maintenance\_module.psd1'
        $result = Invoke-DevKitStaleInstallCleanup -Root $root -DryRun
        $result.Stale | Should -Be 1
        $result.Removed | Should -Be 0
        @($result.Files) | Should -Contain $stale
        Test-Path -LiteralPath $stale | Should -BeTrue
    }

    It "deletes nothing when either list is missing" {
        $root = New-FakeInstall
        $stale = Add-File $root 'tools\maintenance\_module.psd1'
        Remove-Item -LiteralPath (Join-Path $root 'core\RemovedFiles.txt')
        (Invoke-DevKitStaleInstallCleanup -Root $root).Stale | Should -Be 0
        Copy-Item -LiteralPath $script:RemovedPath -Destination (Join-Path $root 'core\RemovedFiles.txt')
        Remove-Item -LiteralPath (Join-Path $root 'core\ShippedFiles.txt')
        (Invoke-DevKitStaleInstallCleanup -Root $root).Stale | Should -Be 0
        Test-Path -LiteralPath $stale | Should -BeTrue
    }

    It "deletes nothing when the shipped list is implausibly short or lacks the files every real list names" {
        $root = New-FakeInstall
        $stale = Add-File $root 'tools\maintenance\_module.psd1'
        [System.IO.File]::WriteAllLines((Join-Path $root 'core\ShippedFiles.txt'), [string[]]@('core\ShippedFiles.txt', 'core\DevKit.Core.psm1', 'tools\lib\DevKit-Common.ps1'))
        (Invoke-DevKitStaleInstallCleanup -Root $root).Stale | Should -Be 0
        $withoutRequired = @(Get-ListEntries $script:ShippedPath | Where-Object { $_ -ne 'tools\lib\DevKit-Common.ps1' })
        [System.IO.File]::WriteAllLines((Join-Path $root 'core\ShippedFiles.txt'), [string[]]$withoutRequired)
        (Invoke-DevKitStaleInstallCleanup -Root $root).Stale | Should -Be 0
        Test-Path -LiteralPath $stale | Should -BeTrue
    }

    It "never deletes a file the shipped list names, even if the removed list names it too" {
        $root = New-FakeInstall
        Add-Content -LiteralPath (Join-Path $root 'core\RemovedFiles.txt') -Value 'core\DevKit.Core.psm1'
        Add-Content -LiteralPath (Join-Path $root 'core\RemovedFiles.txt') -Value 'TOOLS/LIB/devkit-common.ps1'
        $before = Get-AllFiles $root
        (Invoke-DevKitStaleInstallCleanup -Root $root).Stale | Should -Be 0
        (Get-AllFiles $root) | Should -Be $before
    }

    It "ignores removed-list entries that try to leave core\ and tools\" {
        $root = New-FakeInstall
        $outside1 = Add-File $root 'keepme.txt'
        $outside2 = Add-File (Split-Path -Parent $root) "sibling-$([guid]::NewGuid().ToString('N').Substring(0, 6)).txt"
        $lines = @('keepme.txt', '..\' + (Split-Path -Leaf $outside2), 'tools\..\keepme.txt', 'tools\..\..\' + (Split-Path -Leaf $outside2), $outside1, 'core', 'tools\')
        Add-Content -LiteralPath (Join-Path $root 'core\RemovedFiles.txt') -Value $lines
        (Invoke-DevKitStaleInstallCleanup -Root $root).Stale | Should -Be 0
        Test-Path -LiteralPath $outside1 | Should -BeTrue
        Test-Path -LiteralPath $outside2 | Should -BeTrue
        Remove-Item -LiteralPath $outside2
    }

    It "does not delete through a link: a removed path that lies behind a junction is left alone" {
        $root = New-FakeInstall
        $outside = Join-Path $TestDrive "outside-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        # The junction makes <root>\tools\maintenance\_module.psd1 resolve to a
        # file in a folder DevKit was never installed into.
        $precious = Add-File $outside '_module.psd1'
        $link = Join-Path $root 'tools\maintenance'
        [void](New-Item -ItemType Junction -Path $link -Target $outside)
        try {
            (Invoke-DevKitStaleInstallCleanup -Root $root).Stale | Should -Be 0
            Test-Path -LiteralPath $precious | Should -BeTrue
            Test-Path -LiteralPath $link | Should -BeTrue
        } finally {
            # Unlink before TestDrive cleanup, so nothing is deleted THROUGH it.
            [System.IO.Directory]::Delete($link, $false)
        }
    }

    It "leaves everything alone when tools\ itself is a link to somewhere else" {
        $root = New-FakeInstall
        $realTools = Join-Path $TestDrive "checkout-tools-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        Move-Item -LiteralPath (Join-Path $root 'tools') -Destination $realTools
        $stale = Add-File $realTools 'maintenance\_module.psd1'
        $link = Join-Path $root 'tools'
        [void](New-Item -ItemType Junction -Path $link -Target $realTools)
        try {
            (Invoke-DevKitStaleInstallCleanup -Root $root).Stale | Should -Be 0
            Test-Path -LiteralPath $stale | Should -BeTrue
        } finally {
            [System.IO.Directory]::Delete($link, $false)
        }
    }

    It "runs as the installer runs it - Windows PowerShell 5.1, -File, exit code 0 - and cleans up" {
        $root = New-FakeInstall
        $stale = Add-File $root 'tools\maintenance\_module.psd1'
        $theirs = Add-File $root 'tools\my-own-script.ps1'
        $output = & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:CleanupScript -InstallRoot $root 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'removed 1 of 1 file'
        Test-Path -LiteralPath $stale | Should -BeFalse
        Test-Path -LiteralPath $theirs | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $root 'core\DevKit.Core.psm1') | Should -BeTrue
    }

    It "works for an install folder with spaces in its path" {
        $root = New-FakeInstall
        $spaced = Join-Path $TestDrive "Program Files $([guid]::NewGuid().ToString('N').Substring(0, 6))\Dev Kit"
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $spaced) -Force)
        Move-Item -LiteralPath $root -Destination $spaced
        $stale = Add-File $spaced 'tools\maintenance\_module.psd1'
        $null = & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:CleanupScript -InstallRoot $spaced 2>&1
        $LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath $stale | Should -BeFalse
    }

    It "exits 0 and removes nothing when pointed at a folder that is not an install" {
        $empty = Join-Path $TestDrive "empty-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        $theirs = Add-File $empty 'tools\maintenance\_module.psd1'
        $output = & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:CleanupScript -InstallRoot $empty 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'removed 0 of 0'
        Test-Path -LiteralPath $theirs | Should -BeTrue
    }
}

Describe "the installer hooks" {

    BeforeAll {
        $script:Hooks = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'app\src-tauri\windows\hooks.nsh'))
    }

    It "runs the cleanup from POSTINSTALL, with the install folder" {
        $script:Hooks | Should -Match '!macro NSIS_HOOK_POSTINSTALL'
        $script:Hooks.Contains('-File "$INSTDIR\core\Remove-StaleInstallFiles.ps1" -InstallRoot "$INSTDIR"') | Should -BeTrue
    }

    It "deletes nothing itself before the new files are written" {
        # A delete-first PREINSTALL hook runs before the installer's own
        # running-app check, which the user can cancel - leaving a working
        # app with no scripts.
        $script:Hooks | Should -Not -Match '!macro NSIS_HOOK_PREINSTALL'
        $script:Hooks | Should -Not -Match 'RMDir /r "\$INSTDIR'
    }

    It "starts Windows' own programs by full path, never by bare name" {
        # CreateProcess looks in the installer's own folder first, and an
        # update runs the installer elevated from a user-writable temp
        # folder: a bare 'powershell.exe' or 'schtasks' there would run
        # whatever was planted beside it.
        $script:Hooks.Contains('"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"') | Should -BeTrue
        $bare = [regex]::Matches($script:Hooks, "(?m)^\s*(nsExec::ExecToStack|ExecWait|ExecShellWait|Exec)\b.*$") |
            ForEach-Object { $_.Value } | Where-Object { $_ -notmatch '\$SYSDIR\\' }
        $bare | Should -BeNullOrEmpty
    }

    It "removes the elevation task elevated when the plain delete was refused" {
        # The task starts whatever exe is at the old install path as
        # Administrator; left behind after an uninstall it points at an empty
        # slot in a user-writable folder.
        $plain = $script:Hooks.IndexOf('schtasks.exe" /delete /tn "NorthstarDevKit-Admin" /f''')
        $query = $script:Hooks.IndexOf('schtasks.exe" /query /tn "NorthstarDevKit-Admin"''')
        $elevated = $script:Hooks.IndexOf('ExecShellWait "runas" "$SYSDIR\schtasks.exe"')
        $plain | Should -BeGreaterThan -1
        $query | Should -BeGreaterThan $plain
        $elevated | Should -BeGreaterThan $query
    }

    It "keeps the elevation task when the uninstaller runs as a step of installing a newer version" {
        # The installer runs the previous uninstaller in place
        # ('uninstall.exe _?=<dir>', so $EXEDIR is the install folder); a real
        # uninstall runs from a temporary copy. Without this, a manual
        # upgrade raised a UAC prompt mid-install and threw away the task,
        # its logon trigger and the setup marker.
        $guard = $script:Hooks.IndexOf('${AndIf} $EXEDIR != $INSTDIR')
        $delete = $script:Hooks.IndexOf('/delete /tn "NorthstarDevKit-Admin"')
        $guard | Should -BeGreaterThan -1
        $delete | Should -BeGreaterThan $guard
        $script:Hooks.IndexOf('${If} $UpdateMode <> 1') | Should -BeLessThan $guard
    }
}
