Describe 'Add-SvnUnversioned' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\gcpstools\Public\Add-SvnUnversioned.ps1"

        function svn { }
    }

    It 'Adds files reported as unversioned by svn' {
        $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'add')
        New-Item -ItemType File -Path (Join-Path $root 'new.txt') | Out-Null
        Mock svn { '?       new.txt' }

        Add-SvnUnversioned -Path $root -Confirm:$false

        Should -Invoke svn -Times 1 -Exactly -ParameterFilter {
            $args[0] -eq 'add' -and $args[1] -eq 'new.txt'
        }
    }

    It 'Skips files matching an -Exclude pattern' {
        $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'exclude')
        New-Item -ItemType File -Path (Join-Path $root 'new.txt') | Out-Null
        New-Item -ItemType File -Path (Join-Path $root 'skip.log') | Out-Null
        Mock svn { '?       new.txt', '?       skip.log' }

        Add-SvnUnversioned -Path $root -Exclude '*.log' -Confirm:$false

        Should -Invoke svn -Times 1 -Exactly -ParameterFilter {
            $args[0] -eq 'add' -and $args[1] -eq 'new.txt'
        }
        Should -Invoke svn -Times 0 -Exactly -ParameterFilter {
            $args[0] -eq 'add' -and $args[1] -eq 'skip.log'
        }
    }

    It 'Does not add anything when -WhatIf is specified' {
        $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'whatif')
        New-Item -ItemType File -Path (Join-Path $root 'new.txt') | Out-Null
        Mock svn { '?       new.txt' }

        Add-SvnUnversioned -Path $root -WhatIf

        Should -Invoke svn -Times 0 -Exactly -ParameterFilter {
            $args[0] -eq 'add'
        }
    }

    It 'Ignores versioned entries (status other than "?")' {
        $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'versioned')
        New-Item -ItemType File -Path (Join-Path $root 'modified.txt') | Out-Null
        Mock svn { 'M       modified.txt' }

        Add-SvnUnversioned -Path $root -Confirm:$false

        Should -Invoke svn -Times 1 -Exactly -ParameterFilter {
            $args[0] -eq 'st'
        }
    }

    It 'Warns and does not throw for a non-existent path' {
        $missing = Join-Path $TestDrive 'does-not-exist'

        { Add-SvnUnversioned -Path $missing -Confirm:$false -WarningAction SilentlyContinue } |
            Should -Not -Throw
    }
}