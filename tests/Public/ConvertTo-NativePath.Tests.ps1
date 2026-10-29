Describe 'ConvertTo-NativePath' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\gcpstools\Public\ConvertTo-NativePath.ps1"
        $sep = [System.IO.Path]::DirectorySeparatorChar
    }

    It 'Converts mixed separators to the platform separator' {
        $root = [System.IO.Path]::GetFullPath($TestDrive)
        $result = ConvertTo-NativePath "$root/a\b/c.cs"
        $result | Should -Be ([System.IO.Path]::Combine($root, 'a', 'b', 'c.cs'))
    }

    It 'Resolves relative paths against the current PowerShell location' {
        Push-Location $TestDrive
        try {
            $expected = [System.IO.Path]::Combine((Get-Location).ProviderPath, 'x', 'y.txt')
            ConvertTo-NativePath 'x\sub/..\y.txt' | Should -Be $expected
        } finally {
            Pop-Location
        }
    }

    It 'Resolves a root-relative path to a full path' {
        $result = ConvertTo-NativePath '/dev/trunk/File.cs'
        [System.IO.Path]::IsPathRooted($result) | Should -BeTrue
        $result | Should -BeLike "*${sep}dev${sep}trunk${sep}File.cs"
    }

    It 'Accepts pipeline input and FullName property' {
        $root = [System.IO.Path]::GetFullPath($TestDrive)
        $results = @("$root/one", [pscustomobject]@{ FullName = "$root\two" }) | ConvertTo-NativePath
        $results | Should -Be @(
            [System.IO.Path]::Combine($root, 'one'),
            [System.IO.Path]::Combine($root, 'two')
        )
    }
}
