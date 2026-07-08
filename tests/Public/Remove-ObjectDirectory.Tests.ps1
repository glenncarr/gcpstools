Describe 'Remove-ObjectDirectory' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\gcpstools\Public\Remove-ObjectDirectory.ps1"
    }

    It 'Does not remove obj directories when -WhatIf is specified' {
        $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'whatif')
        New-Item -ItemType Directory -Path (Join-Path $root 'obj') | Out-Null

        Remove-ObjectDirectory -Path $root -WhatIf

        Join-Path $root 'obj' | Should -Exist
    }

    It 'Removes obj directories recursively' {
        $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'remove')
        New-Item -ItemType Directory -Path (Join-Path $root 'obj')        | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'src\obj')    | Out-Null

        Remove-ObjectDirectory -Path $root

        Join-Path $root 'obj'     | Should -Not -Exist
        Join-Path $root 'src\obj' | Should -Not -Exist
    }

    It 'Does not throw when no obj directories exist' {
        $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'empty')

        { Remove-ObjectDirectory -Path $root } | Should -Not -Throw
    }
}
