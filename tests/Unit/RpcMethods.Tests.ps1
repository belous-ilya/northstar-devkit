#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for the RPC layer's pure helpers (core/RpcMethods.ps1)
.DESCRIPTION
    The RPC layer had zero coverage. This file covers the parts that are
    pure functions of their inputs, with an emphasis on the two invariants
    that have actually broken things in production:

      - The $DevKitRpcArrayMethods registry. A method whose top-level result
        is an array MUST be listed there or PowerShell's function-boundary
        unrolling turns a one-element result into a bare object and an empty
        one into $null - which the typed consumers (the CLI's Vec<> parses,
        the widget's .map calls) then crash on, precisely on the
        fresh-install states no dev machine exhibits.
      - Add-DevKitForceArgument / Test-DevKitScriptDeclaresParameter, the
        fix for destructive tools dying under -NonInteractive because
        Confirm-DevKitDestructiveAction's Read-Host throws there.

    Dot-sources RpcMethods.ps1 directly - it defines functions and the
    registry at load time and needs neither DevKit.Core nor a live sidecar.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    # See Get-DevKitPackageManager.Tests.ps1 for why these load-once flags
    # get reset when several test files share one Pester process.
    $global:DevKitRpcMethodsLoaded = $false
    . (Join-Path $script:RepoRoot 'core\RpcMethods.ps1')

    function New-TestScript {
        param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Body)
        $path = Join-Path $TestDrive $Name
        Set-Content -LiteralPath $path -Value $Body -Encoding UTF8
        return $path
    }
}

Describe "Test-DevKitRpcArrayMethod" {

    It "knows the array-returning methods" {
        Test-DevKitRpcArrayMethod -Method 'projects.list' | Should -BeTrue
        Test-DevKitRpcArrayMethod -Method 'notes.get' | Should -BeTrue
        Test-DevKitRpcArrayMethod -Method 'ondeck.get' | Should -BeTrue
    }

    It "registers the error-center collectors, whose results are arrays" {
        Test-DevKitRpcArrayMethod -Method 'errors.system' | Should -BeTrue
        Test-DevKitRpcArrayMethod -Method 'errors.app' | Should -BeTrue
    }

    It "does NOT register errors.clearAppLogs, whose result is an object" {
        Test-DevKitRpcArrayMethod -Method 'errors.clearAppLogs' | Should -BeFalse
    }

    It "is false for scalar/object methods and for unknown ones" {
        Test-DevKitRpcArrayMethod -Method 'settings.get' | Should -BeFalse
        Test-DevKitRpcArrayMethod -Method 'metrics.system' | Should -BeFalse
        Test-DevKitRpcArrayMethod -Method 'no.such.method' | Should -BeFalse
    }

    It "is false for the removed junk/excluded-ports methods" {
        # metrics.junk / junk.clear / metrics.excludedPorts were dead RPC
        # surface (zero callers) and are gone - including the registry entry.
        Test-DevKitRpcArrayMethod -Method 'metrics.excludedPorts' | Should -BeFalse
        Test-DevKitRpcArrayMethod -Method 'metrics.junk' | Should -BeFalse
        Test-DevKitRpcArrayMethod -Method 'junk.clear' | Should -BeFalse
    }
}

Describe "settings.set input validation" {

    It "rejects a string preferences value before anything is written" {
        # A non-object preferences made the merge loop enumerate scalar
        # properties and write junk keys into settings.json - the gate must
        # trip first, so this throw happens before Set-DevKitSettings runs.
        $params = [PSCustomObject]@{ settings = [PSCustomObject]@{ preferences = 'not-an-object' } }
        { Invoke-DevKitRpcMethod -Method 'settings.set' -Params $params -EmitEvent {} } | Should -Throw '*preferences*'
    }

    It "rejects an array preferences value" {
        $params = [PSCustomObject]@{ settings = [PSCustomObject]@{ preferences = @('a', 'b') } }
        { Invoke-DevKitRpcMethod -Method 'settings.set' -Params $params -EmitEvent {} } | Should -Throw '*preferences*'
    }

    It "rejects a non-object settings root" {
        $params = [PSCustomObject]@{ settings = 'junk' }
        { Invoke-DevKitRpcMethod -Method 'settings.set' -Params $params -EmitEvent {} } | Should -Throw '*"settings"*'
    }

    It "rejects a null preferences (null is not 'no patch' - it would clobber on-disk preferences)" {
        $params = [PSCustomObject]@{ settings = [PSCustomObject]@{ preferences = $null } }
        { Invoke-DevKitRpcMethod -Method 'settings.set' -Params $params -EmitEvent {} } | Should -Throw '*preferences*required*'
    }
}

Describe "Get-DevKitRpcParam" {

    It "reads a present property" {
        Get-DevKitRpcParam ([PSCustomObject]@{ hours = 6 }) 'hours' 24 | Should -Be 6
    }

    It "falls back to the default for a missing property" {
        Get-DevKitRpcParam ([PSCustomObject]@{ other = 1 }) 'hours' 24 | Should -Be 24
    }

    It "falls back to the default for a null-valued property" {
        Get-DevKitRpcParam ([PSCustomObject]@{ hours = $null }) 'hours' 24 | Should -Be 24
    }

    It "falls back to the default when params itself is null" {
        Get-DevKitRpcParam $null 'hours' 24 | Should -Be 24
    }

    It "returns `$false rather than the default for an explicit false" {
        # The tool.run 'confirmed' flag depends on this: an explicit false
        # must not be mistaken for "absent".
        Get-DevKitRpcParam ([PSCustomObject]@{ confirmed = $false }) 'confirmed' $false | Should -BeFalse
    }
}

Describe "Test-DevKitRpcConfirmedFlag" {

    It "is true only for a real boolean true" {
        Test-DevKitRpcConfirmedFlag $true | Should -BeTrue
        Test-DevKitRpcConfirmedFlag $false | Should -BeFalse
    }

    It "is false for a missing/null value" {
        Test-DevKitRpcConfirmedFlag $null | Should -BeFalse
    }

    It "does NOT treat the string 'false' as true" {
        # A plain [bool] cast would: PowerShell casts any non-empty string
        # to $true, which on this flag means silently forcing a destructive
        # tool the user never confirmed.
        Test-DevKitRpcConfirmedFlag 'false' | Should -BeFalse
        Test-DevKitRpcConfirmedFlag 'no' | Should -BeFalse
        Test-DevKitRpcConfirmedFlag 0 | Should -BeFalse
        Test-DevKitRpcConfirmedFlag 1 | Should -BeFalse
    }

    It "accepts the exact string 'true' (case-insensitive) for a stringly-typed caller" {
        Test-DevKitRpcConfirmedFlag 'true' | Should -BeTrue
        Test-DevKitRpcConfirmedFlag 'True' | Should -BeTrue
    }
}

Describe "Test-DevKitScriptDeclaresParameter" {

    It "finds a switch declared in a [CmdletBinding()] param block" {
        $p = New-TestScript -Name 'has-force.ps1' -Body @'
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force
)
Write-Host "ran"
'@
        Test-DevKitScriptDeclaresParameter -ScriptPath $p -Name 'Force' | Should -BeTrue
    }

    It "matches case-insensitively" {
        $p = New-TestScript -Name 'case.ps1' -Body "param([switch]`$Force)"
        Test-DevKitScriptDeclaresParameter -ScriptPath $p -Name 'force' | Should -BeTrue
    }

    It "finds a parameter even when the comment-based help runs straight into [CmdletBinding()]" {
        # Docker-Nuke.ps1 really is written as `#>[CmdletBinding()]` on one
        # line - a text search would be fine, but this proves the AST is.
        $p = New-TestScript -Name 'jammed.ps1' -Body @'
<#
.SYNOPSIS
    Test
#>[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$KeepVolumes
)
'@
        Test-DevKitScriptDeclaresParameter -ScriptPath $p -Name 'Force' | Should -BeTrue
    }

    It "is false for a script with no -Force" {
        $p = New-TestScript -Name 'no-force.ps1' -Body @'
[CmdletBinding()]
param(
    [int]$Hours = 24,
    [int]$MaxEvents = 50
)
'@
        Test-DevKitScriptDeclaresParameter -ScriptPath $p -Name 'Force' | Should -BeFalse
    }

    It "is false for a script with no param block at all" {
        $p = New-TestScript -Name 'no-params.ps1' -Body 'Write-Host "just a script"'
        Test-DevKitScriptDeclaresParameter -ScriptPath $p -Name 'Force' | Should -BeFalse
    }

    It "is false (not a crash) for a missing file" {
        Test-DevKitScriptDeclaresParameter -ScriptPath (Join-Path $TestDrive 'nope.ps1') -Name 'Force' | Should -BeFalse
    }

    It "does not match a -Force mentioned only in the help text or the body" {
        $p = New-TestScript -Name 'mentions-force.ps1' -Body @'
<#
.PARAMETER Force
    Documented but never declared.
#>
param([switch]$Apply)
Write-Host "pass -Force to skip"
'@
        Test-DevKitScriptDeclaresParameter -ScriptPath $p -Name 'Force' | Should -BeFalse
    }

    It "does not EXECUTE the script it inspects" {
        $marker = Join-Path $TestDrive 'side-effect.txt'
        $p = New-TestScript -Name 'side-effect.ps1' -Body @"
param([switch]`$Force)
Set-Content -LiteralPath '$marker' -Value 'ran'
"@
        Test-DevKitScriptDeclaresParameter -ScriptPath $p -Name 'Force' | Should -BeTrue
        Test-Path -LiteralPath $marker | Should -BeFalse
    }
}

Describe "Add-DevKitForceArgument" {

    BeforeAll {
        $script:ForceScript = New-TestScript -Name 'forceable.ps1' -Body @'
[CmdletBinding()]
param(
    [string]$SetStartType,
    [switch]$Force
)
'@
        $script:PlainScript = New-TestScript -Name 'plain.ps1' -Body @'
[CmdletBinding()]
param([int]$Hours = 24)
'@
    }

    It "appends -Force when the script declares it" {
        $r = @(Add-DevKitForceArgument -ScriptPath $script:ForceScript -Arguments @())
        $r.Count | Should -Be 1
        $r[0] | Should -Be '-Force'
    }

    It "keeps the caller's existing arguments and appends -Force last" {
        $r = @(Add-DevKitForceArgument -ScriptPath $script:ForceScript -Arguments @('-SetStartType', 'Spooler'))
        $r.Count | Should -Be 3
        $r[0] | Should -Be '-SetStartType'
        $r[1] | Should -Be 'Spooler'
        $r[2] | Should -Be '-Force'
    }

    It "leaves a script that declares no -Force completely alone" {
        # Passing an undeclared parameter to `pwsh -File` is a hard binding
        # error, so this would turn the fix into a new breakage for the
        # non-destructive half of the catalog.
        $r = @(Add-DevKitForceArgument -ScriptPath $script:PlainScript -Arguments @('-Hours', '6'))
        $r.Count | Should -Be 2
        $r | Should -Not -Contain '-Force'
    }

    It "does not add a second -Force when the caller already passed one" {
        $r = @(Add-DevKitForceArgument -ScriptPath $script:ForceScript -Arguments @('-Force'))
        $r.Count | Should -Be 1
    }

    It "recognizes an already-present -Force case-insensitively" {
        $r = @(Add-DevKitForceArgument -ScriptPath $script:ForceScript -Arguments @('-force'))
        $r.Count | Should -Be 1
        $r[0] | Should -Be '-force'
    }

    It "does not mistake a VALUE that happens to read like -Force for a passed switch" {
        $r = @(Add-DevKitForceArgument -ScriptPath $script:ForceScript -Arguments @('-SetStartType', '-Force-ish'))
        $r.Count | Should -Be 3
        $r[2] | Should -Be '-Force'
    }

    It "leaves a missing script alone rather than throwing" {
        $r = @(Add-DevKitForceArgument -ScriptPath (Join-Path $TestDrive 'gone.ps1') -Arguments @('-A'))
        $r.Count | Should -Be 1
    }
}

Describe "ConvertTo-DevKitQuotedArgument" {

    It "leaves a simple token unquoted" {
        ConvertTo-DevKitQuotedArgument -Value '-Force' | Should -Be '-Force'
    }

    It "quotes a value containing spaces" {
        ConvertTo-DevKitQuotedArgument -Value 'C:\Program Files\App' | Should -Be '"C:\Program Files\App"'
    }

    It "escapes an embedded quote per the C runtime's rules" {
        ConvertTo-DevKitQuotedArgument -Value 'say "hi"' | Should -Be '"say \"hi\""'
    }

    It "doubles a trailing backslash run inside the quotes" {
        ConvertTo-DevKitQuotedArgument -Value 'C:\Some Dir\' | Should -Be '"C:\Some Dir\\"'
    }

    It "quotes an empty string" {
        ConvertTo-DevKitQuotedArgument -Value '' | Should -Be '""'
    }
}

Describe "Resolve-DevKitToolScriptPath" {

    BeforeAll {
        $script:ToolsRoot = Join-Path $TestDrive 'tools'
        New-Item -ItemType Directory -Path (Join-Path $script:ToolsRoot 'ports') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:ToolsRoot 'ports\Scan.ps1') -Value 'Write-Host scan'
        Set-Content -LiteralPath (Join-Path $script:ToolsRoot 'ports\notes.txt') -Value 'not a script'
        New-Item -ItemType Directory -Path (Join-Path $script:ToolsRoot 'ports\sub.ps1') -Force | Out-Null
        # A real .ps1 OUTSIDE the tools folder: the thing tool.run must never reach.
        Set-Content -LiteralPath (Join-Path $TestDrive 'outside.ps1') -Value 'Write-Host escaped'
    }

    It "resolves a tool inside the tools folder" {
        Resolve-DevKitToolScriptPath -ToolsRoot $script:ToolsRoot -Folder 'ports' -ScriptName 'Scan.ps1' |
            Should -Be (Join-Path $script:ToolsRoot 'ports\Scan.ps1')
    }

    It "refuses to leave the tools folder - <case>" -ForEach @(
        @{ case = 'parent folder'; folder = '..'; name = 'outside.ps1' }
        @{ case = 'climbing out through a real folder'; folder = 'ports\..\..'; name = 'outside.ps1' }
        @{ case = 'forward slashes'; folder = 'ports/../..'; name = 'outside.ps1' }
        @{ case = 'traversal in the script name'; folder = 'ports'; name = '..\..\outside.ps1' }
    ) {
        { Resolve-DevKitToolScriptPath -ToolsRoot $script:ToolsRoot -Folder $folder -ScriptName $name } |
            Should -Throw -ExpectedMessage 'Not a DevKit tool*'
    }

    It "refuses an absolute path smuggled in as the script" {
        # Join-Path glues an absolute child onto the tools folder rather than
        # honouring it, so this lands on a path that cannot exist - refused
        # either way, which is the property that matters.
        { Resolve-DevKitToolScriptPath -ToolsRoot $script:ToolsRoot -Folder 'ports' -ScriptName (Join-Path $TestDrive 'outside.ps1') } |
            Should -Throw
    }

    It "refuses a file that is not a .ps1, and a directory named like one" {
        { Resolve-DevKitToolScriptPath -ToolsRoot $script:ToolsRoot -Folder 'ports' -ScriptName 'notes.txt' } | Should -Throw -ExpectedMessage 'Not a DevKit tool*'
        { Resolve-DevKitToolScriptPath -ToolsRoot $script:ToolsRoot -Folder 'ports' -ScriptName 'sub.ps1' } | Should -Throw -ExpectedMessage 'Tool script not found*'
    }

    It "says 'not found' for a missing tool, and requires both parts" {
        { Resolve-DevKitToolScriptPath -ToolsRoot $script:ToolsRoot -Folder 'ports' -ScriptName 'Gone.ps1' } | Should -Throw -ExpectedMessage 'Tool script not found*'
        { Resolve-DevKitToolScriptPath -ToolsRoot $script:ToolsRoot -Folder '' -ScriptName 'Scan.ps1' } | Should -Throw -ExpectedMessage '*requires a folder and a script*'
    }
}

Describe "tool.run streams both of the tool's output streams as they happen" {

    BeforeAll {
        # tool.run resolves scripts under $RepoRoot\tools; point it at a
        # throwaway tree holding one harmless script.
        $script:FakeRepo = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path (Join-Path $script:FakeRepo 'tools\demo') -Force | Out-Null
        $accented = "caf$([char]0x00E9)"
        Set-Content -LiteralPath (Join-Path $script:FakeRepo 'tools\demo\Talk.ps1') -Encoding UTF8 -Value @"
if ([Console]::IsOutputRedirected -and [Console]::OutputEncoding.CodePage -ne 65001) { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding `$false }
Write-Host 'first'
[Console]::Error.WriteLine('early-error')
Start-Sleep -Milliseconds 1500
Write-Host 'last $accented'
exit 3
"@
    }

    It "delivers an early error BEFORE later output, with the right exit code and intact text" {
        $events = [System.Collections.Generic.List[object]]::new()
        $emit = { param($EventName, $RunId, [hashtable]$Extra = @{}) $events.Add([pscustomobject]@{ Name = $EventName; Stream = $Extra['stream']; Line = $Extra['line']; Exit = $Extra['exitCode'] }) }.GetNewClosure()
        # Invoke-DevKitRpcMethod reads these three from the scope it is called
        # in - in a lane runspace they are session variables the sidecar sets.
        Set-Variable -Name RepoRoot -Value $script:FakeRepo
        Set-Variable -Name RunRegistry -Value $null
        Set-Variable -Name ToolLaneGate -Value $null

        $result = Invoke-DevKitRpcMethod -Method 'tool.run' -Params ([pscustomobject]@{ folder = 'demo'; script = 'Talk.ps1'; args = @(); runId = 'r1' }) -EmitEvent $emit

        $result.exitCode | Should -Be 3
        $lines = @($events | Where-Object { $_.Name -eq 'tool.output' })
        $errorAt = [array]::IndexOf(@($lines | ForEach-Object { $_.Line }), 'early-error')
        $lastAt = -1
        for ($i = 0; $i -lt $lines.Count; $i++) { if ([string]$lines[$i].Line -like 'last*') { $lastAt = $i } }
        $errorAt | Should -BeGreaterOrEqual 0
        $lastAt | Should -BeGreaterThan $errorAt -Because 'stderr used to be held back until stdout closed'
        ($lines | Where-Object { $_.Line -eq 'early-error' }).Stream | Should -Be 'stderr'
        $lines[$lastAt].Line | Should -Be "last caf$([char]0x00E9)"
        ($events | Where-Object { $_.Name -eq 'tool.finished' }).Exit | Should -Be 3
    }

    It "refuses a script outside the tools folder before starting anything" {
        Set-Content -LiteralPath (Join-Path $script:FakeRepo 'outside.ps1') -Value 'Write-Host escaped'
        $events = [System.Collections.Generic.List[object]]::new()
        $emit = { param($EventName, $RunId, [hashtable]$Extra = @{}) $events.Add($EventName) }.GetNewClosure()
        # Invoke-DevKitRpcMethod reads these three from the scope it is called
        # in - in a lane runspace they are session variables the sidecar sets.
        Set-Variable -Name RepoRoot -Value $script:FakeRepo
        Set-Variable -Name RunRegistry -Value $null
        Set-Variable -Name ToolLaneGate -Value $null
        { Invoke-DevKitRpcMethod -Method 'tool.run' -Params ([pscustomobject]@{ folder = '..'; script = 'outside.ps1'; args = @(); runId = 'r2' }) -EmitEvent $emit } |
            Should -Throw -ExpectedMessage 'Not a DevKit tool*'
        $events.Count | Should -Be 0
    }
}

Describe "catalog.toolExists" {

    # Run history asks this before offering "Run again" for a row an earlier
    # release may have recorded. It has to be the same answer tool.run would
    # give - and NOT "is it in the catalog": Doctor and Close-Out are tools
    # whose folders have no manifest, so the catalog has never listed them.

    BeforeAll {
        $script:RealRepo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:ExistsRepo = Join-Path $TestDrive 'exists-repo'
        New-Item -ItemType Directory -Path (Join-Path $script:ExistsRepo 'tools\demo') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:ExistsRepo 'tools\demo\Talk.ps1') -Value 'Write-Host hi'
        Set-Content -LiteralPath (Join-Path $script:ExistsRepo 'tools\demo\notes.txt') -Value 'not a script'
        Set-Content -LiteralPath (Join-Path $script:ExistsRepo 'outside.ps1') -Value 'Write-Host escaped'
        function Test-ToolExists {
            param([string]$Repo, $Folder, $Script)
            Set-Variable -Name RepoRoot -Value $Repo
            (Invoke-DevKitRpcMethod -Method 'catalog.toolExists' -Params ([pscustomobject]@{ folder = $Folder; script = $Script }) -EmitEvent {}).exists
        }
    }

    It "is true for a tool script that is there" {
        Test-ToolExists $script:ExistsRepo 'demo' 'Talk.ps1' | Should -BeTrue
    }

    It "is false for a tool that was removed" {
        Test-ToolExists $script:ExistsRepo 'maintenance' 'Clear-TempFiles.ps1' | Should -BeFalse
        Test-ToolExists $script:ExistsRepo 'demo' 'Gone.ps1' | Should -BeFalse
    }

    It "is false, not an error, for anything tool.run would refuse" {
        Test-ToolExists $script:ExistsRepo '..' 'outside.ps1' | Should -BeFalse
        Test-ToolExists $script:ExistsRepo 'demo' 'notes.txt' | Should -BeFalse
        Test-ToolExists $script:ExistsRepo '' '' | Should -BeFalse
        Test-ToolExists $script:ExistsRepo 'demo' '' | Should -BeFalse
    }

    It "answers with a plain true or false under the key the app reads" {
        Set-Variable -Name RepoRoot -Value $script:ExistsRepo
        $result = Invoke-DevKitRpcMethod -Method 'catalog.toolExists' -Params ([pscustomobject]@{ folder = 'demo'; script = 'Talk.ps1' }) -EmitEvent {}
        ($result | ConvertTo-Json -Compress) | Should -Be '{"exists":true}'
    }

    It "is true for the widget's own tools, which no catalog manifest lists" {
        # The two Quick Actions tiles. A catalog lookup called both of these
        # "no longer part of DevKit".
        Test-ToolExists $script:RealRepo 'diagnostics' 'DevKit-Doctor.ps1' | Should -BeTrue
        Test-ToolExists $script:RealRepo 'workflow' 'Close-OutSession.ps1' | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:RealRepo 'tools\diagnostics\_module.psd1') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:RealRepo 'tools\workflow\_module.psd1') | Should -BeFalse
    }

    It "is true for every tool the real manifests list" {
        $checked = 0
        foreach ($manifest in Get-ChildItem -LiteralPath (Join-Path $script:RealRepo 'tools') -Recurse -Filter '_module.psd1') {
            $folder = $manifest.Directory.Name
            foreach ($item in (Import-PowerShellDataFile -LiteralPath $manifest.FullName).Items) {
                Test-ToolExists $script:RealRepo $folder $item.Script | Should -BeTrue -Because "$folder/$($item.Script) is in the catalog"
                $checked++
            }
        }
        $checked | Should -BeGreaterThan 20
    }
}

Describe "tool.run does not start a tool once shutdown has begun" {

    # The main thread marks the shared gate when shutdown starts. A run that
    # was still queued (behind the tool lane's own start-up) would otherwise
    # begin after the shutdown sweep had already looked for running tools,
    # and outlive the sidecar.

    BeforeAll {
        $script:ShutdownRepo = Join-Path $TestDrive 'shutdown-repo'
        New-Item -ItemType Directory -Path (Join-Path $script:ShutdownRepo 'tools\demo') -Force | Out-Null
        $script:Marker = Join-Path $TestDrive 'tool-ran.txt'
        Set-Content -LiteralPath (Join-Path $script:ShutdownRepo 'tools\demo\Mark.ps1') -Value "Set-Content -LiteralPath '$($script:Marker)' -Value ran"
    }

    BeforeEach {
        if (Test-Path -LiteralPath $script:Marker) { Remove-Item -LiteralPath $script:Marker -Force }
        $script:Events = [System.Collections.Generic.List[object]]::new()
        $script:Emit = { param($EventName, $RunId, [hashtable]$Extra = @{}) $script:Events.Add($EventName) }
        Set-Variable -Name RepoRoot -Value $script:ShutdownRepo
        Set-Variable -Name RunRegistry -Value $null
    }

    It "refuses, starts nothing and emits nothing when the gate says shutdown" {
        $gate = [System.Collections.Concurrent.ConcurrentDictionary[string, string]]::new()
        $gate['active'] = 'token-1'
        $gate['shutdown'] = '1'
        Set-Variable -Name ToolLaneGate -Value $gate
        { Invoke-DevKitRpcMethod -Method 'tool.run' -Params ([pscustomobject]@{ folder = 'demo'; script = 'Mark.ps1'; args = @(); runId = 's1'; __toolLaneToken = 'token-1' }) -EmitEvent $script:Emit } |
            Should -Throw -ExpectedMessage '*shutting down*'
        Test-Path -LiteralPath $script:Marker | Should -BeFalse
        $script:Events.Count | Should -Be 0
        # ...and gives its claim on the lane back, like every other exit.
        $gate.ContainsKey('active') | Should -BeFalse
    }

    It "runs normally when the gate does not say shutdown" {
        $gate = [System.Collections.Concurrent.ConcurrentDictionary[string, string]]::new()
        $gate['active'] = 'token-2'
        Set-Variable -Name ToolLaneGate -Value $gate
        $result = Invoke-DevKitRpcMethod -Method 'tool.run' -Params ([pscustomobject]@{ folder = 'demo'; script = 'Mark.ps1'; args = @(); runId = 's2'; __toolLaneToken = 'token-2' }) -EmitEvent $script:Emit
        $result.exitCode | Should -Be 0
        Test-Path -LiteralPath $script:Marker | Should -BeTrue
    }
}
