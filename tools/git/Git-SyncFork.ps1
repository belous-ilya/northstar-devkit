#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Git Sync Fork - Northstar DevKit
.DESCRIPTION
    Sync a forked repository with its upstream remote.
    Fetches upstream, merges or rebases changes, and pushes to origin.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    Path to the forked repository. Defaults to current directory.
.PARAMETER UpstreamRemote
    Name of the upstream remote. Default: 'upstream'
.PARAMETER OriginRemote
    Name of the origin remote. Default: 'origin'
.PARAMETER Branch
    Branch to sync. Default: current branch or 'main'
.PARAMETER Rebase
    Use rebase instead of merge for syncing.
.PARAMETER Force
    Skip confirmation prompts.
.EXAMPLE
    .\Git-SyncFork.ps1
    .\Git-SyncFork.ps1 -Path "C:\my-fork"
    .\Git-SyncFork.ps1 -UpstreamRemote "upstream" -Rebase
    .\Git-SyncFork.ps1 -Branch "develop"
#>[CmdletBinding()]
param(
    [string]$Path = ".",
    [string]$UpstreamRemote = "upstream",
    [string]$OriginRemote = "origin",
    [string]$Branch = "",
    [switch]$Rebase,
    [switch]$Force
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
    Write-DevKitHeader "Git Sync Fork"
    Write-DevKitError $_
    exit 1
}

Write-DevKitHeader "Git Sync Fork"
Write-DevKitInfo "Path: $targetPath"

try {
    Push-Location -LiteralPath $targetPath

    # Verify Git repo
    if (-not (Test-Path -LiteralPath ".git")) {
        Write-Host "`n  ERROR: Not a Git repository.`n" -ForegroundColor Red
        exit 1
    }

    # Check git availability
    try {
        $null = git --version 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "`n  ERROR: Git not found in PATH.`n" -ForegroundColor Red
            exit 1
        }
    } catch {
        Write-Host "`n  ERROR: Git not found in PATH.`n" -ForegroundColor Red
        exit 1
    }

    # Determine branch
    if (-not $Branch) {
        $Branch = git branch --show-current 2>$null
        if (-not $Branch) {
            git show-ref --verify --quiet refs/heads/main 2>$null
            if ($LASTEXITCODE -eq 0) {
                $Branch = "main"
            } else {
                git show-ref --verify --quiet refs/heads/master 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $Branch = "master"
                } else {
                    Write-Host "`n  ERROR: Could not determine branch. Please specify with -Branch.`n" -ForegroundColor Red
                    exit 1
                }
            }
        }
    }

    Write-Host "  Branch: $Branch" -ForegroundColor Gray
    Write-Host "  Strategy: $(if($Rebase){'Rebase'}else{'Merge'})" -ForegroundColor Gray
    Write-Host ""

    # Check for an in-progress merge/rebase left over from a prior failed
    # sync before the generic dirty-tree check, so we can give targeted
    # continue/abort guidance instead of a misleading "commit or stash" nudge.
    $gitDir = Join-Path $targetPath ".git"
    $mergeHeadPath = Join-Path $gitDir "MERGE_HEAD"
    $rebaseMergePath = Join-Path $gitDir "rebase-merge"
    $rebaseApplyPath = Join-Path $gitDir "rebase-apply"

    if (Test-Path -LiteralPath $mergeHeadPath) {
        Write-Host "  ERROR: A merge is already in progress in this repository!" -ForegroundColor Red
        Write-Host "  Resolve it before syncing:" -ForegroundColor Yellow
        Write-Host "    git merge --continue   (after resolving conflicts)" -ForegroundColor Yellow
        Write-Host "    git merge --abort      (to cancel it)" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }

    if ((Test-Path -LiteralPath $rebaseMergePath) -or (Test-Path -LiteralPath $rebaseApplyPath)) {
        Write-Host "  ERROR: A rebase is already in progress in this repository!" -ForegroundColor Red
        Write-Host "  Resolve it before syncing:" -ForegroundColor Yellow
        Write-Host "    git rebase --continue  (after resolving conflicts)" -ForegroundColor Yellow
        Write-Host "    git rebase --abort     (to cancel it)" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }

    # Check for uncommitted changes
    $status = git status --porcelain 2>$null
    if ($status) {
        Write-Host "  ERROR: You have uncommitted changes!" -ForegroundColor Red
        Write-Host "  Please commit or stash them before syncing." -ForegroundColor Yellow
        Write-Host "`n  Uncommitted files:" -ForegroundColor Gray
        $status | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Write-Host ""
        exit 1
    }

    # Verify remotes exist
    $remotes = git remote 2>$null
    Write-Host "  Remotes found: $($remotes -join ', ')" -ForegroundColor Gray

    if ($remotes -notcontains $UpstreamRemote) {
        Write-Host "`n  ERROR: Upstream remote '$UpstreamRemote' not found!" -ForegroundColor Red
        Write-Host "  Add it with: git remote add $UpstreamRemote <upstream-url>" -ForegroundColor Yellow
        exit 1
    }

    if ($remotes -notcontains $OriginRemote) {
        Write-Host "`n  ERROR: Origin remote '$OriginRemote' not found!" -ForegroundColor Red
        exit 1
    }

    # Show remote URLs
    $upstreamUrl = git remote get-url $UpstreamRemote 2>$null
    $originUrl = git remote get-url $OriginRemote 2>$null
    Write-Host "  Upstream: $upstreamUrl" -ForegroundColor DarkGray
    Write-Host "  Origin:   $originUrl" -ForegroundColor DarkGray
    Write-Host ""

    # Confirm
    if (-not $Force) {
        if (-not (Confirm-DevKitDestructiveAction -Always -Action "sync $Branch with $UpstreamRemote/$Branch (rewrites the fork branch when rebasing)")) {
            Write-Host "`n  Cancelled.`n" -ForegroundColor Gray
            exit 0
        }
    }

    # Step 1: Fetch from upstream
    Write-Host "`n  [1/4] Fetching from $UpstreamRemote..." -ForegroundColor Cyan
    $fetchOutput = git fetch $UpstreamRemote 2>&1
    $fetchExit = $LASTEXITCODE
    $fetchOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($fetchExit -ne 0) {
        Write-Host "`n  ERROR: Failed to fetch from upstream.`n" -ForegroundColor Red
        exit 1
    }
    Write-Host "  DONE: Fetched from upstream." -ForegroundColor Green

    # Step 2: Checkout target branch
    Write-Host "`n  [2/4] Checking out $Branch..." -ForegroundColor Cyan
    $checkoutOutput = git checkout "$Branch" 2>&1
    $checkoutExit = $LASTEXITCODE
    $checkoutOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($checkoutExit -ne 0) {
        Write-Host "`n  ERROR: Failed to checkout branch.`n" -ForegroundColor Red
        exit 1
    }
    Write-Host "  DONE: On branch $Branch." -ForegroundColor Green

    # A rebase ends in a force-push, so pin down - BEFORE history is rewritten -
    # exactly what the fork holds, and refuse if it has commits this checkout
    # lacks. The sha recorded here is the lease for the push in step 4.
    #
    # The old order (rebase, THEN fetch the fork, then --force-with-lease)
    # protected nothing: a bare --force-with-lease compares against the
    # remote-tracking ref, and the fetch had just moved that ref to whatever
    # was on the fork - including a commit pushed from another machine, which
    # the push then silently overwrote.
    $originLeaseSha = $null
    if ($Rebase) {
        Write-Host "`n  Checking $OriginRemote/$Branch before rewriting history..." -ForegroundColor Cyan
        $originFetchOutput = git fetch $OriginRemote $Branch 2>&1
        $originFetchExit = $LASTEXITCODE
        $originFetchOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        $originLeaseSha = git rev-parse --verify --quiet "refs/remotes/$OriginRemote/$Branch" 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $originLeaseSha) {
            if ($originFetchExit -ne 0) {
                Write-Host "`n  ERROR: Could not check $OriginRemote/$Branch, so a force-push would be blind. Nothing was changed.`n" -ForegroundColor Red
                exit 1
            }
            # The branch does not exist on the fork yet: nothing to protect.
            $originLeaseSha = $null
        } else {
            $originLeaseSha = ([string]$originLeaseSha).Trim()
            git merge-base --is-ancestor $originLeaseSha HEAD 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "`n  ERROR: $OriginRemote/$Branch has commits this checkout does not have." -ForegroundColor Red
                Write-Host "  A rebase and force-push would delete them from your fork." -ForegroundColor Yellow
                Write-Host "  Bring them in first (git pull --rebase $OriginRemote $Branch), then run the sync again." -ForegroundColor Yellow
                Write-Host "  Nothing was changed.`n" -ForegroundColor Yellow
                exit 1
            }
        }
    }

    # Step 3: Merge or Rebase
    Write-Host "`n  [3/4] Syncing with $UpstreamRemote/$Branch..." -ForegroundColor Cyan
    if ($Rebase) {
        $syncOutput = git rebase "$UpstreamRemote/$Branch" 2>&1
    } else {
        $syncOutput = git merge "$UpstreamRemote/$Branch" --no-edit 2>&1
    }
    $syncExit = $LASTEXITCODE
    $syncOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($syncExit -ne 0) {
        Write-Host "`n  ERROR: Sync failed." -ForegroundColor Red
        Write-Host "  You may need to resolve conflicts manually." -ForegroundColor Yellow
        if ($Rebase) {
            Write-Host "  To abort: git rebase --abort" -ForegroundColor Yellow
        } else {
            Write-Host "  To abort: git merge --abort" -ForegroundColor Yellow
        }
        exit 1
    }
    if ($Rebase) {
        Write-Host "  DONE: Rebased onto $UpstreamRemote/$Branch." -ForegroundColor Green
    } else {
        Write-Host "  DONE: Merged $UpstreamRemote/$Branch." -ForegroundColor Green
    }

    # Step 4: Push to origin
    Write-Host "`n  [4/4] Pushing to $OriginRemote..." -ForegroundColor Cyan
    if ($Rebase) {
        # No fetch here on purpose - see the lease comment above step 3. The
        # push is allowed only if the fork still holds exactly the commit that
        # was checked before the rebase.
        Write-Host "  WARNING: Force-pushing rebased branch (using --force-with-lease)!" -ForegroundColor Yellow
        if ($originLeaseSha) {
            $pushOutput = git push "$OriginRemote" "$Branch" "--force-with-lease=${Branch}:$originLeaseSha" 2>&1
        } else {
            $pushOutput = git push "$OriginRemote" "$Branch" --force-with-lease 2>&1
        }
    } else {
        $pushOutput = git push "$OriginRemote" "$Branch" 2>&1
    }
    $pushExit = $LASTEXITCODE
    $pushOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($pushExit -ne 0) {
        if ($Rebase) {
            Write-Host "`n  ERROR: Force-push rejected by --force-with-lease." -ForegroundColor Red
            Write-Host "  Someone else may have pushed to $OriginRemote/$Branch since you last synced." -ForegroundColor Yellow
            Write-Host "  Fetch and inspect $OriginRemote/$Branch, then re-run the sync." -ForegroundColor Yellow
            Write-Host "  Not retrying with a plain -f push.`n" -ForegroundColor Yellow
        } else {
            Write-Host "`n  ERROR: Failed to push.`n" -ForegroundColor Red
        }
        exit 1
    }
    Write-Host "  DONE: Pushed to $OriginRemote." -ForegroundColor Green

    Write-Host "`n  ===================================" -ForegroundColor Cyan
    Write-Host "  Fork sync complete!" -ForegroundColor Green
    Write-Host "  Branch: $Branch" -ForegroundColor Gray
    Write-Host "  Up-to-date with: $UpstreamRemote/$Branch" -ForegroundColor Gray
    Write-Host "  ===================================`n" -ForegroundColor Cyan
} finally {
    Pop-Location
}
