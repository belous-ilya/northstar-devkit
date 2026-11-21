#!/usr/bin/env pwsh
<#
.SYNOPSIS
    WiFi Fix (Fast Mode) - Northstar DevKit
.DESCRIPTION
    The same diagnose-then-fix run as WiFi-Optimize.ps1, without the
    download/upload speed test at the end. Like it, this changes settings
    only when the measurements call for a fix.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER KeepDNS
    Don't change DNS settings. Passed through to WiFi-Optimize.ps1.
.PARAMETER Force
    Skip the confirmation prompt. Passed through to WiFi-Optimize.ps1.
.EXAMPLE
    .\WiFi-FastMode.ps1
    .\WiFi-FastMode.ps1 -KeepDNS
#>
# NOTE: deliberately no [CmdletBinding()] here (unlike the repo's usual script
# skeleton) and no -Fast parameter. This script always forces -Fast on the
# call below, but its catalog entry (tools/wifi/_module.psd1) also passes
# -Fast as a static argument. Without CmdletBinding, a param() block binds
# named args loosely: the unrecognized -Fast falls through into the automatic
# $args array instead of throwing "parameter cannot be found" - and since
# $args is never forwarded below, it is absorbed instead of landing twice on
# WiFi-Optimize.ps1's single [switch]$Fast parameter.
param(
    [switch]$KeepDNS,
    [switch]$Force
)

# No administrator check here: WiFi-Optimize.ps1 only needs elevation when it
# actually has a fix to apply, and reports that itself. It always ends with
# an explicit exit code, which is what $LASTEXITCODE carries back through the
# call operator.
& "$PSScriptRoot\WiFi-Optimize.ps1" -Fast -KeepDNS:$KeepDNS -Force:$Force
exit $LASTEXITCODE
