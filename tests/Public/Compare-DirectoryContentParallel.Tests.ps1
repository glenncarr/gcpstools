Describe 'Compare-DirectoryContentParallel' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\gcpstools\Public\Compare-DirectoryContentParallel.ps1"
    }

    It 'Throws on PowerShell 5.x' {
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            Set-ItResult -Skipped -Because 'Only relevant on PS5.x'
            return
        }
        { Compare-DirectoryContentParallel -Source '.' -Destination '.' } | Should -Throw
    }

    It 'Returns MissingInDest for a file only in source' {
        if ($PSVersionTable.PSVersion.Major -lt 7) {
            Set-ItResult -Skipped -Because 'Requires PowerShell 7+'
            return
        }
        $src = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'src1')
        $dst = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'dst1')
        Set-Content -Path (Join-Path $src 'file.txt') -Value 'hello'

        $result = Compare-DirectoryContentParallel -Source $src -Destination $dst
        $result.Status | Should -Be 'MissingInDest'
    }

    It 'Returns Match for identical files when -ShowAll is specified' {
        if ($PSVersionTable.PSVersion.Major -lt 7) {
            Set-ItResult -Skipped -Because 'Requires PowerShell 7+'
            return
        }
        $src = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'src2')
        $dst = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'dst2')
        Set-Content -Path (Join-Path $src 'file.txt') -Value 'identical'
        Set-Content -Path (Join-Path $dst 'file.txt') -Value 'identical'

        $result = Compare-DirectoryContentParallel -Source $src -Destination $dst -ShowAll
        $result.Status | Should -Be 'Match'
    }

    It 'Returns ContentMismatch for files with different content' {
        if ($PSVersionTable.PSVersion.Major -lt 7) {
            Set-ItResult -Skipped -Because 'Requires PowerShell 7+'
            return
        }
        $src = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'src3')
        $dst = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'dst3')
        Set-Content -Path (Join-Path $src 'file.txt') -Value 'source content'
        Set-Content -Path (Join-Path $dst 'file.txt') -Value 'dest content'

        $result = Compare-DirectoryContentParallel -Source $src -Destination $dst
        $result.Status | Should -Be 'ContentMismatch'
    }

    It 'Returns no results for two empty directories' {
        if ($PSVersionTable.PSVersion.Major -lt 7) {
            Set-ItResult -Skipped -Because 'Requires PowerShell 7+'
            return
        }
        $src = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'src4')
        $dst = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'dst4')

        $result = Compare-DirectoryContentParallel -Source $src -Destination $dst
        $result | Should -BeNullOrEmpty
    }
}
