#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Kill Port - Northstar DevKit
.DESCRIPTION
    Kill a process by port number or PID.
    Either provide a port number to find and kill the process,
    or provide a ProcessId directly.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Port
    The port number to kill.
.PARAMETER ProcessId
    The process ID to kill directly.
.PARAMETER Force
    Skip confirmation prompt.
.PARAMETER InfoOnly
    Look up and display the process without ever prompting to kill it.
.EXAMPLE
    .\Kill-Port.ps1 -Port 3000
    .\Kill-Port.ps1 -ProcessId 12345
    .\Kill-Port.ps1 -Port 3000 -Force
    .\Kill-Port.ps1 -Port 3000 -InfoOnly
#>
# DefaultParameterSetName: with two sets and no default, running this with
# neither -Port nor -ProcessId (or with only -Force / -InfoOnly) died in
# the parameter binder with "Parameter set cannot be resolved" before the
# script's own "No PID specified or found" message could run.
[CmdletBinding(DefaultParameterSetName='ByPort')]
param(
    [Parameter(ParameterSetName='ByPort')]
    [ValidateRange(1, 65535)]
    [int]$Port,

    [Parameter(ParameterSetName='ByPID')]
    [Alias('PID')]
    [int]$ProcessId,

    [switch]$Force,

    [switch]$InfoOnly
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path -LiteralPath $CommonModule) {
    . $CommonModule
} else {
    Write-Host "ERROR: Required module not found: $CommonModule" -ForegroundColor Red
    exit 1
}

Write-DevKitHeader "Kill Port"

if ($Port) {
    Write-DevKitInfo "Finding process on port $Port..."
    $procInfo = Get-DevKitProcessByPort -Port $Port

    if (-not $procInfo) {
        Write-DevKitError "Nothing is listening on port $Port"
        exit 1
    }

    $ProcessId = $procInfo.PID

    Write-Host "  Found: PID $($procInfo.PID)" -ForegroundColor Yellow
    if ($procInfo.Name -ne "Unknown") {
        Write-Host "  Name: $($procInfo.Name)" -ForegroundColor Yellow
        Write-Host "  Path: $($procInfo.Path)" -ForegroundColor Gray
    }
}

if (-not $ProcessId) {
    Write-DevKitError "No PID specified or found."
    exit 1
}

# Reject reserved / protected PIDs before ever touching Get-Process/Stop-Process.
if ($ProcessId -eq 0 -or $ProcessId -eq 4) {
    Write-DevKitError "Refusing to target PID $ProcessId (reserved system process)."
    exit 1
}
if ($ProcessId -eq $PID) {
    Write-DevKitError "Refusing to target PID $ProcessId (this is the current DevKit process)."
    exit 1
}

if ($InfoOnly) {
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
    } catch {
        Write-DevKitError "Process $ProcessId not found."
        exit 1
    }

    $startTime = try { $process.StartTime } catch { "N/A" }
    Write-Host ""
    Write-Host "  Process: $($process.ProcessName) (PID: $ProcessId)" -ForegroundColor Yellow
    Write-Host "  Started: $startTime" -ForegroundColor Gray
    Write-Host ""
    exit 0
}

try {
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
} catch {
    Write-DevKitError "Process $ProcessId not found."
    exit 1
}

# DevKit runs elevated, so this tool CAN stop anything - which is exactly why
# it must refuse the processes Windows dies without (kill the svchost on port
# 135 and Windows forces a shutdown) and its own tree (this script, the
# sidecar that spawned it, the DevKit app above that). Checked before the
# prompt: there is no point asking about a kill that will be refused.
$refusal = Get-DevKitKillRefusalReason -ProcessId $ProcessId -Name $process.ProcessName -ProtectedPids (Get-DevKitOwnProcessTreeIds)
if ($refusal) {
    Write-DevKitError "Refusing to stop $($process.ProcessName) (PID $ProcessId): $refusal."
    exit 1
}

Write-Host ""

if (-not $Force) {
    if (-not (Confirm-DevKitDestructiveAction -Always -Action "stop $($process.ProcessName) (PID $ProcessId)")) {
        Write-DevKitInfo "Cancelled."
        exit 0
    }
}

# TOCTOU guard: the confirmation prompt above can take an arbitrary amount of
# time, during which the OS could reuse this PID for a different process.
# Re-fetch the process immediately before killing and make sure it is still
# the same one we showed the user.
$initialName = $process.ProcessName
$initialStart = try { $process.StartTime } catch { $null }

$verifyProcess = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
if (-not $verifyProcess) {
    Write-DevKitError "Process $ProcessId is no longer running. Aborting kill."
    exit 1
}

$verifyStart = try { $verifyProcess.StartTime } catch { $null }
if ($verifyProcess.ProcessName -ne $initialName -or $verifyStart -ne $initialStart) {
    Write-DevKitError "Process identity changed since confirmation (PID $ProcessId is now '$($verifyProcess.ProcessName)', not '$initialName'). Aborting kill for safety."
    exit 1
}

try {
    # -ErrorAction Stop: Stop-Process failures (access denied, already gone)
    # are non-terminating by default, so without it this catch never ran and
    # a failed kill still printed DONE and exited 0.
    Stop-Process -Id $ProcessId -Force -ErrorAction Stop
} catch {
    Write-DevKitError "Failed to kill process: $($_.Exception.Message)"
    exit 1
}

# Believe the process table, not the absence of an exception.
$survivor = $null
foreach ($attempt in 1..10) {
    $survivor = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $survivor -or $survivor.HasExited) { $survivor = $null; break }
    Start-Sleep -Milliseconds 100
}
if ($survivor) {
    Write-DevKitError "PID $ProcessId is still running a second after the kill."
    exit 1
}
Write-Host "  DONE: Process killed.`n" -ForegroundColor Green
