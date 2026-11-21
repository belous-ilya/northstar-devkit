#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Docker Nuke - Northstar DevKit
.DESCRIPTION
    Nuclear option for Docker: stops all running containers,
    removes all containers, images, volumes, and networks.
    This is the 'node_modules' of Docker - use with caution!
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Force
    Skip all confirmation prompts.
.PARAMETER KeepVolumes
    Keep Docker volumes (only remove containers and images).
.PARAMETER KeepImages
    Keep Docker images (only remove containers).
.PARAMETER DryRun
    Show what would be deleted without making changes.
.EXAMPLE
    .\Docker-Nuke.ps1
    .\Docker-Nuke.ps1 -Force
    .\Docker-Nuke.ps1 -KeepVolumes
    .\Docker-Nuke.ps1 -DryRun
#>[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$KeepVolumes,
    [switch]$KeepImages,
    [switch]$DryRun
)


$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) {
    . $CommonModule
} else {
    Write-Host "ERROR: Required module not found: $CommonModule" -ForegroundColor Red
    exit 1
}


Write-Host "`nNorthstar DevKit - DOCKER NUKE`n" -ForegroundColor Cyan
Write-Host "  WARNING: This will remove ALL Docker resources!" -ForegroundColor Yellow
Write-Host ""

# Check if Docker is available
if (-not (Test-DevKitCommand "docker")) {
    Write-Host "  ERROR: Docker not found in PATH.`n" -ForegroundColor Red
    Write-Host "  Please install Docker Desktop or Docker Engine.`n" -ForegroundColor Yellow
    exit 1
}
$dockerVersion = docker --version 2>$null
Write-Host "  Docker: $dockerVersion" -ForegroundColor Gray

# Check Docker daemon
$null = docker info 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR: Docker daemon is not running.`n" -ForegroundColor Red
    Write-Host "  Please start Docker Desktop or Docker service.`n" -ForegroundColor Yellow
    exit 1
}

# Every step that reports a problem is counted, so the run cannot end on
# "COMPLETE" (and exit 0) after printing warnings.
$script:problems = 0

function Invoke-DevKitDockerBatch {
    <#
    .SYNOPSIS
        Runs one docker command over a list of ids in batches of 50 and
        returns @{ Output = <all lines>; Failed = <bool> }. A machine with a
        few hundred volumes (64-character names) overflows Windows' 32k
        command-line limit when they are all passed at once, and the whole
        step then failed without removing anything.
    #>
    param(
        [Parameter(Mandatory = $true)][string[]]$Command,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Ids,
        [int]$BatchSize = 50
    )
    $output = @()
    $failed = $false
    for ($i = 0; $i -lt $Ids.Count; $i += $BatchSize) {
        $last = [math]::Min($i + $BatchSize, $Ids.Count) - 1
        $batch = @($Ids[$i..$last])
        $output += @(docker @Command @batch 2>&1)
        if ($LASTEXITCODE -ne 0) { $failed = $true }
    }
    return @{ Output = $output; Failed = $failed }
}

# Get current state
$containers = docker ps -aq 2>$null | Where-Object { $_ }
$images = docker images -q 2>$null | Where-Object { $_ }
$volumes = docker volume ls -q 2>$null | Where-Object { $_ }
$networks = docker network ls --format "{{.Name}}" 2>$null | Where-Object { $_ -notmatch '^(bridge|host|none)$' }

$containerCount = ($containers | Measure-Object).Count
$imageCount = ($images | Measure-Object).Count
$volumeCount = ($volumes | Measure-Object).Count
$networkCount = ($networks | Measure-Object).Count

# Show what will be affected
Write-Host "  Resources to be deleted:" -ForegroundColor Yellow
Write-Host "    Containers: $containerCount" -ForegroundColor $(if($containerCount -gt 0){'Red'}else{'Green'})
if (-not $KeepImages) {
    Write-Host "    Images:     $imageCount" -ForegroundColor $(if($imageCount -gt 0){'Red'}else{'Green'})
} else {
    Write-Host "    Images:     KEPT (KeepImages specified)" -ForegroundColor Green
}
if (-not $KeepVolumes) {
    Write-Host "    Volumes:    $volumeCount" -ForegroundColor $(if($volumeCount -gt 0){'Red'}else{'Green'})
} else {
    Write-Host "    Volumes:    KEPT (KeepVolumes specified)" -ForegroundColor Green
}
Write-Host "    Networks:   $networkCount (custom only)" -ForegroundColor $(if($networkCount -gt 0){'Red'}else{'Green'})
Write-Host ""

# Nothing to do
if ($containerCount -eq 0 -and ($KeepImages -or $imageCount -eq 0) -and ($KeepVolumes -or $volumeCount -eq 0) -and $networkCount -eq 0) {
    Write-Host "  OK: No Docker resources found. Nothing to nuke!`n" -ForegroundColor Green
    exit 0
}

# Dry run mode
if ($DryRun) {
    Write-Host "  [DRY RUN] No changes will be made.`n" -ForegroundColor Magenta
    
    if ($containerCount -gt 0) {
        Write-Host "  Containers that would be removed:" -ForegroundColor Yellow
        docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" 2>$null | 
            Select-Object -Skip 1 |
            ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
    
    if ($imageCount -gt 0 -and -not $KeepImages) {
        Write-Host "`n  Images that would be removed:" -ForegroundColor Yellow
        docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" 2>$null | 
            Select-Object -Skip 1 |
            ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
    
    # Volumes are where the data lives (databases, uploads) and are the one
    # thing here that cannot be pulled or rebuilt, so the preview names them.
    if ($volumeCount -gt 0 -and -not $KeepVolumes) {
        Write-Host "`n  Volumes that would be removed (their data is not recoverable):" -ForegroundColor Yellow
        $volumes | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    } elseif ($volumeCount -gt 0) {
        Write-Host "`n  Volumes that would be KEPT: $volumeCount" -ForegroundColor Green
    }

    if ($networkCount -gt 0) {
        Write-Host "`n  Custom networks that would be removed:" -ForegroundColor Yellow
        $networks | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }

    Write-Host ""
    exit 0
}

# Confirm - uses the shared gate (lib/DevKit-Common.ps1) so the typed-phrase
# comparison is guaranteed case-sensitive and this respects the user's
# confirmDestructive setting consistently with every other destructive tool.
# The sentence names exactly what this run will destroy: it used to say
# "containers, images, volumes, and networks" even with -KeepVolumes or
# -KeepImages, so the prompt for the volume-keeping item threatened the
# very data it was chosen to spare.
$doomed = @("$containerCount container(s)")
if (-not $KeepImages) { $doomed += "$imageCount image(s)" }
if (-not $KeepVolumes) { $doomed += "$volumeCount volume(s) AND THEIR DATA" }
$doomed += "$networkCount custom network(s)"
$kept = @()
if ($KeepImages) { $kept += 'images' }
if ($KeepVolumes) { $kept += 'volumes' }
$actionText = "destroy ALL Docker " + ($doomed -join ', ')
if ($kept.Count -gt 0) { $actionText += " (keeping $($kept -join ' and '))" }
if (-not (Confirm-DevKitDestructiveAction -Action $actionText -TypedPhrase 'NUKE' -Force:$Force)) {
    Write-Host "`n  Cancelled. Wise choice!`n" -ForegroundColor Gray
    exit 0
}

# Execute the nuke
$step = 1

# Build the total step count from the same conditions the steps below
# actually branch on, so the displayed "[n/total]" progress cannot drift
# out of sync with the number of increments that really happen.
$containerSteps = if ($containerCount -gt 0) { 2 } else { 1 }
$imageSteps = 1
$volumeSteps = 1
$networkSteps = 1
$totalSteps = $containerSteps + $imageSteps + $volumeSteps + $networkSteps

# Step 1: Stop all containers
if ($containerCount -gt 0) {
    Write-Host "`n  [$step/$totalSteps] Stopping all containers..." -ForegroundColor Cyan
    $stopHadErrors = $false
    # Reuse the container list captured before the confirmation gate instead
    # of re-listing - the same targets the counts/prompt above referred to.
    $stopResult = Invoke-DevKitDockerBatch -Command @('stop') -Ids @($containers)
    foreach ($line in $stopResult.Output) {
        if ($line -match 'error|Error') {
            Write-Host "    ERROR: $line" -ForegroundColor Red
            $stopHadErrors = $true
        }
    }
    if ($stopHadErrors -or $stopResult.Failed) {
        Write-Host "  WARNING: Some containers may not have stopped cleanly." -ForegroundColor Yellow
        $script:problems++
    } else {
        Write-Host "  DONE: All containers stopped." -ForegroundColor Green
    }
    $step++

    # Step 2: Remove all containers
    Write-Host "`n  [$step/$totalSteps] Removing all containers..." -ForegroundColor Cyan
    $removeHadErrors = $false
    # The list captured before the confirmation, not a fresh 'docker ps':
    # a container started after the user typed NUKE was never shown to them.
    $removeResult = Invoke-DevKitDockerBatch -Command @('rm', '-f') -Ids @($containers)
    foreach ($line in $removeResult.Output) {
        if ($line -match 'error|Error') {
            Write-Host "    ERROR: $line" -ForegroundColor Red
            $removeHadErrors = $true
        } elseif ("$line".Trim()) {
            Write-Host "    Removed: $line" -ForegroundColor DarkGray
        }
    }
    if ($removeHadErrors -or $removeResult.Failed) {
        Write-Host "  WARNING: Some containers may not have been removed cleanly." -ForegroundColor Yellow
        $script:problems++
    } else {
        Write-Host "  DONE: All containers removed." -ForegroundColor Green
    }
    $step++
} else {
    Write-Host "`n  [$step/$totalSteps] No containers to remove." -ForegroundColor Green
    $step++
}

# Step 3: Remove images (unless KeepImages)
if (-not $KeepImages -and $imageCount -gt 0) {
    Write-Host "`n  [$step/$totalSteps] Removing all images..." -ForegroundColor Cyan
    $imagesHadErrors = $false
    # Reuse the list captured up front instead of re-querying.
    # -q repeats an id once per tag; each id is removed once.
    $imagesResult = Invoke-DevKitDockerBatch -Command @('rmi', '-f') -Ids @($images | Select-Object -Unique)
    foreach ($line in $imagesResult.Output) {
        if ($line -match 'Untagged|Deleted') {
            Write-Host "    $line" -ForegroundColor DarkGray
        } elseif ($line -match 'error|Error') {
            Write-Host "    ERROR: $line" -ForegroundColor Red
            $imagesHadErrors = $true
        }
    }
    if ($imagesHadErrors -or $imagesResult.Failed) {
        Write-Host "  WARNING: Some images may not have been removed cleanly." -ForegroundColor Yellow
        $script:problems++
    } else {
        Write-Host "  DONE: All images removed." -ForegroundColor Green
    }
    $step++
} elseif ($KeepImages) {
    Write-Host "`n  [$step/$totalSteps] Skipping images (KeepImages specified)." -ForegroundColor Green
    $step++
} else {
    Write-Host "`n  [$step/$totalSteps] No images to remove." -ForegroundColor Green
    $step++
}

# Step 4: Remove volumes (unless KeepVolumes)
if (-not $KeepVolumes -and $volumeCount -gt 0) {
    Write-Host "`n  [$step/$totalSteps] Removing all volumes..." -ForegroundColor Cyan
    $volumesHadErrors = $false
    # Reuse the list captured up front instead of re-querying.
    $volumesResult = Invoke-DevKitDockerBatch -Command @('volume', 'rm') -Ids @($volumes)
    foreach ($line in $volumesResult.Output) {
        # Named volumes ('myapp_pgdata') are not hex ids: the old "starts
        # with a hex digit, show 12 characters" test skipped most of them
        # and threw on any short name that happened to start with a-f.
        if ($line -match 'error|Error') {
            Write-Host "    ERROR: $line" -ForegroundColor Red
            $volumesHadErrors = $true
        } elseif ("$line".Trim()) {
            Write-Host "    Removed: $line" -ForegroundColor DarkGray
        }
    }
    if ($volumesHadErrors -or $volumesResult.Failed) {
        Write-Host "  WARNING: Some volumes may not have been removed cleanly." -ForegroundColor Yellow
        $script:problems++
    } else {
        Write-Host "  DONE: All volumes removed." -ForegroundColor Green
    }
    $step++
} elseif ($KeepVolumes) {
    Write-Host "`n  [$step/$totalSteps] Skipping volumes (KeepVolumes specified)." -ForegroundColor Green
    $step++
} else {
    Write-Host "`n  [$step/$totalSteps] No volumes to remove." -ForegroundColor Green
    $step++
}

# Step 5: Prune networks and build cache
Write-Host "`n  [$step/$totalSteps] Pruning networks and build cache..." -ForegroundColor Cyan
# These prunes used to discard both output and exit code, unlike every step
# above - check $LASTEXITCODE so a failed prune can't report "DONE".
$networkPruneOutput = @(docker network prune -f 2>&1)
$networkPruneFailed = ($LASTEXITCODE -ne 0)
$builderPruneOutput = @(docker builder prune -f 2>&1)
$builderPruneFailed = ($LASTEXITCODE -ne 0)
if ($networkPruneFailed -or $builderPruneFailed) {
    Write-Host "  WARNING: Networks/build cache may not have been pruned cleanly." -ForegroundColor Yellow
    $script:problems++
} else {
    Write-Host "  DONE: Networks and build cache pruned." -ForegroundColor Green
}

# Final system prune to clean up everything else. NOTE: `docker system prune -f`
# (without -a) still removes DANGLING images even though -a was not passed, so
# when -KeepImages is set we must skip this step's image-cleaning side effect
# entirely rather than running the unscoped prune.
if ($KeepImages) {
    Write-Host "`n  Skipping final system prune (KeepImages specified - system prune still removes dangling images)." -ForegroundColor Green
    if (-not $KeepVolumes) {
        Write-Host "  Pruning remaining anonymous volumes..." -ForegroundColor Cyan
        $anonVolumeOutput = @(docker volume prune -f 2>&1)
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  WARNING: Anonymous volume prune reported errors." -ForegroundColor Yellow
            $script:problems++
        }
    }
} else {
    Write-Host "`n  Final cleanup with system prune..." -ForegroundColor Cyan
    $pruneArgs = @("system", "prune", "-f")
    if (-not $KeepVolumes) { $pruneArgs += "--volumes" }
    $systemPruneOutput = @(docker @pruneArgs 2>&1)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARNING: Final system prune reported errors." -ForegroundColor Yellow
        $script:problems++
    }
}

Write-Host "`n  ===================================" -ForegroundColor Cyan
if ($script:problems -gt 0) {
    Write-Host "  DOCKER NUKE FINISHED WITH PROBLEMS" -ForegroundColor Red
    Write-Host "  $($script:problems) step(s) reported errors - see the WARNING lines above." -ForegroundColor Gray
} else {
    Write-Host "  DOCKER NUKE COMPLETE!" -ForegroundColor Green
    $keptNote = if ($kept.Count -gt 0) { " except $($kept -join ' and ') (kept)" } else { '' }
    Write-Host "  All Docker resources have been destroyed$keptNote." -ForegroundColor Gray
}
Write-Host "  ===================================`n" -ForegroundColor Cyan

# Show disk space recovered
$systemDf = docker system df 2>$null
if ($systemDf) {
    Write-Host "  Current Docker disk usage:" -ForegroundColor Gray
    $systemDf | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
}
Write-Host ""
if ($script:problems -gt 0) { exit 1 }
exit 0
