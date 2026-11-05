Describe 'Get-NuGetPackageContent' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\gcpstools\Public\Get-NuGetPackageContent.ps1"
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        function New-TestNuGetPackage {
            param([string]$Path, [switch]$Empty)

            $archive = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
            try {
                if (-not $Empty) {
                    $utf8 = [System.Text.UTF8Encoding]::new($false)
                    $utf16 = [System.Text.Encoding]::Unicode
                    $entries = [ordered]@{
                        'Example.nuspec' = $utf8.GetBytes("<package>`r`n</package>`n")
                        'lib/' = [byte[]]@()
                        'lib/netstandard2.0/Example.dll' = [byte[]]@(0, 1, 128, 255)
                        'empty.txt' = [byte[]]@()
                        'docs/readme.txt' = $utf8.GetBytes("caf$([char]0xE9)")
                        'docs/utf16.txt' = [byte[]]($utf16.GetPreamble() + $utf16.GetBytes('BOM text'))
                        'docs/[literal].txt' = $utf8.GetBytes('literal')
                    }
                    foreach ($name in $entries.Keys) {
                        $entry = $archive.CreateEntry($name)
                        $entry.LastWriteTime = [DateTimeOffset]::new(2026, 1, 2, 3, 4, 6, [TimeSpan]::Zero)
                        $stream = $entry.Open()
                        try {
                            $bytes = $entries[$name]
                            $stream.Write($bytes, 0, $bytes.Length)
                        }
                        finally {
                            $stream.Dispose()
                        }
                    }
                }
            }
            finally {
                $archive.Dispose()
            }
        }

        function Assert-PackageReleased {
            param([string]$Path)

            $handle = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $handle.Dispose()
        }
    }

    BeforeEach {
        $packagePath = Join-Path $TestDrive 'Example[1].nupkg'
        if (Test-Path -LiteralPath $packagePath) {
            Remove-Item -LiteralPath $packagePath -Force
        }
        New-TestNuGetPackage -Path $packagePath
    }

    It 'Lists independent metadata objects including directory entries' {
        $entries = @(Get-NuGetPackageContent -Path $packagePath)
        $entries.Count | Should -Be 7
        Assert-PackageReleased $packagePath
        $file = $entries | Where-Object FullName -eq 'Example.nuspec'
        $file.PackagePath | Should -Be $packagePath
        $file.Name | Should -Be 'Example.nuspec'
        $file.Length | Should -Be 22
        $file.CompressedLength | Should -BeGreaterThan 0
        $file.LastWriteTime | Should -BeOfType ([DateTimeOffset])
        $file.LastWriteTime.Year | Should -Be 2026
        $file.IsDirectory | Should -BeFalse
        ($entries | Where-Object FullName -eq 'lib/').IsDirectory | Should -BeTrue
        $file | Should -Not -BeOfType ([System.IO.Compression.ZipArchiveEntry])
    }

    It 'Returns complete text with original line endings and releases the archive' {
        $result = Get-NuGetPackageContent $packagePath -EntryPath 'Example.nuspec'
        $result | Should -BeOfType ([string])
        $result | Should -BeExactly "<package>`r`n</package>`n"
        Assert-PackageReleased $packagePath
    }

    It 'Decodes UTF-8 without a BOM' {
        Get-NuGetPackageContent $packagePath 'docs/readme.txt' |
            Should -BeExactly "caf$([char]0xE9)"
    }

    It 'Detects a UTF-16 BOM without returning the BOM' {
        Get-NuGetPackageContent $packagePath 'docs/utf16.txt' | Should -BeExactly 'BOM text'
    }

    It 'Returns binary content as a single byte array' {
        $output = @(Get-NuGetPackageContent $packagePath 'lib/netstandard2.0/Example.dll' -AsByteStream)
        $output.Count | Should -Be 1
        Should -ActualValue $output[0] -BeOfType ([byte[]])
        [Convert]::ToBase64String($output[0]) | Should -Be 'AAGA/w=='
        Assert-PackageReleased $packagePath
    }

    It 'Returns an empty string for an empty text file' {
        $output = @(Get-NuGetPackageContent $packagePath 'empty.txt')
        $output.Count | Should -Be 1
        $output[0] | Should -BeExactly ''
    }

    It 'Returns a single empty byte array for an empty binary file' {
        $output = @(Get-NuGetPackageContent $packagePath 'empty.txt' -AsByteStream)
        $output.Count | Should -Be 1
        Should -ActualValue $output[0] -BeOfType ([byte[]])
        $output[0].Length | Should -Be 0
    }

    It 'Treats internal brackets literally' {
        Get-NuGetPackageContent $packagePath 'docs/[literal].txt' | Should -BeExactly 'literal'
    }

    It 'Accepts multiple paths and pipeline FileInfo objects' {
        @(Get-NuGetPackageContent -Path $packagePath, $packagePath).Count | Should -Be 14
        $result = Get-Item -LiteralPath $packagePath | Get-NuGetPackageContent -EntryPath 'empty.txt'
        $result | Should -BeExactly ''
        @($packagePath | Get-NuGetPackageContent).Count | Should -Be 7
    }

    It 'Resolves relative package paths against the PowerShell location' {
        Push-Location $TestDrive
        try {
            Get-NuGetPackageContent '.\Example[1].nupkg' 'Example.nuspec' |
                Should -BeExactly "<package>`r`n</package>`n"
        }
        finally {
            Pop-Location
        }
    }

    It 'Returns no entries for an empty ZIP archive' {
        $emptyPath = Join-Path $TestDrive 'empty.nupkg'
        New-TestNuGetPackage $emptyPath -Empty
        @(Get-NuGetPackageContent $emptyPath).Count | Should -Be 0
        Assert-PackageReleased $emptyPath
    }

    It 'Reports missing packages' {
        { Get-NuGetPackageContent (Join-Path $TestDrive 'missing.nupkg') -ErrorAction Stop } |
            Should -Throw '*Failed to read NuGet package*'
    }

    It 'Rejects directories as package paths' {
        { Get-NuGetPackageContent $TestDrive -ErrorAction Stop } |
            Should -Throw '*not a file system file*'
    }

    It 'Reports invalid ZIP archives and releases the file' {
        $invalidPath = Join-Path $TestDrive 'invalid.nupkg'
        [System.IO.File]::WriteAllText($invalidPath, 'not a ZIP')
        { Get-NuGetPackageContent $invalidPath -ErrorAction Stop } |
            Should -Throw '*Failed to read NuGet package*'
        Assert-PackageReleased $invalidPath
    }

    It 'Reports missing entries and releases the archive' {
        { Get-NuGetPackageContent $packagePath 'missing.txt' -ErrorAction Stop } |
            Should -Throw "*Entry 'missing.txt' was not found*"
        Assert-PackageReleased $packagePath
    }

    It 'Matches entry paths case-sensitively without expanding wildcards' {
        { Get-NuGetPackageContent $packagePath 'example.nuspec' -ErrorAction Stop } |
            Should -Throw '*was not found*'
        { Get-NuGetPackageContent $packagePath '*.nuspec' -ErrorAction Stop } |
            Should -Throw '*was not found*'
    }

    It 'Rejects directory entries rather than returning empty content' {
        { Get-NuGetPackageContent $packagePath 'lib/' -ErrorAction Stop } |
            Should -Throw '*is a directory*'
        Assert-PackageReleased $packagePath
    }

    It 'Reports invalid UTF-8 instead of silently replacing bytes' {
        { Get-NuGetPackageContent $packagePath 'lib/netstandard2.0/Example.dll' -ErrorAction Stop } |
            Should -Throw '*Failed to read NuGet package*'
        Assert-PackageReleased $packagePath
    }

    It 'Reports a package error and continues to later pipeline input' {
        $errors = @()
        $result = @((Join-Path $TestDrive 'missing.nupkg'), $packagePath) |
            Get-NuGetPackageContent -EntryPath 'Example.nuspec' -ErrorAction SilentlyContinue -ErrorVariable errors
        $result | Should -BeExactly "<package>`r`n</package>`n"
        @($errors | Where-Object FullyQualifiedErrorId -like 'NuGetPackageReadFailed*').Count | Should -Be 1
    }

    It 'Exports the command in the module manifest' {
        $manifest = Import-PowerShellDataFile "$PSScriptRoot\..\..\src\gcpstools\gcpstools.psd1"
        $manifest.FunctionsToExport | Should -Contain 'Get-NuGetPackageContent'
    }
}
