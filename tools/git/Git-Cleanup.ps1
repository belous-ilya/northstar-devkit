#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Git Cleanup - Northstar DevKit
.DESCRIPTION
    Cleans up a Git repository by pruning merged branches, running garbage
    collection, and optionally clearing the reflog. Shows before/after size.

    Garbage collection is a plain `git gc` by default, which keeps git's
    two-week grace period for unreachable objects. -Aggressive (and
    -ClearReflog) run `git gc --aggressive --prune=now` instead: slower, and
    anything unreachable is deleted immediately.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    Path to the Git repository. Defaults to current directory.
.PARAMETER ClearReflog
    Clear the reflog (use with caution - irreversible).
.PARAMETER Aggressive
    Run `git gc --aggressive --prune=now` instead of a plain `git gc`.
    Irreversible: unreachable objects are deleted now, not after two weeks.
.PARAMETER Force
    Skip confirmation prompts.
.PARAMETER DryRun
    Show what would be done without making changes.
.EXAMPLE
    .\Git-Cleanup.ps1
    .\Git-Cleanup.ps1 -Path "C:\my-project"
    .\Git-Cleanup.ps1 -ClearReflog -Force
    .\Git-Cleanup.ps1 -DryRun
#>[CmdletBinding()]
param(
    [string]$Path = ".",
    [switch]$ClearReflog,
    [switch]$Aggressive,
    [switch]$Force,
    [switch]$DryRun
)


$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path -LiteralPath $CommonModule) {
    . $CommonModule
} else {
    Write-Host "ERROR: Required module not found: $CommonModule" -ForegroundColor Red
    exit 1
}


try {
    $targetPath = Resolve-DevKitDirectory -Path $Path
} catch {
    Write-DevKitHeader "Git Cleanup"
    Write-DevKitError $_
    exit 1
}

Write-DevKitHeader "Git Cleanup"
Write-DevKitInfo "Path: $targetPath"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "`n  ERROR: Git not found in PATH.`n" -ForegroundColor Red
    exit 1
}

# Ask git rather than looking for a .git folder: a folder below the
# repository root has none, and neither does a submodule's working tree in
# the shape this used to test for.
$insideWorkTree = (git -C $targetPath rev-parse --is-inside-work-tree 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $insideWorkTree -ne 'true') {
    Write-Host "`n  ERROR: Not a Git repository.`n" -ForegroundColor Red
    exit 1
}

# Everything below acts on the WHOLE repository, wherever inside it -Path
# points. Name it, and say so plainly when it is not the folder that was
# given: a project folder that merely sits inside a larger repository (a
# monorepo, a dotfiles repo in the home folder) would otherwise have that
# outer repository's branches pruned with nothing on screen to show it.
$repoRoot = (git -C $targetPath rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ($repoRoot) {
    $repoRootNative = $repoRoot -replace '/', '\'
    Write-DevKitInfo "Repository: $repoRootNative"
    # --show-prefix is empty exactly at the repository root. Comparing the
    # two paths as text would misfire on a short (8.3) or differently
    # spelled form of the same folder.
    $insidePrefix = (git -C $targetPath rev-parse --show-prefix 2>$null | Out-String).Trim()
    if ($insidePrefix) {
        Write-Host "  NOTE: that is not the folder you gave - it is the repository that CONTAINS it." -ForegroundColor Yellow
        Write-Host "        Branch pruning and garbage collection apply to the whole repository." -ForegroundColor Yellow
    }
}

# Every step that fails is counted, so the run cannot end on "cleaned" (and
# exit 0) after printing errors.
$script:failures = 0

# Long-lived branches that are routinely level with the default branch -
# which makes them "merged" - and must never be offered for deletion.
$protectedBranches = @(
    'main', 'master', 'develop', 'development', 'dev', 'trunk',
    'staging', 'stage', 'production', 'prod', 'release', 'gh-pages'
)

try {
    Push-Location -LiteralPath $targetPath

# Get initial size
Write-Host "`n  Analyzing repository..." -ForegroundColor Cyan
$sizeBefore = (git count-objects -vH 2>$null | Select-String "size-pack" | ForEach-Object { $_.Line.Split(":")[1].Trim() })
if (-not $sizeBefore) { $sizeBefore = "Unknown" }
Write-Host "  Current pack size: $sizeBefore" -ForegroundColor Gray

# Fetch latest from remote (dry-run safe)
if (-not $DryRun) {
    Write-Host "`n  Fetching from remote..." -ForegroundColor Cyan
    git fetch --all --prune 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: git fetch --all --prune failed (exit code $LASTEXITCODE)." -ForegroundColor Red
        $script:failures++
    }
}

# Determine the actual default/integration branch so "merged" is measured
# against it instead of whatever happens to be checked out (HEAD).
$currentBranch = git branch --show-current 2>$null
$defaultBranch = $null

$symbolicRef = git symbolic-ref refs/remotes/origin/HEAD 2>$null
if ($LASTEXITCODE -eq 0 -and $symbolicRef) {
    $defaultBranch = ($symbolicRef -replace '^refs/remotes/origin/', '').Trim()
}

if (-not $defaultBranch) {
    $remoteShow = git remote show origin 2>$null
    if ($LASTEXITCODE -eq 0) {
        foreach ($line in $remoteShow) {
            if ($line -match 'HEAD branch:\s*(\S+)') {
                if ($matches[1] -and $matches[1] -ne '(unknown)') {
                    $defaultBranch = $matches[1]
                }
                break
            }
        }
    }
}

if (-not $defaultBranch) {
    foreach ($candidate in @('main', 'master', 'develop')) {
        git show-ref --verify --quiet "refs/heads/$candidate" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $defaultBranch = $candidate
            break
        }
    }
}

# Find merged branches (excluding current, the default branch, and the
# long-lived names in $protectedBranches, plus anything under release/ or
# hotfix/)
$mergedBranches = @()
if ($defaultBranch) {
    Write-Host "  Default branch: $defaultBranch" -ForegroundColor Gray
    $mergedBranches = git branch --merged $defaultBranch 2>$null |
        Where-Object { $_ -match '^\s+' } |
        ForEach-Object { $_.Trim() } |
        Where-Object {
            $_ -ne $currentBranch -and $_ -ne $defaultBranch -and
            $_ -notin $protectedBranches -and $_ -notmatch '^(release|hotfix)/'
        }
} else {
    Write-Host "  WARNING: Could not determine the default branch; skipping merged-branch detection." -ForegroundColor Yellow
}

if ($mergedBranches) {
    Write-Host "`n  Found merged branches:" -ForegroundColor Yellow
    $mergedBranches | ForEach-Object { Write-Host "    - $_" -ForegroundColor Gray }
    
    if ($DryRun) {
        Write-Host "  [DRY RUN] Would delete these branches" -ForegroundColor Magenta
    } else {
        $deleteBranches = Confirm-DevKitDestructiveAction -Always -Action "delete the merged branches listed above (git branch -d)" -Force:$Force
        if ($deleteBranches) {
            foreach ($branch in $mergedBranches) {
                try {
                    $deleteOutput = git branch -d $branch 2>&1
                    $deleteExit = $LASTEXITCODE
                    $deleteOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
                    if ($deleteExit -eq 0) {
                        Write-Host "  Deleted: $branch" -ForegroundColor Green
                    } else {
                        Write-Host "  ERROR deleting $branch`: $deleteOutput" -ForegroundColor Red
                        $script:failures++
                    }
                } catch {
                    Write-Host "  ERROR deleting $branch`: $_" -ForegroundColor Red
                    $script:failures++
                }
            }
        }
    }
} else {
    Write-Host "`n  No merged branches to clean up." -ForegroundColor Green
}

# Prune remote-tracking branches. A repository with no 'origin' (local
# only, or a differently named remote) has nothing to prune there, and
# asking anyway is an error from git that says nothing about the cleanup.
$hasOrigin = @(git remote 2>$null) -contains 'origin'
if (-not $hasOrigin) {
    Write-Host "`n  No 'origin' remote; skipping remote-tracking prune." -ForegroundColor Gray
} elseif ($DryRun) {
    Write-Host "`n  [DRY RUN] Would prune remote-tracking branches" -ForegroundColor Magenta
} else {
    Write-Host "`n  Pruning remote-tracking branches..." -ForegroundColor Cyan
    git remote prune origin 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: git remote prune origin failed (exit code $LASTEXITCODE)." -ForegroundColor Red
        $script:failures++
    }
}

# Garbage collection, in one of two strengths. Local helper so the
# exit-code handling isn't duplicated between the standalone pass below and
# the post-reflog-clear pass.
#
# The DEFAULT is a plain `git gc`: it repacks and prunes only objects that
# have been unreachable for git's own two-week grace period, so a commit
# orphaned by mistake yesterday (a bad reset, a dropped stash) can still be
# rescued. This tool used to run `--aggressive --prune=now` on every use -
# deleting every unreachable object immediately, with no way back, and
# burning minutes of CPU on a repack git's own documentation advises against
# for routine use - behind a button labelled "cleanup".
#
# -Thorough is that old behaviour, now explicit: -Aggressive on the command
# line, or -ClearReflog, whose whole purpose is to make objects unreachable
# and gone.
function Invoke-DevKitGitGc {
    param([switch]$Thorough)
    if ($Thorough) {
        Write-Host "  Running aggressive garbage collection (unreachable objects are deleted now)..." -ForegroundColor Cyan
        $gcArgs = @('gc', '--aggressive', '--prune=now')
    } else {
        Write-Host "  Running garbage collection..." -ForegroundColor Cyan
        $gcArgs = @('gc')
    }
    git @gcArgs 2>&1 | ForEach-Object {
        if ($_ -match '^(Counting|Compressing|Writing|Total)') {
            Write-Host "    $_" -ForegroundColor DarkGray
        }
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: git $($gcArgs -join ' ') failed (exit code $LASTEXITCODE)." -ForegroundColor Red
        $script:failures++
    }
}

# Garbage collection. When -ClearReflog is also set, skip this pre-clear pass
# entirely: the post-reflog-clear pass below is the only one that matters,
# since it fully supersedes anything gc'd here.
if ($DryRun) {
    Write-Host "  [DRY RUN] Would run garbage collection" -ForegroundColor Magenta
} elseif ($ClearReflog) {
    Write-Host "`n  Skipping pre-reflog garbage collection (will run once after reflog clear)." -ForegroundColor Gray
} else {
    $gcAction = if ($Aggressive) { "run AGGRESSIVE garbage collection (--prune=now is irreversible)" } else { "run garbage collection" }
    $runGc = Confirm-DevKitDestructiveAction -Always -Action $gcAction -Force:$Force
    if ($runGc) {
        Write-Host ""
        Invoke-DevKitGitGc -Thorough:$Aggressive
    } else {
        Write-Host "  Skipped garbage collection." -ForegroundColor Yellow
    }
}

# Clear reflog if requested
if ($ClearReflog) {
    if ($DryRun) {
        Write-Host "  [DRY RUN] Would clear reflog" -ForegroundColor Magenta
    } else {
        if (Confirm-DevKitDestructiveAction -Always -Action "clear the reflog (irreversible)" -Force:$Force) {
            Write-Host "  Clearing reflog..." -ForegroundColor Cyan
            git reflog expire --expire=now --all 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  ERROR: git reflog expire failed (exit code $LASTEXITCODE)." -ForegroundColor Red
                $script:failures++
            } else {
                Write-Host "  Reflog cleared." -ForegroundColor Green
            }
        } else {
            Write-Host "  Skipped reflog clear." -ForegroundColor Yellow
        }

        # This is the only gc pass when -ClearReflog is set (the pre-clear pass
        # above is skipped), so it runs here regardless of the reflog answer
        # above - otherwise declining the reflog prompt would mean gc never
        # runs at all for this invocation.
        if (Confirm-DevKitDestructiveAction -Always -Action "run garbage collection with --prune=now (irreversible)" -Force:$Force) {
            Invoke-DevKitGitGc -Thorough
        } else {
            Write-Host "  Skipped garbage collection." -ForegroundColor Yellow
        }
    }
}

# Get final size
if (-not $DryRun) {
    Write-Host "`n  Analyzing results..." -ForegroundColor Cyan
    $sizeAfter = (git count-objects -vH 2>$null | Select-String "size-pack" | ForEach-Object { $_.Line.Split(":")[1].Trim() })
    if (-not $sizeAfter) { $sizeAfter = "Unknown" }
    
    Write-Host "`n  ===================================" -ForegroundColor Cyan
    Write-Host "  Size Before: $sizeBefore" -ForegroundColor Gray
    Write-Host "  Size After:  $sizeAfter" -ForegroundColor Gray
    Write-Host "  ===================================" -ForegroundColor Cyan
    if ($script:failures -gt 0) {
        Write-Host "`n  FINISHED WITH ERRORS: $($script:failures) step(s) failed - see the ERROR lines above.`n" -ForegroundColor Red
    } else {
        Write-Host "`n  DONE: Git repository cleaned!`n" -ForegroundColor Green
    }
} else {
    Write-Host "`n  [DRY RUN] No changes made.`n" -ForegroundColor Magenta
}
} finally {
    Pop-Location
}
if ($script:failures -gt 0) { exit 1 }
exit 0
