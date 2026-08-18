Describe 'Remove-SvnUnversioned' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\gcpstools\Public\Remove-SvnUnversioned.ps1"

        # Placeholder so Pester can mock the native 'svn' command even when SVN is not installed.
        function svn { }
    }

    It 'Removes files reported as unversioned by svn' {
        $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'remove')
        New-Item -ItemType File -Path (Join-Path $root 'junk.txt') | Out-Null
        New-Item -ItemType File -Path (Join-Path $root 'keep.txt') | Out-Null
        Mock svn { '?       junk.txt' }

        Remove-SvnUnversioned -Path $root -Confirm:$false

        Join-Path $root 'junk.txt' | Should -Not -Exist
        Join-Path $root 'keep.txt' | Should -Exist
    }

    It 'Skips files matching an -Exclude pattern' {
        $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'exclude')
        New-Item -ItemType File -Path (Join-Path $root 'junk.txt') | Out-Null
        New-Item -ItemType File -Path (Join-Path $root 'skip.log') | Out-Null
        Mock svn { '?       junk.txt', '?       skip.log' }

        Remove-SvnUnversioned -Path $root -Exclude '*.log' -Confirm:$false

        Join-Path $root 'junk.txt' | Should -Not -Exist
        Join-Path $root 'skip.log' | Should -Exist
    }

    It 'Does not remove anything when -WhatIf is specified' {
        $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'whatif')
        New-Item -ItemType File -Path (Join-Path $root 'junk.txt') | Out-Null
        Mock svn { '?       junk.txt' }

        Remove-SvnUnversioned -Path $root -WhatIf

        Join-Path $root 'junk.txt' | Should -Exist
    }

    It 'Ignores versioned entries (status other than "?")' {
        $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'versioned')
        New-Item -ItemType File -Path (Join-Path $root 'modified.txt') | Out-Null
        Mock svn { 'M       modified.txt' }

        Remove-SvnUnversioned -Path $root -Confirm:$false

        Join-Path $root 'modified.txt' | Should -Exist
    }

    It 'Warns and does not throw for a non-existent path' {
        $missing = Join-Path $TestDrive 'does-not-exist'

        { Remove-SvnUnversioned -Path $missing -Confirm:$false -WarningAction SilentlyContinue } |
            Should -Not -Throw
    }
}
