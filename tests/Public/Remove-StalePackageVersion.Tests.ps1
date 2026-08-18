Describe 'Remove-StalePackageVersion' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\gcpstools\Public\Remove-StalePackageVersion.ps1"

        function New-VersionDir {
            param($Root, $Name, $AgeDays)
            $dir = New-Item -ItemType Directory -Path (Join-Path $Root $Name)
            $dir.LastWriteTime = (Get-Date).AddDays(-$AgeDays)
            $dir
        }
    }

    It 'Removes version directories older than the threshold' {
        $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'remove')
        New-VersionDir -Root $root -Name '1.2.3' -AgeDays 30 | Out-Null

        Remove-StalePackageVersion -RootPath $root -OlderThanDays 7 -Confirm:$false

        Join-Path $root '1.2.3' | Should -Not -Exist
    }

    It 'Keeps version directories newer than the threshold' {
        $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'keep-new')
        New-VersionDir -Root $root -Name '2.0.0' -AgeDays 1 | Out-Null

        Remove-StalePackageVersion -RootPath $root -OlderThanDays 7 -Confirm:$false

        Join-Path $root '2.0.0' | Should -Exist
    }

    It 'Ignores directories that do not match the version pattern' {
        $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'ignore')
        New-VersionDir -Root $root -Name 'not-a-version' -AgeDays 30 | Out-Null

        Remove-StalePackageVersion -RootPath $root -OlderThanDays 7 -Confirm:$false

        Join-Path $root 'not-a-version' | Should -Exist
    }

    It 'Emits the removed directory objects to the pipeline' {
        $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'emit')
        New-VersionDir -Root $root -Name '3.4.5' -AgeDays 30 | Out-Null

        $result = Remove-StalePackageVersion -RootPath $root -OlderThanDays 7 -Confirm:$false

        $result | Should -HaveCount 1
        $result.Name | Should -Be '3.4.5'
    }

    It 'Does not remove anything when -WhatIf is specified' {
        $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'whatif')
        New-VersionDir -Root $root -Name '1.0.0' -AgeDays 30 | Out-Null

        Remove-StalePackageVersion -RootPath $root -OlderThanDays 7 -WhatIf

        Join-Path $root '1.0.0' | Should -Exist
    }

    It 'Honors a custom -VersionPattern' {
        $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'custom')
        New-VersionDir -Root $root -Name '0.0.1234' -AgeDays 30 | Out-Null

        Remove-StalePackageVersion -RootPath $root -OlderThanDays 7 -VersionPattern '^0\.0\.\d{4,5}$' -Confirm:$false

        Join-Path $root '0.0.1234' | Should -Not -Exist
    }

    It 'Throws when the root path does not exist' {
        $missing = Join-Path $TestDrive 'does-not-exist'

        { Remove-StalePackageVersion -RootPath $missing -Confirm:$false } | Should -Throw
    }

    It 'Does not throw when no matching directories exist' {
        $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'empty')

        { Remove-StalePackageVersion -RootPath $root -Confirm:$false } | Should -Not -Throw
    }

    It 'Rejects an out-of-range OlderThanDays value' {
        $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'range')

        { Remove-StalePackageVersion -RootPath $root -OlderThanDays 400 -Confirm:$false } | Should -Throw
    }
}
