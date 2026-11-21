#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Northstar DevKit - Common Helpers
.DESCRIPTION
    Shared functions used by DevKit scripts. This file is dot-sourced by
    standalone scripts; it does not produce output when loaded.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.VERSION
    3.8.0
#>

# Prevent double-loading. Scope-aware on purpose: a $global: bool would
# incorrectly skip loading for a sibling script invoked via `&` in the same
# process (a distinct child scope that never inherits functions defined by
# another sibling's dot-source), leaving it with the flag set but none of
# the functions actually defined. Checking for the function itself detects
# "already loaded in a scope this one can see" instead.
if (Get-Command Write-DevKitHeader -ErrorAction SilentlyContinue) { return }
$global:DevKitCommonLoaded = $true

# When output is piped (the app's Run dialog, a redirect to a file), write it
# as UTF-8. A tool run headlessly gets its own hidden console, whose output
# code page is the legacy OEM one - so a path under C:\Users\José, an em
# dash, or any non-Latin text reached the app as "?" or U+FFFD (verified:
# é arrived as FFFD, a Cyrillic letter as "?"). The app decodes the pipe as
# UTF-8; this makes the tool, and every native command it starts (they
# inherit the console), actually send that. Skipped when already UTF-8 -
# which is always the case inside the RPC sidecar, whose single stdout
# writer must never have its stream swapped underneath it - and never
# touched for an interactive console, where the user's own code page stands.
try {
    if ([Console]::IsOutputRedirected -and [Console]::OutputEncoding.CodePage -ne 65001) {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    }
} catch {
    # No console at all (some hosts): nothing to configure.
}

# A process relaunched via Start-Process (e.g. the GUI's MTA->STA and
# packaged-shell hops in gui/DevKit-GUI.ps1) can have module auto-load
# resolve Microsoft.PowerShell.Utility to a same-named module from a
# DIFFERENT PowerShell install earlier on PSModulePath - observed on real
# hardware: a Store-packaged pwsh 7 build's copy (no
# Import-PowerShellDataFile) winning over this host's own copy. $PSHOME
# always points at the CURRENT host's own install regardless of how it was
# launched, so pin its own Utility module now, once, before anything below
# calls Import-PowerShellDataFile.
$devKitUtilityManifestPath = Join-Path $PSHOME "Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1"
if (Test-Path $devKitUtilityManifestPath) {
    Import-Module $devKitUtilityManifestPath -Force -ErrorAction SilentlyContinue
}

# Animation/color engine (gradient text, startup banner, spinner) - split
# out of this file so the terminal-capability probing and ANSI rendering
# live in one place. Dot-sourced here so every function below (and every
# script that dot-sources DevKit-Common.ps1) can call it directly.
. (Join-Path $PSScriptRoot "DevKit-UI.ps1")

# ==================== SETTINGS ====================

function Get-DevKitJsonReadArgs {
    <#
    .SYNOPSIS
        Extra arguments for every ConvertFrom-Json that reads DevKit's own
        data (the stores, and RPC requests): @{ DateKind = 'String' } where
        the cmdlet has that parameter, else an empty table.
    .DESCRIPTION
        PowerShell 7 turns any JSON string that LOOKS like an ISO date into a
        [datetime]. DevKit's data is full of such strings (updatedAt,
        lastUsedUtc, lastUpdateCheckUtc - and a note can simply be one), and
        every reader then did [string]$value, which renders a DateTime as
        "11/21/2026 10:00:00": the zone is gone, a "+02:00" stamp has been
        shifted to local time, and the next save wrote that back for good.
        Windows PowerShell 5.1 never converted, so the two shells disagreed
        about the same file. -DateKind String (PowerShell 7.5+) keeps the
        text as written. ConvertTo-DevKitStoredText covers 7.0 - 7.4.
    #>
    if ($null -eq $script:DevKitJsonReadArgs) {
        $script:DevKitJsonReadArgs = @{}
        try {
            if ((Get-Command ConvertFrom-Json -ErrorAction Stop).Parameters.ContainsKey('DateKind')) {
                $script:DevKitJsonReadArgs = @{ DateKind = 'String' }
            }
        } catch { }
    }
    return $script:DevKitJsonReadArgs
}

function ConvertTo-DevKitStoredText {
    <#
    .SYNOPSIS
        A value read from JSON, as the text that was written. Undoes
        PowerShell 7's date coercion where Get-DevKitJsonReadArgs could not
        prevent it (7.0 - 7.4): a DateTime comes back as a round-trip ISO
        string, never as the culture-style text a plain [string] cast gives.
    #>
    param($Value)
    if ($Value -is [datetime] -or $Value -is [datetimeoffset]) {
        return $Value.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$Value
}

function Read-DevKitStoreFile {
    <#
    .SYNOPSIS
        The text of one of DevKit's JSON stores (settings.json,
        projects.json), or $null when the file does not exist. THROWS when
        the file exists but cannot be read, after a few short retries.
    .DESCRIPTION
        "Could not read it" and "it is corrupt" are different facts, and the
        store code used to treat them as one: any exception while loading -
        including a sharing violation from another DevKit process replacing
        the file at that instant, or antivirus holding it - sent the file to
        quarantine as "corrupted" and reset every preference (or the whole
        linked-projects list) to defaults. And a save that could not read
        the file first wrote back only what the caller had passed, which for
        the app is a one-key patch.

        Callers now get the distinction: this throws for "unreadable right
        now" (leave the file alone; fail the save), and they keep quarantine
        for text that was read and would not parse.

        ReadAllText rather than Get-Content: it decodes BOM-less UTF-8 the
        same way under Windows PowerShell 5.1 and PowerShell 7 (5.1's
        Get-Content reads it as ANSI, mangling any non-ASCII project path).
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $lastError = $null
    foreach ($attempt in 1..4) {
        try {
            return [System.IO.File]::ReadAllText($Path)
        } catch [System.IO.FileNotFoundException] {
            return $null
        } catch {
            $lastError = $_
            Start-Sleep -Milliseconds 60
        }
    }
    throw "Could not read ${Path}: $($lastError.Exception.Message)"
}

function Get-DevKitSettingsFile {
    $dir = Join-Path $env:LOCALAPPDATA "NorthstarDevKit"
    if (-not (Test-Path $dir)) {
        # Best-effort: a creation failure (permissions, profile not fully
        # loaded during logon) must not be a terminating error here -
        # downstream readers already tolerate the file simply being absent.
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { }
    }
    return Join-Path $dir "settings.json"
}

function Get-DevKitSettings {
    <#
    .SYNOPSIS
        Loads DevKit's settings, creating the file with defaults on first
        use. A corrupt/hand-edited file is quarantined and reset rather than
        crashing - the same pattern already used for the project registry.
    .OUTPUTS
        PSCustomObject with .schemaVersion and .preferences.
    #>
    $defaults = [PSCustomObject]@{
        schemaVersion = 1
        preferences   = [PSCustomObject]@{
            confirmDestructive = $true
            updateCheckEnabled = $true
            lastUpdateCheckUtc = $null
            enableAnimations   = $true
            widgetDockMode     = 'Right'
            widgetWidth        = 380
            gitFlyoutWidth     = 300
            notesFlyoutWidth   = 300
            envDriftSilencedProjects = @()
            # Tauri app appearance/UX (added with the 2026 Settings panel;
            # the name-level backfill above makes these safe to add - an
            # existing settings.json just gains them on next load).
            appTheme           = 'northstar'   # one of the 10 built-in theme presets
            accentColor        = $null         # hex override; $null = theme default
            fontFamily         = $null         # UI font override; $null = theme default
            uiScale            = 1.0           # 0.8 - 1.4, applied as root zoom
            terminalTheme      = 'northstar'   # embedded terminal color scheme
            uiSounds           = $true         # click/thud/swoosh feedback
            uiSoundVolume      = 0.5           # 0.0 - 1.0
            # Flyout trays + global summon (2026 tray revival - the
            # gitFlyoutWidth/notesFlyoutWidth above are the ORIGINAL WPF
            # widget's per-flyout widths, kept for continuity; flyoutWidth
            # is the default for flyouts that don't have their own).
            flyoutWidth        = 380
            controlCenterFlyoutWidth = $null  # $null = fill the remaining screen on open; a resize drag persists a number
            flyoutTabOrder     = @()           # rail tab order by tray id; empty = the code's default order. Written by drag-reordering the rail.
            globalHotkey       = 'CommandOrControl+Alt+D'  # summon/dismiss the widget
            runHistoryLimit    = 50            # tool runs retained in history
            # Icon rail (the vertical strip of flyout tabs on the widget's
            # inner edge). Width is the whole strip; iconSize is the glyph
            # inside it, kept separate so a wider strip with the same glyph
            # (more breathing room) is expressible.
            iconTheme          = 'outline'     # 'outline' | 'solid' | 'duotone'
            railWidth          = 44            # px, logical
            railIconSize       = 18            # px, logical
            # Widget width persisted on close so it reopens exactly as left.
            # $null = never set; the Rust side then falls back to its
            # quarter-screen default (see commands.rs).
            widgetSavedWidth   = $null
        }
    }

    $path = Get-DevKitSettingsFile
    if (-not (Test-Path $path)) { return $defaults }

    # Unreadable right now is NOT corrupt: answer this one call with the
    # defaults and leave the file exactly where it is (Read-DevKitStoreFile).
    $raw = $null
    try { $raw = Read-DevKitStoreFile -Path $path } catch { return $defaults }

    try {
        if ([string]::IsNullOrWhiteSpace($raw)) { return $defaults }
        $jsonArgs = Get-DevKitJsonReadArgs
        $data = $raw | ConvertFrom-Json @jsonArgs -ErrorAction Stop
        if (-not $data.preferences) { return $defaults }
        # Fill in any preference missing from an older/partial file rather
        # than failing outright, so adding a new setting later never breaks
        # an existing settings.json.
        # Caveat: shallow name-level backfill only - any key present in the user file replaces the default wholesale (nested object values are never deep-merged).
        foreach ($prop in $defaults.preferences.PSObject.Properties.Name) {
            # @() + -contains, never .Name.Contains(): with exactly one
            # property on file the member-enumerated .Name is a bare string,
            # and String.Contains would do a substring match.
            if (-not (@($data.preferences.PSObject.Properties.Name) -contains $prop)) {
                $data.preferences | Add-Member -MemberType NoteProperty -Name $prop -Value $defaults.preferences.$prop
            }
        }
        return $data
    } catch {
        $backupPath = "$path.corrupt-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
        try { Move-Item -Path $path -Destination $backupPath -Force -ErrorAction SilentlyContinue } catch {}
        Write-DevKitError "Settings file was corrupted and has been reset. Backup: $backupPath"
        return $defaults
    }
}

function Set-DevKitSettings {
    param([Parameter(Mandatory = $true)]$Settings)
    $path = Get-DevKitSettingsFile
    $tempPath = "$path.tmp.$PID"
    try {
        # Merge over whatever is on disk right now instead of blindly
        # overwriting: another DevKit process (e.g. the long-lived widget) may
        # have written its own preference change since this caller loaded its
        # copy, and last-writer-wins would silently drop it. The caller's
        # preference keys win; on-disk keys the caller doesn't carry (e.g.
        # written by a newer build) are preserved. Best-effort: any
        # read/parse failure falls back to the caller's copy as-is.
        $toSave = $Settings
        # Read OUTSIDE the forgiving try below, so a file that exists but
        # cannot be read fails the save. Carrying on would write the
        # caller's object as the whole file - and the app's caller sends a
        # one-key patch, so every other preference would silently revert.
        $raw = Read-DevKitStoreFile -Path $path
        try {
            if ($null -ne $raw) {
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    $jsonArgs = Get-DevKitJsonReadArgs
                    $onDisk = $raw | ConvertFrom-Json @jsonArgs -ErrorAction Stop
                    if ($onDisk.preferences -and $Settings.preferences) {
                        foreach ($prop in @($Settings.preferences.PSObject.Properties.Name)) {
                            $onDisk.preferences | Add-Member -MemberType NoteProperty -Name $prop -Value $Settings.preferences.$prop -Force
                        }
                        # schemaVersion is deliberately NOT taken from the caller
                        # unconditionally. A caller sending a partial patch may omit it
                        # entirely (writing $null would make the next Get-DevKitSettings
                        # treat the file as unversioned), and an older build must never
                        # downgrade a file a newer build wrote. Keep the highest version
                        # either side knows about.
                        $diskVersion = 0
                        if ($null -ne $onDisk.schemaVersion) { [void][int]::TryParse([string]$onDisk.schemaVersion, [ref]$diskVersion) }
                        $callerVersion = 0
                        if ($null -ne $Settings.schemaVersion) { [void][int]::TryParse([string]$Settings.schemaVersion, [ref]$callerVersion) }
                        $keepVersion = [Math]::Max($diskVersion, $callerVersion)
                        if ($keepVersion -gt 0) {
                            $onDisk | Add-Member -MemberType NoteProperty -Name schemaVersion -Value $keepVersion -Force
                        }
                        $toSave = $onDisk
                    }
                }
            }
        } catch { $toSave = $Settings }
        $toSave | ConvertTo-Json -Depth 6 | Set-Content -Path $tempPath -Encoding UTF8
        Move-Item -Path $tempPath -Destination $path -Force
    } catch {
        if (Test-Path $tempPath) { Remove-Item $tempPath -Force -ErrorAction SilentlyContinue }
        throw "Failed to save settings: $_"
    }
}

function Confirm-DevKitDestructiveAction {
    <#
    .SYNOPSIS
        One reusable confirmation gate for destructive operations, so new
        (and eventually migrated) destructive scripts share a single,
        correctly-implemented prompt instead of each hand-rolling its own.
    .PARAMETER Action
        One-line description of what will happen, e.g. "delete all Docker
        containers, images, and volumes".
    .PARAMETER AffectedPaths
        Optional list of specific paths/items to display, so the user sees
        exactly what's affected rather than a vague summary.
    .PARAMETER TypedPhrase
        If set, the user must type this exact phrase (case-sensitive) to
        confirm, e.g. 'NUKE'. If omitted, a simple y/N prompt is used.
    .PARAMETER Force
        Bypass the prompt entirely (the caller's own -Force switch).
    .PARAMETER Always
        Ask even when the user has turned the confirmDestructive setting
        off. For a prompt that is the tool's whole point or a choice between
        steps rather than a second "are you sure": "Kill Process by Port
        (With Confirmation)" exists next to a no-confirm twin, and Git
        Cleanup asks about each step separately. These tools asked
        unconditionally before they used this gate; -Always keeps that,
        while still gaining the safe refusal where nobody can answer.
        -Force still bypasses it.
    .OUTPUTS
        [bool] $true if the action should proceed.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [string[]]$AffectedPaths = @(),
        [string]$TypedPhrase,
        [switch]$Force,
        [switch]$Always
    )

    if ($Force) { return $true }

    if (-not $Always) {
        $settings = Get-DevKitSettings
        if (-not $settings.preferences.confirmDestructive) { return $true }
    }

    Write-Host "  This will: $Action" -ForegroundColor Yellow
    foreach ($p in $AffectedPaths) { Write-Host "    - $p" -ForegroundColor Gray }

    # Read-Host THROWS under -NonInteractive ("PowerShell is in NonInteractive
    # mode"), which is exactly how the GUI launches tool scripts - it spawns
    # them with -NonInteractive and closes stdin. Without this guard every
    # destructive tool dies on an unhandled exception right after the user
    # already confirmed in the app's own caution dialog. Refuse safely instead:
    # declining is always the correct answer when consent cannot be obtained.
    if (-not (Test-DevKitCanPrompt)) {
        Write-Host "  Cannot prompt for confirmation in a non-interactive session - aborting." -ForegroundColor Yellow
        Write-Host "  Re-run this tool with -Force to proceed without a prompt." -ForegroundColor Gray
        return $false
    }

    if ($TypedPhrase) {
        $typed = Read-Host "  Type '$TypedPhrase' to confirm"
        return ($typed -ceq $TypedPhrase)
    }
    $answer = Read-Host "  Continue? (y/N)"
    return ($answer -eq 'y')
}

function Test-DevKitCanPrompt {
    <#
    .SYNOPSIS
        True when this session can actually read a console prompt.
    .DESCRIPTION
        PowerShell exposes no direct "am I -NonInteractive" flag, so probe the
        two conditions that make Read-Host fail: a host whose UI stack is
        absent (the -NonInteractive case, and runspaces created without a
        host), and redirected/absent stdin. Any probe failure is treated as
        "cannot prompt" - the safe direction for a destructive gate.
    .OUTPUTS
        [bool]
    #>
    try {
        if ($null -eq $Host -or $null -eq $Host.UI -or $null -eq $Host.UI.RawUI) { return $false }
        if ([System.Console]::IsInputRedirected) { return $false }
        return $true
    } catch {
        return $false
    }
}

# ==================== TOOL MANIFESTS AND THE ARROW-KEY MENU ====================
#
# Every tool folder describes its tools in a small "_module.psd1" manifest
# (Get-DevKitModule loads one). The catalog the app and the CLI show is built
# from those manifests in core/DevKit-GuiCore.ps1. Show-DevKitInteractiveMenu
# is the arrow-key picker a tool can use for its own choices (Run Package
# Script lists the package.json scripts with it).

function Get-DevKitModule {
    <#
    .SYNOPSIS
        Loads a tool category's _module.psd1 manifest.
    .PARAMETER FolderPath
        Full path to the category folder (e.g. .../ports).
    #>
    param([Parameter(Mandatory = $true)][string]$FolderPath)

    $manifestPath = Join-Path $FolderPath "_module.psd1"
    if (-not (Test-Path $manifestPath)) {
        throw "No _module.psd1 manifest found in '$FolderPath'"
    }
    # Import-PowerShellDataFile only ever parses literal data (hashtables,
    # arrays, strings, numbers, booleans) - safe to load with no code
    # execution risk, unlike dot-sourcing an arbitrary .ps1.
    $module = Import-PowerShellDataFile -Path $manifestPath
    $module.FolderPath = $FolderPath
    return $module
}


function Show-DevKitInteractiveMenu {
    <#
    .SYNOPSIS
        Renders a bracketed option list and reads the user's choice, adding
        optional arrow-key navigation on top of the classic "type a number
        and press Enter" flow every menu already used.
    .DESCRIPTION
        Each entry is either selectable (@{ Key; Label }) or a non-selectable
        section heading (@{ IsHeader = $true; Label }) used for the Main
        Menu's grouped layout. On a console that supports raw key reads,
        UpArrow/DownArrow move a highlighted selection (skipping headings)
        and Enter confirms it; typed digits/letters are still captured and
        echoed like Read-Host, so existing conventions (typing "3p" to
        force-reprompt a project, typing a bare search keyword) keep working
        unchanged. On a console that can't do raw key reads (redirected
        input, CI, some non-interactive hosts) this transparently falls back
        to a plain Read-Host prompt - the exact behavior every menu had
        before this function existed. Always returns the same raw trimmed
        string a Read-Host call would, so callers (switch statements, regex
        matches like '^(.+)p$') require no changes at all.
    .PARAMETER Entries
        Ordered list of @{ Key; Label } and/or @{ IsHeader = $true; Label }.
    .PARAMETER PromptLabel
        Text shown at the input line (matches the prior Read-Host prompts).
    #>
    param(
        [Parameter(Mandatory = $true)][array]$Entries,
        [string]$PromptLabel = 'Select option'
    )

    $selectable = @()
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        if (-not $Entries[$i].IsHeader) { $selectable += $i }
    }

    # Checked (and guarded) before ANY Console API touches the actual
    # screen buffer: on a redirected/piped host (CI, a plain pipe, some
    # non-console hosts) even a read-only property like CursorTop can throw
    # "handle is invalid" rather than just report redirected - so every
    # probe here is wrapped, and failure at any step degrades straight to
    # the classic Read-Host flow instead of crashing the menu.
    $canNavigate = $selectable.Count -gt 0
    if ($canNavigate) {
        try {
            $canNavigate = (-not [Console]::IsInputRedirected) -and (-not [Console]::IsOutputRedirected)
        } catch {
            $canNavigate = $false
        }
    }

    $entryTop = $null
    if ($canNavigate) {
        try { $entryTop = [Console]::CursorTop } catch { $canNavigate = $false }
    }

    foreach ($e in $Entries) {
        if ($e.IsHeader) {
            Write-Host "  $($e.Label)" -ForegroundColor White
        } else {
            Write-Host ("  [{0}] {1}" -f $e.Key, $e.Label)
        }
    }
    Write-Host ""

    if (-not $canNavigate) {
        $raw = Read-Host $PromptLabel
        # stdin EOF (redirected input exhausted) must not throw on .Trim() or
        # spin a re-prompt loop forever - treat it as Back, same as Escape.
        if ($null -eq $raw) { return '0' }
        return $raw.Trim()
    }

    $promptTop = $null
    try { $promptTop = [Console]::CursorTop } catch { $canNavigate = $false }
    if (-not $canNavigate) {
        $raw = Read-Host $PromptLabel
        if ($null -eq $raw) { return '0' }
        return $raw.Trim()
    }

    try {
        $bufferWidth = [Console]::BufferWidth
        $maxLen = [Math]::Max($bufferWidth - 1, 1)
        $selectedPos = 0
        $typed = ''

        $drawEntry = {
            param($entryIndex, $isSelected)
            [Console]::SetCursorPosition(0, $entryTop + $entryIndex)
            $e = $Entries[$entryIndex]
            $line = "  [{0}] {1}" -f $e.Key, $e.Label
            if ($line.Length -gt $maxLen) { $line = $line.Substring(0, $maxLen) }
            $padded = $line.PadRight($maxLen)
            if ($isSelected) {
                Write-Host ("> " + $padded.Substring(2)) -ForegroundColor Black -BackgroundColor Cyan -NoNewline
            } else {
                Write-Host $padded -NoNewline
            }
        }
        $drawPrompt = {
            [Console]::SetCursorPosition(0, $promptTop)
            $line = "${PromptLabel}: $typed"
            if ($line.Length -gt $maxLen) { $line = $line.Substring(0, $maxLen) }
            Write-Host $line.PadRight($maxLen) -NoNewline
            [Console]::SetCursorPosition([Math]::Min($line.Length, $maxLen), $promptTop)
        }

        & $drawEntry $selectable[$selectedPos] $true
        & $drawPrompt

        while ($true) {
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow' {
                    & $drawEntry $selectable[$selectedPos] $false
                    $selectedPos = if ($selectedPos -eq 0) { $selectable.Count - 1 } else { $selectedPos - 1 }
                    & $drawEntry $selectable[$selectedPos] $true
                    $typed = ''
                    & $drawPrompt
                }
                'DownArrow' {
                    & $drawEntry $selectable[$selectedPos] $false
                    $selectedPos = ($selectedPos + 1) % $selectable.Count
                    & $drawEntry $selectable[$selectedPos] $true
                    $typed = ''
                    & $drawPrompt
                }
                'Enter' {
                    [Console]::SetCursorPosition(0, $promptTop + 1)
                    if ([string]::IsNullOrWhiteSpace($typed)) { return $Entries[$selectable[$selectedPos]].Key }
                    return $typed.Trim()
                }
                'Escape' {
                    [Console]::SetCursorPosition(0, $promptTop + 1)
                    return '0'
                }
                'Backspace' {
                    if ($typed.Length -gt 0) {
                        $typed = $typed.Substring(0, $typed.Length - 1)
                        & $drawPrompt
                    }
                }
                default {
                    if ($key.KeyChar -and -not [char]::IsControl($key.KeyChar)) {
                        $typed += $key.KeyChar
                        & $drawPrompt
                    }
                }
            }
        }
    } catch {
        Write-Host ""
        Write-Host "  (Arrow-key navigation unavailable in this console -- switched to typed input.)" -ForegroundColor DarkGray
        $raw = Read-Host $PromptLabel
        if ($null -eq $raw) { return '0' }   # stdin EOF: treat as Back, same as Escape
        return $raw.Trim()
    }
}


# ==================== OUTPUT HELPERS ====================

function Write-DevKitHeader {
    param([string]$Title)
    Write-Host "`nNorthstar DevKit - $Title`n" -ForegroundColor Cyan
}

function Write-DevKitStep {
    param([string]$Message)
    # Cyan, not Yellow: Yellow is reserved for real warnings (per AGENTS.md's
    # documented color convention). Routine in-progress chrome using the same
    # color as an actual warning diluted its meaning across the codebase.
    Write-Host "  $Message..." -ForegroundColor Cyan -NoNewline
}

function Write-DevKitDone {
    Write-Host " DONE" -ForegroundColor Green
}

function Write-DevKitSkip {
    Write-Host " SKIP" -ForegroundColor Gray
}

function Write-DevKitError {
    param([string]$Message)
    Write-Host " ERROR: $Message" -ForegroundColor Red
}

function Write-DevKitInfo {
    param([string]$Message)
    Write-Host "  $Message" -ForegroundColor Gray
}

# ==================== ENVIRONMENT / PRIVILEGE ====================

function Test-DevKitAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-DevKitCommand {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-DevKitWindowsExecutable {
    <#
    .SYNOPSIS
        Resolves a command name to something safe to invoke directly with "&".
    .DESCRIPTION
        A real bug hit while building the AI CLI tools: on a machine with more
        than one "gh" on PATH, Get-Command's first match was an extension-less
        POSIX shim (an npm-installed unrelated "gh" package, not GitHub CLI).
        Invoking that directly with "&" makes PowerShell fall back to
        ShellExecute, which pops a real "Select an app to open" Windows dialog
        instead of failing cleanly - and can leave a caller waiting on GUI
        input that never arrives. Only ever invoke a match with a recognized
        Windows-executable extension (or a native PS command/function/alias,
        which never hits ShellExecute); anything else should be treated as
        "found but not safely runnable" rather than guessed at.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)

    $appMatches = @(Get-Command $Name -All -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandType -eq 'Application' -and $_.Source -match '\.(exe|cmd|bat)$'
    })
    if ($appMatches.Count -gt 0) { return $appMatches[0] }

    $anyMatch = Get-Command $Name -ErrorAction SilentlyContinue
    if ($anyMatch -and $anyMatch.CommandType -ne 'Application') { return $anyMatch }

    return $null
}

# ==================== PATH HELPERS ====================

function Resolve-DevKitDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Path not found: $Path"
    }

    $resolved = (Resolve-Path $Path).Path
    if (-not (Test-Path $resolved -PathType Container)) {
        throw "Path is not a directory: $resolved"
    }

    return $resolved
}

function Invoke-DevKitInDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    $resolved = Resolve-DevKitDirectory -Path $Path
    Push-Location $resolved
    try {
        & $ScriptBlock
    } finally {
        Pop-Location
    }
}

# ==================== FILE / CACHE HELPERS ====================

function Remove-DevKitNodeModulesWithStatus {
    <#
    .SYNOPSIS
        Deletes node_modules from a project directory and says which of the
        three things happened: 'Removed', 'Absent' or 'Failed'.
    .DESCRIPTION
        'Absent' (there was no node_modules) and 'Failed' (files in it are
        locked and it is still there) are opposite outcomes, and the old
        boolean returned $false for both. Every caller printed SKIP for
        either, so a delete blocked by a running dev server was reported as
        "nothing to do" - and Nuke-And-Reinstall then went on to delete the
        lock files and install on top of a half-deleted tree.

        Long-path-safe deletion: mirrors an empty folder over node_modules
        with robocopy, then removes the (now-empty) directory tree. Robocopy
        is bounded with /R:2 /W:1 so a locked file cannot hang the call.
        Throws if robocopy itself reports a hard failure (exit code >= 8).

        A node_modules that is a junction or symbolic link (dev containers,
        some monorepo setups) has only the LINK removed. Mirroring an empty
        folder through it would empty the directory it points at - somebody
        else's node_modules.
    .PARAMETER Path
        The project directory containing node_modules.
    .OUTPUTS
        [string] 'Removed' | 'Absent' | 'Failed'
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolved = Resolve-DevKitDirectory -Path $Path
    $nmPath = Join-Path $resolved "node_modules"

    if (-not (Test-Path -LiteralPath $nmPath)) {
        return 'Absent'
    }

    $nmItem = Get-Item -LiteralPath $nmPath -Force
    if ($nmItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        # Non-recursive delete of a directory link removes the link only.
        [System.IO.Directory]::Delete($nmPath, $false)
        if (Test-Path -LiteralPath $nmPath) { return 'Failed' }
        return 'Removed'
    }

    # Long-path-safe deletion: mirror an empty folder, then remove
    $empty = Join-Path $env:TEMP "empty_devkit_$(Get-Random)"
    try {
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        robocopy $empty $nmPath /MIR /MT:8 /R:2 /W:1 /NFL /NDL /NJH /NJS | Out-Null
        # Robocopy exit codes 0-7 are all "success" (bitmask of what happened,
        # e.g. files copied/deleted); only >=8 indicates a real failure.
        if ($LASTEXITCODE -ge 8) {
            throw "robocopy failed to clear '$nmPath' (exit code $LASTEXITCODE) - files may be locked by a running process."
        }
        Remove-Item -LiteralPath $nmPath -Recurse -Force -ErrorAction SilentlyContinue
    } finally {
        if (Test-Path -LiteralPath $empty) {
            Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path -LiteralPath $nmPath) {
        # Removal did not fully succeed (e.g. locked files) - say so instead
        # of pretending the directory is gone.
        return 'Failed'
    }

    return 'Removed'
}

function Remove-DevKitNodeModules {
    <#
    .SYNOPSIS
        Deletes node_modules from the given project directory. Returns $true
        only when it existed and is now gone.
    .DESCRIPTION
        Kept for callers that only need yes/no. $false means EITHER "there
        was none" OR "it could not be removed" - anything that must tell
        those apart (every tool that goes on to do something destructive)
        calls Remove-DevKitNodeModulesWithStatus instead.
    .PARAMETER Path
        The project directory containing node_modules.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    return ((Remove-DevKitNodeModulesWithStatus -Path $Path) -eq 'Removed')
}

function Get-DevKitReinstallBlocker {
    <#
    .SYNOPSIS
        Why a "delete everything and reinstall" must not start, or $null
        when it may.
    .DESCRIPTION
        The reinstall tools used to delete node_modules and the lock files
        first and discover only at the install step that the package
        manager was not on PATH - leaving a project with neither. Asked
        BEFORE anything is deleted.
    .OUTPUTS
        [string] reason, or $null.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Manager
    )
    if (-not (Test-Path -LiteralPath (Join-Path $Path 'package.json'))) {
        return "there is no package.json in $Path, so there is nothing to reinstall"
    }
    if (-not (Test-DevKitCommand $Manager.Command)) {
        return "$($Manager.Command) is not installed or not on PATH, so the reinstall could not run"
    }
    return $null
}

function Move-DevKitLockFilesAside {
    <#
    .SYNOPSIS
        Renames a project's lock files to "<name>.devkit-bak" so a fresh
        install resolves from scratch, and returns what it moved.
    .DESCRIPTION
        Set aside, not deleted: if the install that follows fails (offline,
        an expired registry token), Restore-DevKitLockFiles puts them back.
        Deleting them outright left a failed run with no lock file at all -
        and an untracked one was gone for good.
    .OUTPUTS
        Array of hashtables (Original, Backup) - full paths.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $moved = @()
    foreach ($name in @("package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock")) {
        $original = Join-Path $Path $name
        if (-not (Test-Path -LiteralPath $original)) { continue }
        $backup = "$original.devkit-bak"
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction Stop }
        Move-Item -LiteralPath $original -Destination $backup -Force -ErrorAction Stop
        $moved += @{ Original = $original; Backup = $backup }
    }
    return , $moved
}

function Restore-DevKitLockFiles {
    <#
    .SYNOPSIS
        Puts lock files set aside by Move-DevKitLockFilesAside back, over
        whatever a failed install may have half-written.
    #>
    param([AllowEmptyCollection()][array]$Moved = @())
    foreach ($entry in @($Moved)) {
        if (-not $entry -or -not (Test-Path -LiteralPath $entry.Backup)) { continue }
        Move-Item -LiteralPath $entry.Backup -Destination $entry.Original -Force -ErrorAction Stop
    }
}

function Remove-DevKitLockFileBackups {
    <#
    .SYNOPSIS
        Deletes the backups once the install has succeeded and written new
        lock files.
    #>
    param([AllowEmptyCollection()][array]$Moved = @())
    foreach ($entry in @($Moved)) {
        if ($entry -and (Test-Path -LiteralPath $entry.Backup)) {
            Remove-Item -LiteralPath $entry.Backup -Force -ErrorAction SilentlyContinue
        }
    }
}

function Clear-DevKitDirectoryContents {
    <#
    .SYNOPSIS
        Empties a directory's contents WITHOUT following junctions.
    .DESCRIPTION
        Windows PowerShell 5.1's Remove-Item -Recurse FOLLOWS junction
        reparse points, so wiping a folder's children with a bare
        Remove-Item -Recurse can delete content OUTSIDE the target tree.
        TEMP folders are exactly where such links appear (other apps'
        scratch dirs, a developer's own junctions), so the junk-clearing
        tools must not use that pattern. This enumerates only the top
        level: reparse points are removed WITHOUT -Recurse (which deletes
        just the link, never its target), plain files are removed
        directly, and real directories are emptied with the same robocopy
        empty-mirror trick Remove-DevKitNodeModules uses, then removed.
        Per-child failures are skipped with SilentlyContinue - matching
        the previous behavior - so a locked file degrades to "left
        behind" and shows up in the caller's re-measure instead of
        aborting the whole wipe.
    .PARAMETER Path
        Directory whose contents should be removed. The directory itself
        is kept.
    .OUTPUTS
        [bool] $true when every enumerated child was removed, $false when
        something survived (e.g. locked files).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $true }

    $empty = Join-Path $env:TEMP "empty_devkit_$(Get-Random)"
    try {
        New-Item -ItemType Directory -Path $empty -Force | Out-Null

        $allGone = $true
        foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
            if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                # A junction/symlink: remove the link itself, never its
                # target. No -Recurse on purpose (see the doc comment above).
                Remove-Item -LiteralPath $child.FullName -Force -ErrorAction SilentlyContinue
            } elseif ($child.PSIsContainer) {
                # Real directory: long-path-safe deep delete without
                # following anything - robocopy is junction-safe here.
                robocopy $empty $child.FullName /MIR /MT:8 /R:2 /W:1 /NFL /NDL /NJH /NJS | Out-Null
                # Capture the exit code IMMEDIATELY (same idiom as
                # Remove-DevKitNodeModules): on PowerShell 5.1, proceeding
                # to Remove-Item -Recurse after a robocopy FAILURE would
                # follow any junction still standing in the half-cleared
                # tree - the exact hazard this helper exists to prevent.
                # Robocopy exit codes 0-7 are all "success" (bitmask of
                # what happened); only >=8 is a real failure - treat the
                # directory as survived, never recurse into it.
                $rc = $LASTEXITCODE
                if ($rc -ge 8) {
                    $allGone = $false
                } else {
                    Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
            } else {
                Remove-Item -LiteralPath $child.FullName -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $child.FullName) { $allGone = $false }
        }
    } finally {
        if (Test-Path -LiteralPath $empty) {
            Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    return $allGone
}

function Clear-DevKitNodeCaches {
    <#
    .SYNOPSIS
        Removes common Node.js dev/framework caches from a project directory.
    .DESCRIPTION
        By default only removes non-build cache folders: .next,
        node_modules\.cache, node_modules\.vite. Build-output folders
        (dist, and the project-root .vite folder) are NOT touched unless
        -IncludeBuildOutput is passed, since deleting them can silently wipe
        a production build with no confirmation from the caller.
    .PARAMETER Path
        The project directory to clean.
    .PARAMETER IncludeTurbo
        Also remove the Turborepo cache (.turbo).
    .PARAMETER IncludeBuildOutput
        Also remove build-output folders (dist, .vite at the project root).
        Defaults to $false for backward compatibility.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$IncludeTurbo,

        [switch]$IncludeBuildOutput
    )

    $resolved = Resolve-DevKitDirectory -Path $Path
    $cachePaths = @(
        (Join-Path $resolved ".next"),
        (Join-Path (Join-Path $resolved "node_modules") ".cache"),
        (Join-Path (Join-Path $resolved "node_modules") ".vite")
    )

    if ($IncludeBuildOutput) {
        $cachePaths += @(
            (Join-Path $resolved "dist"),
            (Join-Path $resolved ".vite")
        )
    }

    if ($IncludeTurbo) {
        # .next\cache lives under .next, which the base list already removes
        # wholesale, and node_modules\.cache is already in the base list -
        # only .turbo itself is unique to this switch.
        $cachePaths += (Join-Path $resolved ".turbo")
    }

    $cachePaths = $cachePaths | Select-Object -Unique

    $found = $false
    foreach ($cachePath in $cachePaths) {
        if (Test-Path $cachePath) {
            Remove-Item -Path $cachePath -Recurse -Force -ErrorAction SilentlyContinue
            $found = $true
        }
    }

    return $found
}

# ==================== PACKAGE MANAGER HELPERS ====================

function Get-DevKitPackageManager {
    <#
    .SYNOPSIS
        Detects which package manager a project uses.
    .DESCRIPTION
        Checks lock files first (bun.lock / bun.lockb, pnpm-lock.yaml,
        yarn.lock, package-lock.json, in that priority order). If none are
        found, falls back to package.json's corepack "packageManager" field
        (e.g. "pnpm@8.15.0") so freshly-scaffolded projects that don't yet
        have a lock file are still detected correctly. Defaults to npm if
        nothing matches. bun.lock (the text lockfile bun writes since 1.2)
        is probed before bun.lockb (the legacy binary one); they share one
        priority slot, so either one wins over every other manager's file.
    .PARAMETER Path
        The project directory to inspect.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolved = Resolve-DevKitDirectory -Path $Path

    $managers = @(
        @{ Lock = "bun.lock"; Command = "bun"; Install = @("install") },
        @{ Lock = "bun.lockb"; Command = "bun"; Install = @("install") },
        @{ Lock = "pnpm-lock.yaml"; Command = "pnpm"; Install = @("install") },
        @{ Lock = "yarn.lock"; Command = "yarn"; Install = @("install") },
        @{ Lock = "package-lock.json"; Command = "npm"; Install = @("install") }
    )

    foreach ($manager in $managers) {
        if (Test-Path (Join-Path $resolved $manager.Lock)) {
            return $manager
        }
    }

    # No lock file found - check package.json's corepack "packageManager"
    # field (e.g. "pnpm@8.15.0") before defaulting to npm.
    $packageJsonPath = Join-Path $resolved "package.json"
    if (Test-Path $packageJsonPath) {
        try {
            $packageJson = Get-Content $packageJsonPath -Raw | ConvertFrom-Json
            if ($packageJson.PSObject.Properties.Name -contains "packageManager" -and $packageJson.packageManager) {
                $managerName = ($packageJson.packageManager -split "@")[0].Trim()
                $matched = @($managers | Where-Object { $_.Command -eq $managerName })
                if ($matched.Count -gt 0) {
                    return $matched[0]
                }
            }
        } catch {
            # Malformed package.json - fall through to the npm default
        }
    }

    # Default to npm
    return @{ Lock = $null; Command = "npm"; Install = @("install") }
}

function Invoke-DevKitPackageInstall {
    <#
    .SYNOPSIS
        Runs the install command for a project's package manager.
    .PARAMETER Path
        The project directory to install in.
    .PARAMETER Manager
        Optional pre-resolved package manager (as returned by
        Get-DevKitPackageManager). Pass this when the caller already
        resolved the manager earlier (e.g. before deleting lock files), so
        this function does not need to re-derive it from a directory whose
        lock files may no longer be present. When omitted, the manager is
        auto-detected from $Path as before.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [hashtable]$Manager
    )

    $manager = $Manager
    if (-not $manager) {
        $manager = Get-DevKitPackageManager -Path $Path
    }

    if (-not (Test-DevKitCommand $manager.Command)) {
        throw "$($manager.Command) is not installed or not in PATH."
    }

    & $manager.Command @($manager.Install)
    if ($LASTEXITCODE -ne 0) {
        throw "Package install failed with exit code $LASTEXITCODE"
    }
}

function Invoke-DevKitPackageCacheClean {
    <#
    .SYNOPSIS
        Cleans the local cache for a project's package manager.
    .PARAMETER Path
        The project directory whose package manager cache to clean.
    .PARAMETER Manager
        Optional pre-resolved package manager (as returned by
        Get-DevKitPackageManager). Pass this when the caller already
        resolved the manager earlier (e.g. before deleting lock files), so
        this function does not need to re-derive it from a directory whose
        lock files may no longer be present. When omitted, the manager is
        auto-detected from $Path as before.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [hashtable]$Manager
    )

    $manager = $Manager
    if (-not $manager) {
        $manager = Get-DevKitPackageManager -Path $Path
    }

    if ($manager.Command -eq "npm") {
        if (-not (Test-DevKitCommand "npm")) { throw "npm is not installed or not in PATH." }
        npm cache clean --force | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "npm cache clean failed" }
    }
    elseif ($manager.Command -eq "pnpm") {
        if (-not (Test-DevKitCommand "pnpm")) { throw "pnpm is not installed or not in PATH." }
        pnpm store prune | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "pnpm store prune failed" }
    }
    elseif ($manager.Command -eq "yarn") {
        if (-not (Test-DevKitCommand "yarn")) { throw "yarn is not installed or not in PATH." }
        yarn cache clean --all | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "yarn cache clean failed" }
    }
    elseif ($manager.Command -eq "bun") {
        if (-not (Test-DevKitCommand "bun")) { throw "bun is not installed or not in PATH." }
        bun pm cache rm | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "bun cache clean failed" }
    }
}

# ==================== PORT / PROCESS HELPERS ====================

function Get-DevKitNeverKillProcessNames {
    <#
    .SYNOPSIS
        The process names no DevKit tool may ever stop (lowercase, no .exe).
    .DESCRIPTION
        Processes Windows misbehaves or dies without. DevKit always runs
        elevated, so nothing else stands between a kill tool and these:
        stopping the svchost that owns port 135 (the RPC endpoint mapper),
        or csrss/wininit/lsass, makes Windows force a shutdown. One list for
        every tool that stops processes - Close-OutSession.ps1 reads it too,
        so the tools cannot drift apart on what is untouchable.

        Returned from a function rather than held in a $script: variable so
        it resolves the same way however this file was loaded (dot-sourced
        by a tool, imported through DevKit.Core, skipped by the load guard).
    #>
    return @(
        'system', 'idle', 'registry', 'secure system', 'memory compression',
        'smss', 'csrss', 'wininit', 'winlogon', 'services', 'svchost', 'lsass',
        'lsaiso', 'fontdrvhost', 'dwm', 'werfault', 'sihost', 'taskhostw',
        'runtimebroker', 'msmpeng', 'nissrv', 'searchindexer', 'spoolsv'
    )
}

function Get-DevKitProcessAncestry {
    <#
    .SYNOPSIS
        A process's pid plus every ancestor pid above it.
    .DESCRIPTION
        Pure - it reads only $Processes - so the walk is unit-testable
        against a synthetic process table.

        Win32_Process.ParentProcessId is a number RECORDED at creation, so a
        recycled pid can make a stranger look like an ancestor. That is the
        harmless direction here: the only thing this list does is EXCLUDE
        pids from being killed, so a false positive costs one un-stopped
        process while a false negative could kill the app that launched us.
        The visited set makes a pid-reuse cycle (A parents B, B parents A)
        terminate instead of spinning.
    .PARAMETER ProcessId
        The pid to walk up from (included in the result).
    .PARAMETER Processes
        Rows exposing ProcessId and ParentProcessId, e.g. from
        Get-CimInstance Win32_Process. Empty is valid: the result is then
        just $ProcessId itself.
    .OUTPUTS
        [int[]] - self first, then each ancestor, nearest first.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [object[]]$Processes = @()
    )

    $byId = @{}
    foreach ($row in @($Processes)) {
        if ($null -eq $row) { continue }
        $rowId = 0
        if (-not [int]::TryParse([string]$row.ProcessId, [ref]$rowId)) { continue }
        if (-not $byId.ContainsKey($rowId)) { $byId[$rowId] = $row }
    }

    $chain = @()
    $seen = @{}
    $current = $ProcessId
    while ($current -gt 0 -and -not $seen.ContainsKey($current)) {
        $chain += $current
        $seen[$current] = $true
        if (-not $byId.ContainsKey($current)) { break }
        $parent = 0
        if (-not [int]::TryParse([string]$byId[$current].ParentProcessId, [ref]$parent)) { break }
        $current = $parent
    }
    return , @($chain)
}

function Get-DevKitOwnProcessTreeIds {
    <#
    .SYNOPSIS
        This process's pid plus every ancestor's - the pids a kill tool must
        never stop, because they are the tool itself, the sidecar that
        spawned it, the DevKit app above that, or the terminal the user ran
        it from.
    .DESCRIPTION
        One Win32_Process snapshot (two properties). If the snapshot cannot
        be taken the result degrades to just $PID rather than failing the
        tool - the name-based refusals in Get-DevKitKillRefusalReason still
        apply.
    #>
    try {
        $snapshot = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId -ErrorAction Stop)
        $chain = Get-DevKitProcessAncestry -ProcessId $PID -Processes $snapshot
        return , @($chain)
    } catch {
        return , @($PID)
    }
}

function Get-DevKitKillRefusalReason {
    <#
    .SYNOPSIS
        Why a process must NOT be stopped, or $null when stopping it is fine.
    .DESCRIPTION
        The floor every kill path in tools/ shares. Reserved pids and
        DevKit's own tree are refused before any name rule. An empty or
        unknown name is allowed: these rules exist to stop a tool from
        killing Windows or itself, not to second-guess a target the user
        picked - a tool that wants a stricter rule (Close-OutSession only
        stops recognized dev runtimes) layers it on top.
    .PARAMETER ProcessId
        The candidate's pid.
    .PARAMETER Name
        The candidate's process name, with or without a .exe suffix.
    .PARAMETER ProtectedPids
        Pids that must survive - normally Get-DevKitOwnProcessTreeIds.
    .OUTPUTS
        [string] reason, or $null when the process may be stopped.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [AllowEmptyString()][AllowNull()][string]$Name = '',
        [int[]]$ProtectedPids = @()
    )

    if ($ProcessId -le 0 -or $ProcessId -eq 4) { return 'reserved system process' }
    if (@($ProtectedPids) -contains $ProcessId) { return "DevKit's own process tree" }

    $normalized = ([string]$Name).Trim().ToLowerInvariant()
    if ($normalized.EndsWith('.exe')) {
        $normalized = $normalized.Substring(0, $normalized.Length - 4)
    }
    if ($normalized -and ((Get-DevKitNeverKillProcessNames) -contains $normalized)) {
        return "protected system process '$normalized'"
    }
    return $null
}

function Get-DevKitProcessByPort {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port
    )

    # ONLY a real listener counts as "the process on this port". For about
    # two minutes after a dev server stops, closed-connection leftovers
    # (TIME_WAIT rows with OwningProcess 0) linger on its port; this used to
    # fall back to the first row of any state, so every port tool announced
    # "PID 0 (Idle)" as the owner of a port nothing was listening on, and
    # Kill-Port answered "Refusing to target PID 0" where the truth was
    # "nothing is listening".
    $connections = @(Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue)
    $connection = $connections | Where-Object { $_.State -eq 'Listen' -and $_.OwningProcess -ne 0 } | Select-Object -First 1
    if (-not $connection) {
        return $null
    }

    $process = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
    return [PSCustomObject]@{
        Port    = $Port
        PID     = $connection.OwningProcess
        Name    = if ($process) { $process.ProcessName } else { "Unknown" }
        Path    = if ($process) { $process.Path } else { $null }
    }
}

function ConvertFrom-DevKitExcludedPortRanges {
    <#
    .SYNOPSIS
        Parses `netsh interface ipv4 show excludedportrange protocol=tcp`
        output into a list of port-range records.
    .DESCRIPTION
        The netsh table is localized (its header text varies by Windows
        display language), so parsing never matches literal header words:
        a line is a data row when its first two whitespace-separated tokens
        both parse as integers (the table's Start Port / End Port columns).
        That single rule skips the title, blank lines, the header row, the
        dashed separator row, and the trailing "* - Administered port
        exclusions." footnote in every locale. A row whose two columns are
        equal (e.g. "5357  5357") is a real single-port exclusion and is
        returned as a range with Start -eq End; any third column netsh may
        print (the "*" marker) is ignored.
    .PARAMETER Output
        The full captured text of the netsh command (may be empty).
    .OUTPUTS
        An array (possibly empty) of hashtables @{ Start = [int]; End = [int] },
        in the order the rows appeared. Always a real array - the "return ,$"
        pattern keeps a single result from unrolling to a bare hashtable.
    .EXAMPLE
        $ranges = ConvertFrom-DevKitExcludedPortRanges -Output (netsh interface ipv4 show excludedportrange protocol=tcp | Out-String)
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Output)

    $results = @()
    if (-not [string]::IsNullOrWhiteSpace($Output)) {
        foreach ($line in ($Output -split "\r?\n")) {
            $tokens = @($line.Trim() -split '\s+')
            if ($tokens.Count -lt 2) { continue }
            $start = 0
            $end = 0
            if ([int]::TryParse($tokens[0], [ref]$start) -and [int]::TryParse($tokens[1], [ref]$end)) {
                $results += @{ Start = $start; End = $end }
            }
        }
    }
    return ,$results
}

# ==================== FOLDER / FILE BROWSER ====================

function Initialize-DevKitFormsInterop {
    <#
    .SYNOPSIS
        One-time native interop compile for a real console-window owner (so a
        dialog z-orders correctly above the console instead of floating
        globally topmost). Idempotent and cheap after first use - done lazily
        here rather than at dot-source time, because most tool runs never
        show a dialog and shouldn't pay the WinForms/C# compile cost.
    #>
    if ('DevKit.NativeMethods' -as [type]) { return }
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    Add-Type -ReferencedAssemblies 'System.Windows.Forms' -TypeDefinition @'
using System;
using System.Windows.Forms;
namespace DevKit {
    public static class NativeMethods {
        [System.Runtime.InteropServices.DllImport("kernel32.dll")]
        public static extern IntPtr GetConsoleWindow();
    }
    public class Win32Window : IWin32Window {
        private IntPtr _handle;
        public Win32Window(IntPtr handle) { _handle = handle; }
        public IntPtr Handle { get { return _handle; } }
    }
}
'@ -ErrorAction SilentlyContinue
}

function Show-DevKitFolderBrowser {
    <#
    .SYNOPSIS
        Shows a folder-browse dialog from a console host, regardless of the
        host's own apartment state.
    .DESCRIPTION
        Windows PowerShell 5.1's console host defaults to STA; pwsh's
        console host defaults to MTA. FolderBrowserDialog is OLE-based and
        requires STA. Rather than depend on whichever apartment state the
        calling host happens to be in (which silently varies by which
        PowerShell launched DevKit), this spins up a dedicated Runspace with
        ApartmentState=STA, shows the dialog there, and marshals only the
        resulting path string back out.
    .PARAMETER Description
        Text shown at the top of the dialog.
    .PARAMETER InitialDirectory
        Directory the dialog should start in, if it exists.
    .OUTPUTS
        [string] the chosen full path, or $null if the user cancelled or the
        folder browser is unavailable on this machine.
    #>
    [CmdletBinding()]
    param(
        [string]$Description = "Select a project folder",
        [string]$InitialDirectory
    )

    Initialize-DevKitFormsInterop   # process-wide types used inside the STA runspace below

    try {
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
        $rs.ApartmentState = [System.Threading.ApartmentState]::STA
        $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $rs.Open()
    } catch {
        Write-DevKitError "Could not start a folder-browser session: $_"
        return $null
    }

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs

    [void]$ps.AddScript({
        param($Description, $InitialDirectory)

        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        } catch {
            return @{ Ok = $false; Error = "Folder browser unavailable on this PowerShell install (Desktop Runtime not found). Type the path manually, or reinstall PowerShell via the official MSI/winget package." }
        }

        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = $Description
        $dialog.ShowNewFolderButton = $true
        if ($InitialDirectory -and (Test-Path $InitialDirectory)) {
            $dialog.SelectedPath = $InitialDirectory
        }

        $consoleHwnd = [DevKit.NativeMethods]::GetConsoleWindow()
        $owner = $null
        if ($consoleHwnd -ne [IntPtr]::Zero) {
            $owner = New-Object DevKit.Win32Window ($consoleHwnd)
        }

        $result = if ($owner) { $dialog.ShowDialog($owner) } else { $dialog.ShowDialog() }

        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            return @{ Ok = $true; Path = $dialog.SelectedPath }
        }
        return @{ Ok = $true; Path = $null }
    }).AddArgument($Description).AddArgument($InitialDirectory)

    try {
        $outcome = ($ps.Invoke() | Select-Object -First 1)
    } catch {
        Write-DevKitError "Folder browser failed: $_"
        $ps.Dispose(); $rs.Close(); $rs.Dispose()
        return $null
    }
    $ps.Dispose()
    $rs.Close()
    $rs.Dispose()

    if (-not $outcome -or -not $outcome.Ok) {
        if ($outcome -and $outcome.Error) { Write-DevKitError $outcome.Error }
        return $null
    }
    return $outcome.Path
}


# ==================== PROJECT REGISTRY ====================

function Get-DevKitProjectsFile {
    $dir = Join-Path $env:LOCALAPPDATA "NorthstarDevKit"
    if (-not (Test-Path $dir)) {
        # Best-effort, same as Get-DevKitSettingsFile: downstream readers
        # tolerate the registry file simply being absent.
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { }
    }
    return Join-Path $dir "projects.json"
}

function Save-DevKitProjectRegistry {
    param([Parameter(Mandatory = $true)]$Registry)

    $path = Get-DevKitProjectsFile
    $tempPath = "$path.tmp.$PID"
    try {
        # Merge over whatever is on disk right now instead of blindly
        # overwriting: another DevKit process (e.g. the long-lived widget) may
        # have added or updated a project since this caller loaded its copy,
        # and last-writer-wins would silently drop that. The caller's version
        # wins per project id, and its activeProjectId wins outright. An
        # on-disk project this process never read (absent from the
        # Get-DevKitProjectRegistry baseline, i.e. a concurrent add) is kept;
        # one the caller read and deliberately dropped (e.g.
        # Remove-DevKitLinkedProject) stays dropped. A PARSE failure falls
        # back to the caller's copy as-is; a file that cannot be READ fails
        # the save instead (Read-DevKitStoreFile) - writing the caller's
        # copy over projects it could not see would drop them.
        $raw = Read-DevKitStoreFile -Path $path
        try {
            if ($null -ne $raw) {
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    $jsonArgs = Get-DevKitJsonReadArgs
                    $onDisk = $raw | ConvertFrom-Json @jsonArgs -ErrorAction Stop
                    if ($null -ne $onDisk.projects) {
                        $callerIds = @($Registry.projects | ForEach-Object { $_.id })
                        $kept = @()
                        foreach ($diskProject in @($onDisk.projects)) {
                            if ($callerIds -contains $diskProject.id) { continue }
                            if ($null -eq $script:DevKitProjectRegistryReadIds -or
                                -not ($script:DevKitProjectRegistryReadIds -contains $diskProject.id)) {
                                $kept += $diskProject
                            }
                        }
                        if ($kept.Count -gt 0) {
                            $Registry.projects = @(@($Registry.projects) + $kept)
                        }
                    }
                }
            }
        } catch { }
        $Registry | ConvertTo-Json -Depth 6 | Set-Content -Path $tempPath -Encoding UTF8
        Move-Item -Path $tempPath -Destination $path -Force
    } catch {
        if (Test-Path $tempPath) { Remove-Item $tempPath -Force -ErrorAction SilentlyContinue }
        throw "Failed to save project registry: $_"
    }
}

function Get-DevKitProjectRegistry {
    <# .OUTPUTS PSCustomObject with .schemaVersion / .activeProjectId / .projects (array, always) #>
    $path = Get-DevKitProjectsFile
    $empty = [PSCustomObject]@{ schemaVersion = 1; activeProjectId = $null; projects = @() }

    # Baseline of project ids this process last read, for
    # Save-DevKitProjectRegistry's merge: it distinguishes "on disk but the
    # caller never saw it" (a concurrent add - keep) from "the caller saw it
    # and deliberately dropped it" (a Remove - keep the deletion).
    $script:DevKitProjectRegistryReadIds = @()

    if (-not (Test-Path $path)) { return $empty }

    # Unreadable right now is NOT corrupt: answer this call with an empty
    # registry and leave the file alone. The empty read-ids baseline set
    # above means a save made off this answer still keeps every project on
    # disk (Save-DevKitProjectRegistry's merge), so nothing is lost.
    $raw = $null
    try { $raw = Read-DevKitStoreFile -Path $path } catch { return $empty }

    try {
        if ([string]::IsNullOrWhiteSpace($raw)) { return $empty }
        $jsonArgs = Get-DevKitJsonReadArgs
        $data = $raw | ConvertFrom-Json @jsonArgs -ErrorAction Stop
        # ConvertFrom-Json returns a bare PSCustomObject (not a 1-item array)
        # when "projects" has exactly one element - always wrap with @().
        $projects = @($data.projects)
        $script:DevKitProjectRegistryReadIds = @($projects | ForEach-Object { $_.id })
        return [PSCustomObject]@{
            schemaVersion   = $data.schemaVersion
            activeProjectId = $data.activeProjectId
            projects        = $projects
        }
    } catch {
        # A corrupt/hand-edited file must never crash DevKit.ps1 - Show-Header
        # reads the registry on every menu redraw. Quarantine and start clean.
        $backupPath = "$path.corrupt-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
        try { Move-Item -Path $path -Destination $backupPath -Force -ErrorAction SilentlyContinue } catch {}
        Write-DevKitError "Project registry was corrupted and has been reset. Backup: $backupPath"
        return $empty
    }
}

function Get-DevKitLinkedProjects {
    <# .OUTPUTS array of project PSCustomObjects, each with an extra computed .Missing [bool] #>
    $registry = Get-DevKitProjectRegistry
    $result = @()
    foreach ($p in $registry.projects) {
        $missing = -not (Test-Path -LiteralPath $p.path)
        $result += ($p | Select-Object *, @{ Name = 'Missing'; Expression = { $missing } })
    }
    return $result
}

function Get-DevKitProjectTags {
    param([Parameter(Mandatory = $true)][string]$Path)
    $tags = @()
    if (Test-Path (Join-Path $Path "package.json")) { $tags += "node" }
    if (Test-Path (Join-Path $Path ".git")) { $tags += "git" }
    if ((Test-Path (Join-Path $Path "next.config.js")) -or
        (Test-Path (Join-Path $Path "next.config.mjs")) -or
        (Test-Path (Join-Path $Path "next.config.ts"))) { $tags += "nextjs" }
    if ((Test-Path (Join-Path $Path "vite.config.js")) -or
        (Test-Path (Join-Path $Path "vite.config.ts"))) { $tags += "vite" }
    if ((Test-Path (Join-Path $Path "Dockerfile")) -or
        (Test-Path (Join-Path $Path "docker-compose.yml"))) { $tags += "docker" }
    return $tags
}

function Add-DevKitLinkedProject {
    <#
    .PARAMETER Path  Folder to link (must exist).
    .PARAMETER Name  Display name; defaults to the leaf folder name.
    .OUTPUTS the (new or matched-existing) project PSCustomObject.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Name
    )

    $resolved = Resolve-DevKitDirectory -Path $Path
    $registry = Get-DevKitProjectRegistry
    $projects = @($registry.projects)

    $existing = $projects | Where-Object {
        [string]::Equals($_.path.TrimEnd('\'), $resolved.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1

    if ($existing) {
        return (Update-DevKitProjectLastUsed -Id $existing.id)
    }

    if (-not $Name) { $Name = Split-Path -Path $resolved -Leaf }

    $newProject = [PSCustomObject]@{
        id          = [guid]::NewGuid().ToString()
        name        = $Name
        path        = $resolved
        tags        = @(Get-DevKitProjectTags -Path $resolved)
        pinned      = $false
        addedUtc    = [DateTime]::UtcNow.ToString("o")
        lastUsedUtc = [DateTime]::UtcNow.ToString("o")
        useCount    = 1
    }

    $registry.projects = @($projects + $newProject)
    Save-DevKitProjectRegistry -Registry $registry
    return $newProject
}

function Update-DevKitProjectLastUsed {
    param([Parameter(Mandatory = $true)][string]$Id)
    $registry = Get-DevKitProjectRegistry
    $projects = @($registry.projects)
    $match = $null
    foreach ($p in $projects) {
        if ($p.id -eq $Id) {
            $p.lastUsedUtc = [DateTime]::UtcNow.ToString("o")
            $p.useCount = [int]$p.useCount + 1
            $match = $p
        }
    }
    $registry.projects = $projects
    Save-DevKitProjectRegistry -Registry $registry
    return $match
}

function Remove-DevKitLinkedProject {
    param([Parameter(Mandatory = $true)][string]$Id)
    $registry = Get-DevKitProjectRegistry
    $registry.projects = @($registry.projects | Where-Object { $_.id -ne $Id })
    if ($registry.activeProjectId -eq $Id) { $registry.activeProjectId = $null }
    Save-DevKitProjectRegistry -Registry $registry
    # Invalidate DevKit.ps1's Show-Header cache: the removed project may have
    # been the active one (same contract as Set/Clear-DevKitActiveProject).
    $global:DevKitActiveProjectCache = $null
}

function Rename-DevKitLinkedProject {
    param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][string]$NewName)
    $registry = Get-DevKitProjectRegistry
    foreach ($p in $registry.projects) { if ($p.id -eq $Id) { $p.name = $NewName } }
    Save-DevKitProjectRegistry -Registry $registry
    # Invalidate DevKit.ps1's Show-Header cache: it may be displaying the old name.
    $global:DevKitActiveProjectCache = $null
}

function Set-DevKitProjectPinned {
    param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][bool]$Pinned)
    $registry = Get-DevKitProjectRegistry
    foreach ($p in $registry.projects) { if ($p.id -eq $Id) { $p.pinned = $Pinned } }
    Save-DevKitProjectRegistry -Registry $registry
}

function Repair-DevKitLinkedProject {
    <# Relinks an existing entry (keeps id/name/tags/history) to a new path. #>
    param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][string]$NewPath)
    $resolved = Resolve-DevKitDirectory -Path $NewPath
    $registry = Get-DevKitProjectRegistry
    foreach ($p in $registry.projects) {
        if ($p.id -eq $Id) {
            $p.path = $resolved
            $p.tags = @(Get-DevKitProjectTags -Path $resolved)
            $p.lastUsedUtc = [DateTime]::UtcNow.ToString("o")
        }
    }
    Save-DevKitProjectRegistry -Registry $registry
    # Invalidate DevKit.ps1's Show-Header cache: it may be displaying the old path.
    $global:DevKitActiveProjectCache = $null
}

function Get-DevKitActiveProject {
    <# .OUTPUTS the active project PSCustomObject (with computed .Missing), or $null #>
    $registry = Get-DevKitProjectRegistry
    if (-not $registry.activeProjectId) { return $null }
    $match = $registry.projects | Where-Object { $_.id -eq $registry.activeProjectId } | Select-Object -First 1
    if (-not $match) { return $null }
    $missing = -not (Test-Path -LiteralPath $match.path)
    return ($match | Select-Object *, @{ Name = 'Missing'; Expression = { $missing } })
}

function Set-DevKitActiveProject {
    param([Parameter(Mandatory = $true)][string]$Id)
    $registry = Get-DevKitProjectRegistry
    $registry.activeProjectId = $Id
    Save-DevKitProjectRegistry -Registry $registry
    Update-DevKitProjectLastUsed -Id $Id | Out-Null
    $global:DevKitActiveProjectCache = $null
}

function Clear-DevKitActiveProject {
    $registry = Get-DevKitProjectRegistry
    $registry.activeProjectId = $null
    Save-DevKitProjectRegistry -Registry $registry
    $global:DevKitActiveProjectCache = $null
}

function Resolve-DevKitMissingActiveProject {
    <#
    .SYNOPSIS
        Interactively resolves a linked/active project whose saved path no
        longer exists on disk (moved, renamed, or deleted).
    .OUTPUTS
        The repaired project PSCustomObject, or $null if the caller should
        fall through to the normal interactive picker.
    #>
    param([Parameter(Mandatory = $true)]$Project)

    Write-Host ""
    Write-Host "  ! Project '$($Project.name)' points to a path that no longer exists:" -ForegroundColor DarkYellow
    Write-Host "      $($Project.path)" -ForegroundColor DarkYellow
    Write-Host "    It may have been moved, renamed, or deleted." -ForegroundColor DarkYellow
    Write-Host ""
    Write-Host "    [1] Locate it now (browse to the new location and relink)"
    Write-Host "    [2] Unlink it and pick a different project"
    Write-Host "    [3] Type the corrected path manually"
    Write-Host "    [0] Cancel"
    $c = Read-Host "Select option"

    switch ($c) {
        '1' {
            $seed = Split-Path -Path $Project.path -Parent
            if (-not (Test-Path $seed)) { $seed = $null }
            $newPath = Show-DevKitFolderBrowser -Description "Locate '$($Project.name)'" -InitialDirectory $seed
            if ($newPath) {
                Repair-DevKitLinkedProject -Id $Project.id -NewPath $newPath
                Set-DevKitActiveProject -Id $Project.id
                return (Get-DevKitActiveProject)
            }
            return $null
        }
        '2' {
            Remove-DevKitLinkedProject -Id $Project.id
            return $null
        }
        '3' {
            $typed = Read-Host "Enter corrected path"
            if (Test-Path $typed) {
                Repair-DevKitLinkedProject -Id $Project.id -NewPath $typed
                Set-DevKitActiveProject -Id $Project.id
                return (Get-DevKitActiveProject)
            }
            Write-Host "  ERROR: Path not found: $typed" -ForegroundColor Red
            return $null
        }
        default { return $null }
    }
}

function Invoke-DevKitManageProjects {
    <#
    .SYNOPSIS
        Rename / pin / unlink / relink submenu for the linked-projects list.
    #>
    while ($true) {
        Clear-Host
        Write-Host "=============================================" -ForegroundColor Cyan
        Write-Host "  Manage Linked Projects" -ForegroundColor Cyan
        Write-Host "=============================================" -ForegroundColor Cyan
        Write-Host ""

        $linked = @(Get-DevKitLinkedProjects | Sort-Object -Property @{Expression = 'pinned'; Descending = $true }, @{Expression = 'lastUsedUtc'; Descending = $true })

        if ($linked.Count -eq 0) {
            Write-Host "  No linked projects yet." -ForegroundColor Gray
            Read-Host "Press Enter to go back"
            return
        }

        for ($i = 0; $i -lt $linked.Count; $i++) {
            $p = $linked[$i]
            $pin = if ($p.pinned) { "*" } else { " " }
            if ($p.Missing) {
                Write-Host ("    [{0}] {1} {2,-22} {3,-30} !! MISSING" -f ($i + 1), $pin, $p.name, $p.path) -ForegroundColor DarkYellow
            } else {
                Write-Host ("    [{0}] {1} {2,-22} {3,-30} [{4}]" -f ($i + 1), $pin, $p.name, $p.path, ($p.tags -join ', '))
            }
        }
        Write-Host ""
        Write-Host "  Select a number to manage, or [0] to go back."
        $choice = Read-Host "Select project"

        if ($choice -eq '0' -or [string]::IsNullOrWhiteSpace($choice)) { return }
        if (-not ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $linked.Count)) { continue }

        $picked = $linked[[int]$choice - 1]
        Clear-Host
        Write-Host "  $($picked.name)  ($($picked.path))" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "    [R] Rename"
        Write-Host "    [P] Toggle pinned (currently: $($picked.pinned))"
        Write-Host "    [L] Relink to a new folder"
        Write-Host "    [U] Unlink"
        Write-Host "    [0] Back"
        $action = Read-Host "Select action"

        switch ($action) {
            { $_ -eq 'R' -or $_ -eq 'r' } {
                $newName = Read-Host "New name"
                if (-not [string]::IsNullOrWhiteSpace($newName)) {
                    Rename-DevKitLinkedProject -Id $picked.id -NewName $newName
                }
            }
            { $_ -eq 'P' -or $_ -eq 'p' } {
                Set-DevKitProjectPinned -Id $picked.id -Pinned (-not $picked.pinned)
            }
            { $_ -eq 'L' -or $_ -eq 'l' } {
                $newPath = Show-DevKitFolderBrowser -Description "Relink '$($picked.name)'"
                if ($newPath) { Repair-DevKitLinkedProject -Id $picked.id -NewPath $newPath }
            }
            { $_ -eq 'U' -or $_ -eq 'u' } {
                $confirm = Read-Host "Unlink '$($picked.name)'? (y/N)"
                if ($confirm -eq 'y') { Remove-DevKitLinkedProject -Id $picked.id }
            }
        }
    }
}

function Select-DevKitProject {
    <#
    .SYNOPSIS
        The shared "which project?" picker used everywhere DevKit.ps1 needs
        a project directory, replacing bare Read-Host path prompts.
    .DESCRIPTION
        Fast path: if an Active Project is set and its path still resolves,
        returns it immediately with no prompting at all. Otherwise shows an
        interactive picker: pick a linked project by number, browse for a
        new folder, use the current directory, or type a path manually.
        Whatever is chosen (other than "type manually" without linking)
        becomes the new Active Project.
    .PARAMETER Prompt
        Label shown at the top of the picker (e.g. the menu option's name).
    .PARAMETER ForceReprompt
        Bypass the silent "use Active Project" fast path even if one is set.
    .OUTPUTS
        [string] resolved project path, or $null if the user cancelled.
    #>
    [CmdletBinding()]
    param(
        [string]$Prompt = "Select a project",
        [switch]$ForceReprompt
    )

    if (-not $ForceReprompt) {
        $active = Get-DevKitActiveProject
        if ($active -and -not $active.Missing) {
            Write-Host "  Using active project: $($active.name)  ($($active.path))" -ForegroundColor Green
            Update-DevKitProjectLastUsed -Id $active.id | Out-Null
            return $active.path
        }
        if ($active -and $active.Missing) {
            $resolved = Resolve-DevKitMissingActiveProject -Project $active
            if ($resolved) { return $resolved.path }
            # falls through to the interactive picker below
        }
    }

    while ($true) {
        Clear-Host
        Write-Host "=============================================" -ForegroundColor Cyan
        Write-Host "  Select Project -- $Prompt" -ForegroundColor Cyan
        Write-Host "=============================================" -ForegroundColor Cyan
        Write-Host ""

        $linked = @(Get-DevKitLinkedProjects | Sort-Object -Property @{Expression = 'pinned'; Descending = $true }, @{Expression = 'lastUsedUtc'; Descending = $true })

        if ($linked.Count -gt 0) {
            Write-Host "  Linked Projects (most recently used first):" -ForegroundColor White
            for ($i = 0; $i -lt $linked.Count; $i++) {
                $p = $linked[$i]
                $pin = if ($p.pinned) { "*" } else { " " }
                if ($p.Missing) {
                    Write-Host ("    [{0}] {1} {2,-22} {3,-30} !! MISSING" -f ($i + 1), $pin, $p.name, $p.path) -ForegroundColor DarkYellow
                } else {
                    Write-Host ("    [{0}] {1} {2,-22} {3,-30} [{4}]" -f ($i + 1), $pin, $p.name, $p.path, ($p.tags -join ', '))
                }
            }
            Write-Host ""
        }

        Write-Host "  ---------------------------------------------"
        Write-Host "    [B] Browse for folder..."
        Write-Host "    [C] Use current directory ($((Get-Location).Path))"
        Write-Host "    [T] Type a path manually"
        if ($linked.Count -gt 0) { Write-Host "    [M] Manage list (rename / pin / unlink / relink)" }
        Write-Host "    [0] Cancel"
        Write-Host "  ---------------------------------------------"
        $choice = Read-Host "Select project"

        if ($choice -eq '0' -or [string]::IsNullOrWhiteSpace($choice)) { return $null }

        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $linked.Count) {
            $picked = $linked[[int]$choice - 1]
            if ($picked.Missing) {
                $picked = Resolve-DevKitMissingActiveProject -Project $picked
                if (-not $picked) { continue }
            }
            Set-DevKitActiveProject -Id $picked.id
            return $picked.path
        }

        if ($choice -eq 'B' -or $choice -eq 'b') {
            $chosenPath = Show-DevKitFolderBrowser -Description "Select a project folder"
            if (-not $chosenPath) { continue }
            $project = Add-DevKitLinkedProject -Path $chosenPath
            Set-DevKitActiveProject -Id $project.id
            return $project.path
        }

        if ($choice -eq 'C' -or $choice -eq 'c') {
            $cur = (Get-Location).Path
            $project = Add-DevKitLinkedProject -Path $cur
            Set-DevKitActiveProject -Id $project.id
            return $project.path
        }

        if ($choice -eq 'T' -or $choice -eq 't') {
            $typed = Read-Host "Enter project path"
            if ([string]::IsNullOrWhiteSpace($typed) -or -not (Test-Path $typed)) {
                Write-Host "  ERROR: Path not found: $typed" -ForegroundColor Red
                Read-Host "Press Enter to continue"
                continue
            }
            $project = Add-DevKitLinkedProject -Path $typed
            Set-DevKitActiveProject -Id $project.id
            return $project.path
        }

        if (($choice -eq 'M' -or $choice -eq 'm') -and $linked.Count -gt 0) {
            Invoke-DevKitManageProjects
            continue
        }
    }
}

function Stop-DevKitNodeProcesses {
    <#
    .SYNOPSIS
        Stop Node processes that appear to belong to the given project path.
    .DESCRIPTION
        Uses the process command line to detect Node processes running code
        under the target directory. This is a heuristic; it will not catch
        every scenario, but it avoids the substring false positives of the
        previous implementation.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolved = Resolve-DevKitDirectory -Path $Path
    $pattern = "$resolved\"

    $procs = Get-CimInstance Win32_Process -Filter "Name='node.exe' or Name='bun.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            ($_.CommandLine -like "*`"$pattern*`"*" -or
             $_.CommandLine -like "*$pattern*")
        }

    $killed = 0
    foreach ($proc in $procs) {
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            $killed++
        } catch {
            # Ignore access-denied or already-exited processes
        }
    }

    return $killed
}
