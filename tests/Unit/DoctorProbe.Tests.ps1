#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for the DevKit Doctor's tool probes
    (tools/diagnostics/DevKit-Doctor.ps1).
.DESCRIPTION
    The Doctor asks a dozen command-line tools for their version. It used to
    call each one directly and wait for as long as the tool took, so one
    tool that never answered held the whole run - and the app's single tool
    lane with it.

    The two probe functions are lifted out of the script by AST (running the
    script itself would run the whole health check) and pointed at stand-in
    tools written to the test drive: one that answers, one that fails, one
    that never finishes.
.EXAMPLE
    Invoke-Pester -Path .\tests\Unit\DoctorProbe.Tests.ps1
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $doctorPath = Join-Path $script:RepoRoot 'tools\diagnostics\DevKit-Doctor.ps1'
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($doctorPath, [ref]$null, [ref]$parseErrors)
    @($parseErrors).Count | Should -Be 0
    foreach ($name in 'Invoke-DevKitDoctorProbe', 'Get-DevKitToolVersion') {
        $fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }.GetNewClosure(), $true)
        $fn | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($fn.Extent.Text))
    }

    function New-StandInTool {
        param([string]$Name, [string[]]$Lines)
        $path = Join-Path $TestDrive $Name
        Set-Content -LiteralPath $path -Encoding Ascii -Value (@('@echo off') + $Lines)
        return $path
    }

    $script:Answers = New-StandInTool 'answers.cmd' @('echo fake 3.4.5', 'echo a second line')
    $script:Fails = New-StandInTool 'fails.cmd' @('echo something went wrong 1>&2', 'exit /b 7')
    # Runs for a minute unless something stops it.
    $script:Hangs = New-StandInTool 'hangs.cmd' @("`"%SystemRoot%\System32\ping.exe`" -n 60 127.0.0.1 >nul")
    $script:Echoes = New-StandInTool 'echoes.cmd' @('echo [%~1] [%~2]')
    $script:AsksAQuestion = New-StandInTool 'asks.cmd' @('set /p answer=Proceed?', 'echo answered [%answer%]')
}

Describe "Invoke-DevKitDoctorProbe" {

    It "returns what the tool printed and its exit code" {
        $probe = Invoke-DevKitDoctorProbe -Path $script:Answers
        $probe.Started | Should -BeTrue
        $probe.TimedOut | Should -BeFalse
        $probe.ExitCode | Should -Be 0
        $probe.Lines[0] | Should -Be 'fake 3.4.5'
        $probe.Lines.Count | Should -Be 2
    }

    It "reports a failing tool's exit code and what it wrote to stderr" {
        $probe = Invoke-DevKitDoctorProbe -Path $script:Fails
        $probe.TimedOut | Should -BeFalse
        $probe.ExitCode | Should -Be 7
        ($probe.Lines -join ' ') | Should -Match 'something went wrong'
    }

    It "stops a tool that never answers and says so, close to its deadline" {
        $elapsed = Measure-Command { $script:HangProbe = Invoke-DevKitDoctorProbe -Path $script:Hangs -TimeoutSeconds 2 }
        $script:HangProbe.Started | Should -BeTrue
        $script:HangProbe.TimedOut | Should -BeTrue
        $script:HangProbe.ExitCode | Should -BeNullOrEmpty
        # 2s deadline, then the stop and a bounded read. Nowhere near the
        # minute the stand-in would run for.
        $elapsed.TotalSeconds | Should -BeLessThan 12
    }

    It "stops what the tool started as well, not only the tool" {
        $before = @(Get-CimInstance Win32_Process -Filter "Name = 'PING.EXE'" | ForEach-Object ProcessId)
        $null = Invoke-DevKitDoctorProbe -Path $script:Hangs -TimeoutSeconds 1
        Start-Sleep -Milliseconds 500
        $left = @(Get-CimInstance Win32_Process -Filter "Name = 'PING.EXE'" |
                Where-Object { $before -notcontains $_.ProcessId -and $_.CommandLine -match '-n 60 127\.0\.0\.1' })
        $left.Count | Should -Be 0
    }

    It "answers 'not started' for a tool that cannot be run, without throwing" {
        $probe = Invoke-DevKitDoctorProbe -Path (Join-Path $TestDrive 'not-there.exe')
        $probe.Started | Should -BeFalse
        $probe.TimedOut | Should -BeFalse
        $probe.Lines.Count | Should -Be 0
    }

    It "passes an argument containing a space as ONE argument" {
        $probe = Invoke-DevKitDoctorProbe -Path $script:Echoes -ArgumentList @('compose version', 'second')
        $probe.Lines[0] | Should -Be '[compose version] [second]'
    }

    It "gives a tool that asks a question 'end of input' instead of waiting for an answer" {
        $elapsed = Measure-Command { $script:AskProbe = Invoke-DevKitDoctorProbe -Path $script:AsksAQuestion -TimeoutSeconds 10 }
        $script:AskProbe.TimedOut | Should -BeFalse
        $elapsed.TotalSeconds | Should -BeLessThan 8
    }
}

Describe "Get-DevKitToolVersion" {

    It "reports a healthy tool's version" {
        $check = Get-DevKitToolVersion -Path $script:Answers -Pattern 'fake (\d+\.\d+\.\d+)'
        $check.Responding | Should -BeTrue
        $check.TimedOut | Should -BeFalse
        $check.Version | Should -Be '3.4.5'
    }

    It "does not call a tool healthy when its output is not a version" {
        $check = Get-DevKitToolVersion -Path $script:Answers -Pattern 'Docker version (\d+)'
        $check.Responding | Should -BeFalse
        $check.ExitOk | Should -BeTrue
        $check.Output | Should -Be 'fake 3.4.5'
    }

    It "does not call a tool healthy when it exits with an error" {
        $check = Get-DevKitToolVersion -Path $script:Fails -Pattern '(.+)'
        $check.Responding | Should -BeFalse
        $check.ExitOk | Should -BeFalse
    }

    It "reports a tool that hangs as timed out, not as healthy and not for ever" {
        $elapsed = Measure-Command { $script:HangCheck = Get-DevKitToolVersion -Path $script:Hangs -Pattern '(.+)' -TimeoutSeconds 2 }
        $script:HangCheck.Responding | Should -BeFalse
        $script:HangCheck.TimedOut | Should -BeTrue
        $elapsed.TotalSeconds | Should -BeLessThan 12
    }

    It "runs the .cmd beside a .ps1 shim, which is what Get-Command hands back for npm-installed tools" {
        # Get-Command npm answers npm.ps1; npm.cmd sits next to it. Only the
        # .cmd can be started as a process and given a deadline.
        $shim = Join-Path $TestDrive 'answers.ps1'
        Set-Content -LiteralPath $shim -Value "throw 'the .ps1 shim must not be the one that runs'"
        $check = Get-DevKitToolVersion -Path $shim -Pattern 'fake (\d+\.\d+\.\d+)'
        $check.Responding | Should -BeTrue
        $check.Version | Should -Be '3.4.5'
    }

    It "answers 'not responding' for a tool that cannot be started" {
        $check = Get-DevKitToolVersion -Path (Join-Path $TestDrive 'not-there.exe') -Pattern '(.+)'
        $check.Responding | Should -BeFalse
        $check.ExitOk | Should -BeFalse
        $check.TimedOut | Should -BeFalse
    }
}
