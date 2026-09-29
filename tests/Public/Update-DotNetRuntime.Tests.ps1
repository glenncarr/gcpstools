Describe 'Update-DotNetRuntime' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\gcpstools\Public\Update-DotNetRuntime.ps1"
    }

    BeforeEach {
        $script:originalProgramW6432 = $env:ProgramW6432
        $script:originalProgramFilesX86 = ${env:ProgramFiles(x86)}
        $env:ProgramW6432 = $TestDrive
        ${env:ProgramFiles(x86)} = $null

        $frameworkPath = Join-Path $TestDrive 'dotnet\shared\Microsoft.NETCore.App'
        Remove-Item -LiteralPath $frameworkPath -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path (Join-Path $frameworkPath '8.0.1') -Force | Out-Null

        Mock -CommandName Invoke-RestMethod -MockWith {
            if ($Uri -like '*releases-index.json') {
                [PSCustomObject]@{
                    'releases-index' = @(
                        [PSCustomObject]@{
                            'channel-version' = '8.0'
                            'latest-release'  = '8.0.2'
                            'support-phase'   = 'active'
                            'releases.json'   = 'https://metadata.example.test/8.0/releases.json'
                        }
                    )
                }
                return
            }

            [PSCustomObject]@{
                releases = @(
                    [PSCustomObject]@{
                        'release-version' = '8.0.2'
                        runtime = [PSCustomObject]@{
                            version = '8.0.2'
                            files = @(
                                [PSCustomObject]@{
                                    rid  = 'win-x64'
                                    name = 'dotnet-runtime-8.0.2-win-x64.exe'
                                    url  = 'https://download.example.test/dotnet-runtime-8.0.2-win-x64.exe'
                                    hash = 'expected-hash'
                                }
                            )
                        }
                    }
                )
            }
        }

        Mock -CommandName Invoke-WebRequest -MockWith { }
    }

    AfterEach {
        $env:ProgramW6432 = $script:originalProgramW6432
        ${env:ProgramFiles(x86)} = $script:originalProgramFilesX86
    }

    It 'reports an available update without downloading it when WhatIf is used' {
        $result = Update-DotNetRuntime -WhatIf

        $result | Should -HaveCount 1
        $result.Status | Should -Be 'WhatIf'
        $result.CurrentVersion | Should -Be '8.0.1'
        $result.TargetVersion | Should -Be '8.0.2'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'skips an end-of-life channel unless IncludeEol is specified' {
        Mock -CommandName Invoke-RestMethod -MockWith {
            [PSCustomObject]@{
                'releases-index' = @(
                    [PSCustomObject]@{
                        'channel-version' = '8.0'
                        'latest-release'  = '8.0.2'
                        'support-phase'   = 'eol'
                        'releases.json'   = 'https://metadata.example.test/8.0/releases.json'
                    }
                )
            }
        }

        $result = Update-DotNetRuntime -Confirm:$false

        $result.Status | Should -Be 'SkippedEol'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It 'reports Current when the newest patch is already installed' {
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'dotnet\shared\Microsoft.NETCore.App\8.0.2') | Out-Null

        $result = Update-DotNetRuntime -Confirm:$false

        $result.Status | Should -Be 'Current'
        $result.CurrentVersion | Should -Be '8.0.2'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'verifies, installs, and reports a reboot-required update' {
        Mock -CommandName Invoke-WebRequest -MockWith { }
        Mock -CommandName Get-FileHash -MockWith { [PSCustomObject]@{ Hash = 'expected-hash' } }
        Mock -CommandName Start-Process -MockWith { [PSCustomObject]@{ ExitCode = 3010 } }

        $result = Update-DotNetRuntime -Confirm:$false -DownloadPath $TestDrive

        $result.Status | Should -Be 'Updated'
        $result.ExitCode | Should -Be 3010
        $result.RebootRequired | Should -BeTrue
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        Should -Invoke Start-Process -Times 1 -Exactly
    }
}