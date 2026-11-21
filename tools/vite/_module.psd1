@{
    Name        = "Vite Tools"
    Description = "Cache-clearing and dev-server tooling for Vite projects: start a fresh Vite dev server with stale caches cleared, or build for production and serve the result locally with Vite's preview server."
    Items       = @(
        @{
            Key             = '1'
            Label           = 'Vite Dev Server (Fresh Start)'
            Script          = 'Vite-DevFresh.ps1'
            Prompts         = @(
                @{ Name = 'Port'; Type = 'Int'; Prompt = 'Port (0 = Vite default; press Enter for default)'; Optional = $true; Min = 0; Max = 65535 }
                @{ Name = 'SkipInstall'; Type = 'YesNo'; Prompt = 'Skip the dependency install (faster when nothing changed)?'; Optional = $true }
                @{ Name = 'ExposeHost'; Type = 'YesNo'; Prompt = 'Expose the server on the local network (--host)?'; Optional = $true }
            )
            RequiresProject = $true
            Help            = "Clears dev caches (node_modules/.cache, node_modules/.vite) and, if -ClearNodeModules is passed, node_modules itself, then runs the detected package manager's install (skip with -SkipInstall) before starting the dev server via 'run dev'. Never touches dist or the project-root .vite cache - a dev fresh start intentionally leaves any existing production build alone. Passes -Port and -ExposeHost (--host) through to Vite; warns but does not block if the target port is already in use, since Vite falls back to the next free port on its own. Use this when the dev server is misbehaving and a cache-cleared restart might fix it. Safety note: deletes cache folders (and node_modules with -ClearNodeModules) with no confirmation prompt - low risk, both are safely regenerated - then starts a long-running dev server that runs until Ctrl+C."
        }
        @{
            Key             = '2'
            Label           = 'Build and Preview'
            Script          = 'Vite-PreviewBuild.ps1'
            Prompts         = @(
                @{ Name = 'Port'; Type = 'Int'; Prompt = 'Preview port (press Enter for 4173)'; Optional = $true; Min = 1; Max = 65535 }
                @{ Name = 'SkipBuild'; Type = 'YesNo'; Prompt = 'Skip the build and preview the existing output?'; Optional = $true }
            )
            RequiresProject = $true
            Help            = "Runs a real production build (default output dist, override with -OutDir) via the detected package manager, then starts a Vite preview server (-Port, default 4173) serving it. Backs up the previous build before rebuilding and automatically restores it if the build fails, so a failed build never leaves the project without a working build; the backup is deleted only after a successful build. Prompts 'Replace previous build?' (y/n) before overwriting an existing build unless -Force is passed. Supports -SkipBuild to preview an existing build as-is, and -Analyze to open a bundle-visualizer stats file if one exists. OutDir is validated to resolve inside the project directory (rejects '..' or an absolute path elsewhere) before anything is touched. Safety note: mutates real build output on disk, gated by a plain y/n prompt / -Force (not the shared Confirm-DevKitDestructiveAction helper), then starts a long-running preview server until Ctrl+C."
        }
    )
}
