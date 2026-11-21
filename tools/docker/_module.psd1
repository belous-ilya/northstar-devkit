@{
    Name        = "Docker Tools"
    Description = "Clean up Docker resources (containers, images, volumes, networks, build cache) - either a full teardown or a selective/unused-only pass - and tail logs from one or more running containers at once. All of these tools require Docker Desktop or the Docker Engine CLI installed with the daemon running."
    Items       = @(
        @{
            Key        = '1'
            Label      = 'Docker Nuke (Containers and Images, Volumes Kept)'
            Script     = 'Docker-Nuke.ps1'
            StaticArgs = @{ KeepVolumes = $true }
            Prompts    = @(
                @{ Name = 'DryRun'; Type = 'YesNo'; Prompt = 'Preview only - list what would be removed and change nothing?'; Optional = $true }
                @{ Name = 'KeepImages'; Type = 'YesNo'; Prompt = 'Keep images too (remove containers only)?'; Optional = $true }
            )
            Help       = "Stops and force-removes ALL containers, then removes all images (unless you answer yes to keeping them), prunes custom networks and the build cache, and finishes with a final 'docker system prune'. VOLUMES ARE KEPT - this item always passes -KeepVolumes, because a volume is where a local database keeps its data and that is the one thing a rebuild cannot bring back; use the next item when the volumes should go too. Use this when you want a clean Docker state but not to lose database contents. Safety note: mutates real Docker state - shows a per-resource-type count before acting, and requires typing 'NUKE' (case-sensitive) via the shared Confirm-DevKitDestructiveAction gate unless -Force is passed (the Control Center's confirm dialog passes it for you). Answer yes to the preview question to see exactly what would be removed first; a preview changes nothing even after confirming."
        }
        @{
            Key     = '2'
            Label   = 'Docker Nuke - Everything, Including Volumes'
            Script  = 'Docker-Nuke.ps1'
            Prompts = @(
                @{ Name = 'DryRun'; Type = 'YesNo'; Prompt = 'Preview only - list what would be removed and change nothing?'; Optional = $true }
            )
            Help    = "The full teardown: everything the item above removes, PLUS EVERY DOCKER VOLUME. Volumes hold the data of local databases and anything else a container was told to keep - once removed, that data is gone and no rebuild restores it. Use this only when you really want Docker back to an empty install. Safety note: mutates real Docker state and permanently deletes volume data - shows a per-resource-type count before acting, and requires typing 'NUKE' (case-sensitive) via the shared Confirm-DevKitDestructiveAction gate unless -Force is passed (the Control Center's confirm dialog passes it for you). Answer yes to the preview question to see what would be removed first; a preview changes nothing even after confirming."
        }
        @{
            Key     = '3'
            Label   = 'Docker Cleanup (selective)'
            Script  = 'Docker-Cleanup.ps1'
            Prompts = @(
                @{ Name = 'DryRun'; Type = 'YesNo'; Prompt = 'Preview only - list what would be removed and change nothing?'; Optional = $true }
                @{ Name = 'AllUnused'; Type = 'YesNo'; Prompt = 'Also remove every unused image and unused network (not just dangling ones)?'; Optional = $true }
                @{ Name = 'Volumes'; Type = 'YesNo'; Prompt = 'Also remove unused volumes (their data is deleted)?'; Optional = $true }
            )
            Help    = "Selective, less destructive than Docker Nuke - removes stopped containers and dangling images by default; answering yes to 'every unused image' (-AllUnused) widens image removal to every unused (not just untagged) image and also prunes unused custom networks; answering yes to volumes (-Volumes) additionally prunes unused volumes. Also cleans the build cache and reports estimated reclaimable disk space. Use this for routine disk-space cleanup that leaves in-use resources alone. Safety note: mutates real Docker state - prompts with a plain y/n confirmation unless -Force is passed (this script predates the shared Confirm-DevKitDestructiveAction gate that Docker Nuke uses, so it does not honor the confirmDestructive setting); answer yes to the preview question (-DryRun) to list the affected containers/images with no changes made."
        }
        @{
            Key    = '4'
            Label  = 'Quick Logs (multi-container)'
            Script = 'Docker-QuickLogs.ps1'
            Help   = "Tails 'docker logs' for one or more containers at once (all running containers by default, or specific names via -Container), with a distinct color prefix per container, an initial line count (-Lines, default 50), optional -Timestamps, and optional -Follow to keep streaming instead of printing the last N lines and exiting. Use this to watch several services' logs together during local development. Note: read-only against Docker (no containers/images/volumes are touched), but with -Follow it blocks the terminal indefinitely - press Ctrl+C to stop, and never invoke -Follow from an unattended/non-interactive context."
        }
    )
}
