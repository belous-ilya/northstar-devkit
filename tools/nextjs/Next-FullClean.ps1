#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Next.js Full Clean - Northstar DevKit
.DESCRIPTION
    Full Next.js project clean.
    Stops dev server, clears all caches (Next.js + Turbopack),
    deletes node_modules and lock files, reinstalls dependencies.
    Auto-detects package manager.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    The project directory. Defaults to current directory.
.PARAMETER StartDev
    Start dev server after cleaning.
.PARAMETER Force
    Skip confirmation prompt.
.EXAMPLE
    .\Next-FullClean.ps1
    .\Next-FullClean.ps1 -StartDev
    .\Next-FullClean.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [switch]$StartDev,
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) {
    . $CommonModule
} else {
    Write-Host "ERROR: Required module not found: $CommonModule" -ForegroundColor Red
    exit 1
}

try {
    $targetPath = Resolve-DevKitDirectory -Path $Path
} catch {
    Write-DevKitHeader "Next.js FULL CLEAN"
    Write-DevKitError $_
    exit 1
}

Write-DevKitHeader "Next.js FULL CLEAN"
Write-DevKitInfo "Path: $targetPath"

$manager = Get-DevKitPackageManager -Path $targetPath
Write-DevKitInfo "Package manager: $($manager.Command)"

# Checked BEFORE the confirmation and before anything is deleted: a reinstall
# that cannot run must not get as far as removing what it was going to rebuild.
$blocker = Get-DevKitReinstallBlocker -Path $targetPath -Manager $manager
if ($blocker) {
    Write-DevKitError "Cannot start: $blocker. Nothing was deleted."
    exit 1
}

if (-not $Force) {
    Write-Host "  WARNING: This will permanently delete:" -ForegroundColor Yellow
    Write-Host "    - .next, .turbo, node_modules/.cache, node_modules/.vite" -ForegroundColor Gray
    Write-Host "    - dist, .vite (build output)" -ForegroundColor Gray
    Write-Host "    - node_modules" -ForegroundColor Gray
    Write-Host "    - package-lock.json, yarn.lock, pnpm-lock.yaml, bun.lockb, bun.lock (put back if the reinstall fails)" -ForegroundColor Gray
    Write-Host ""
    $confirm = Read-Host "  Continue? (y/n)"
    if ($confirm -ne 'y') {
        Write-DevKitInfo "Cancelled."
        exit 0
    }
}

Invoke-DevKitInDirectory -Path $targetPath -ScriptBlock {
    $steps = @()
    # Shared with the step actions below (they run in child scopes).
    $state = @{ Locks = @() }

    $steps += @{
        Name = "Stop local node processes"
        Action = {
            $killed = Stop-DevKitNodeProcesses -Path .
            # Always emit output (and a newline) here regardless of $killed -
            # this step is excluded from the loop's generic Write-DevKitDone
            # call below, so without this the next step's step-header would
            # print on the same line when 0 processes were killed.
            Write-DevKitDone
            if ($killed -gt 0) {
                Write-DevKitInfo "Stopped $killed process(es)"
            }
        }
    }

    $steps += @{
        Name = "Clear Next.js and Turbopack caches"
        Action = {
            Clear-DevKitNodeCaches -Path . -IncludeTurbo -IncludeBuildOutput | Out-Null
        }
    }

    $steps += @{
        Name = "Delete node_modules"
        Action = {
            switch (Remove-DevKitNodeModulesWithStatus -Path .) {
                'Removed' { Write-DevKitDone }
                'Absent' { Write-DevKitSkip }
                default {
                    # Still there: something is holding files in it. Stop
                    # HERE, before the lock files are touched - installing
                    # over a half-deleted tree is worse than not starting.
                    throw "node_modules could not be fully removed - a running process (dev server, editor, antivirus) is still holding files in it. Close it and run this again. The lock files were not touched."
                }
            }
        }
    }

    $steps += @{
        Name = "Set lock files aside"
        Action = {
            # Renamed, not deleted: put back if the install below fails.
            $state.Locks = Move-DevKitLockFilesAside -Path (Get-Location).Path
        }
    }

    $steps += @{
        Name = "Clear package manager cache"
        Action = { Invoke-DevKitPackageCacheClean -Path . -Manager $manager }
    }

    $steps += @{
        Name = "Install dependencies"
        Action = { Invoke-DevKitPackageInstall -Path . -Manager $manager }
    }

    $stepNum = 1
    foreach ($step in $steps) {
        Write-DevKitStep "[$stepNum/$($steps.Count)] $($step.Name)"
        try {
            & $step.Action
            if ($step.Name -notin @("Delete node_modules", "Stop local node processes")) {
                Write-DevKitDone
            }
        } catch {
            Write-DevKitError $_
            if (@($state.Locks).Count -gt 0) {
                try {
                    Restore-DevKitLockFiles -Moved $state.Locks
                    Write-DevKitInfo "The previous lock file(s) were put back."
                } catch {
                    Write-Host "  WARNING: could not restore the lock file(s); they are beside the project as *.devkit-bak ($($_.Exception.Message))" -ForegroundColor Yellow
                }
            }
            exit 1
        }
        $stepNum++
    }
    # The install succeeded and wrote fresh lock files.
    Remove-DevKitLockFileBackups -Moved $state.Locks

    Write-Host "`n  DONE: Full clean complete!`n" -ForegroundColor Green

    if ($StartDev) {
        Write-Host "  Starting dev server...`n" -ForegroundColor Green
        try {
            if (-not (Test-DevKitCommand $manager.Command)) {
                throw "$($manager.Command) is not installed or not in PATH."
            }
            $env:NEXT_TELEMETRY_DISABLED = "1"
            & $manager.Command @("run", "dev")
        } catch {
            Write-DevKitError $_
        }
    }
}
