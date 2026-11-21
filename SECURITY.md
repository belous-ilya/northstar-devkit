# Security Policy

## Supported versions

Northstar DevKit ships a single supported line. Only the latest release receives
security fixes; the in-app updater installs it automatically within 24 hours.

| Version | Supported |
| ------- | --------- |
| The latest release | Yes |
| Anything older | No — update via the installer or **Check for Updates** in the widget |

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Use GitHub's private reporting —
[Report a vulnerability](https://github.com/belous-ilya/northstar-devkit/security/advisories/new).

Please include the affected version, your Windows build, reproduction steps, and the
impact you believe it has. We will acknowledge within **3 business days**, give you an
assessment and a target fix window within **10 business days**, and credit you in the
release notes unless you ask us not to.

## What "always Administrator" means for you

DevKit runs elevated all the time, and it gets there without a prompt: every
launch goes through a scheduled task that starts `devkit-app.exe` with
administrator rights. Read this before installing it on a machine you do not
fully trust.

**Anything that can run as your Windows user can use DevKit to become
Administrator, without a UAC prompt.** That is a property of the design, not a
bug waiting for a patch:

- The app lives in your user profile, where any of your programs can replace
  its files, and the scheduled task will start whatever is there, elevated.
- DevKit exists to run your projects' own code and tools (git, npm scripts,
  node, docker) inside your project folders, and while it is elevated, so are
  they. A project's scripts and configuration are files your user can write.

In practice an elevated DevKit is equivalent to leaving an Administrator
terminal open all day. That is a reasonable trade for a single-user development
machine and the wrong one for a shared PC, or for a machine where you run
software you do not trust. Windows itself does not treat UAC as a security
boundary for an administrator account; DevKit does not turn it into one.

What DevKit does do:

- The git calls it makes on its own, with nobody asking (the Git panel's
  background refresh and fetch), run with the project's git hooks, file-monitor
  hook, `ext::` and `git://` remotes, custom upload-pack program, external diff
  and signature-checking programs switched off. Known exceptions, left on
  because switching them off breaks ordinary setups: a custom `core.sshCommand`,
  and filter drivers named in `.gitattributes` (git-lfs is one). Git has many
  settings; treat this list as what has been closed, not as proof nothing else
  exists. Git actions you click, and every tool, obey the project's
  configuration in full.
- `tool.run` only executes scripts inside DevKit's own `tools` folder.
- Uninstalling removes the scheduled task (asking for administrator rights once
  if needed), so no elevated launcher is left pointing at an empty folder.

## Scope

In scope:

- The NSIS installer and the minisign-signed update feed (`latest.json`)
- The PowerShell RPC sidecar (`core/Invoke-DevKitRpc.ps1`) and its method dispatch
- Any tool under `tools/` that elevates, edits the system PATH or environment, or
  writes outside `%LOCALAPPDATA%\NorthstarDevKit\`
- The Tauri desktop app and the `devkit` CLI

Out of scope:

- Issues that require an attacker to already hold administrator rights on the machine
- Issues that require an attacker to already run code as the Windows user who runs
  DevKit: such code can reach Administrator through DevKit by design (see above).
  Reports of a way to do so that needs no code running as that user remain in scope.
- Vulnerabilities in third-party tools DevKit merely launches (Node, Docker, `gh`, git)
- Findings from automated scanners with no demonstrated exploit path

## Data handling

DevKit runs entirely on your machine. It stores linked projects and settings under
`%LOCALAPPDATA%\NorthstarDevKit\` and sends no telemetry. Its only outbound network
calls are the GitHub requests described under "What it touches" in the README.
