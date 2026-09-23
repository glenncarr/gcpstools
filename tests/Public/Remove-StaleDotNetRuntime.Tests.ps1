Describe 'Remove-StaleDotNetRuntime' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\gcpstools\Public\Remove-StaleDotNetRuntime.ps1"

        function New-Framework {
            param($Name, [string[]]$Versions)
            $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive $Name)
            foreach ($version in $Versions) {
                New-Item -ItemType Directory -Path (Join-Path $root $version) | Out-Null
            }
            $root.FullName
        }
    }

    It 'Removes superseded patches and keeps the newest of each band' {
        $root = New-Framework -Name 'keep-newest' -Versions '6.0.1', '6.0.10', '6.0.2', '8.0.3', '8.0.4'

        Remove-StaleDotNetRuntime -Path $root -Confirm:$false | Out-Null

        Join-Path $root '6.0.10' | Should -Exist
        Join-Path $root '8.0.4' | Should -Exist
        Join-Path $root '6.0.1' | Should -Not -Exist
        Join-Path $root '6.0.2' | Should -Not -Exist
        Join-Path $root '8.0.3' | Should -Not -Exist
    }

    It 'Emits the removed directories to the pipeline' {
        $root = New-Framework -Name 'emit' -Versions '9.0.0', '9.0.1'

        $result = Remove-StaleDotNetRuntime -Path $root -Confirm:$false

        $result | Should -HaveCount 1
        $result.Name | Should -Be '9.0.0'
    }

    It 'Does not remove anything when -WhatIf is specified' {
        $root = New-Framework -Name 'whatif' -Versions '7.0.1', '7.0.2'

        Remove-StaleDotNetRuntime -Path $root -WhatIf

        Join-Path $root '7.0.1' | Should -Exist
        Join-Path $root '7.0.2' | Should -Exist
    }

    It 'Ranks a prerelease below the matching stable release' {
        $root = New-Framework -Name 'prerelease' -Versions '8.0.5', '8.0.5-preview.1'

        Remove-StaleDotNetRuntime -Path $root -Confirm:$false | Out-Null

        Join-Path $root '8.0.5' | Should -Exist
        Join-Path $root '8.0.5-preview.1' | Should -Not -Exist
    }

    It 'Ignores directories that are not version numbers' {
        $root = New-Framework -Name 'ignore' -Versions '8.0.1', '8.0.2', 'not-a-version'

        Remove-StaleDotNetRuntime -Path $root -Confirm:$false | Out-Null

        Join-Path $root 'not-a-version' | Should -Exist
    }

    It 'Keeps the requested number of versions per band' {
        $root = New-Framework -Name 'keep-two' -Versions '8.0.1', '8.0.2', '8.0.3'

        Remove-StaleDotNetRuntime -Path $root -KeepVersions 2 -Confirm:$false | Out-Null

        Join-Path $root '8.0.1' | Should -Not -Exist
        Join-Path $root '8.0.2' | Should -Exist
        Join-Path $root '8.0.3' | Should -Exist
    }

    It 'Only processes the requested bands' {
        $root = New-Framework -Name 'band-filter' -Versions '6.0.1', '6.0.2', '8.0.1', '8.0.2'

        Remove-StaleDotNetRuntime -Path $root -Band '8.0' -Confirm:$false | Out-Null

        Join-Path $root '6.0.1' | Should -Exist
        Join-Path $root '8.0.1' | Should -Not -Exist
    }

    It 'Accepts paths from the pipeline' {
        $first = New-Framework -Name 'pipe-a' -Versions '8.0.1', '8.0.2'
        $second = New-Framework -Name 'pipe-b' -Versions '9.0.1', '9.0.2'

        $result = $first, $second | Remove-StaleDotNetRuntime -Confirm:$false

        $result | Should -HaveCount 2
        Join-Path $first '8.0.1' | Should -Not -Exist
        Join-Path $second '9.0.1' | Should -Not -Exist
    }

    It 'Skips paths that do not exist' {
        $missing = Join-Path $TestDrive 'does-not-exist'

        { Remove-StaleDotNetRuntime -Path $missing -Confirm:$false } | Should -Not -Throw
    }
}
