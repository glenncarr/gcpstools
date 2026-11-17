function Get-NuGetPackageContent {
<#
.SYNOPSIS
    Lists, reads, or extracts files from a NuGet package.

.DESCRIPTION
    Opens a local .nupkg as a ZIP archive using .NET without requiring external
    tools. By default, returns metadata objects that remain usable after the
    archive is closed. The default table displays FullName, LastWriteTime,
    Length, and CompressedLength.

    With EntryPath, returns the complete file as one string, preserving line
    endings. Text defaults to UTF-8 with BOM detection; invalid UTF-8 produces
    an error. Use AsByteStream for binary files. With DestinationPath, extracts
    all files, or only the specified EntryPath values, beneath that directory.

.PARAMETER Path
    One or more literal file system paths to local packages. Accepts paths or
    FileInfo objects from the pipeline. Wildcards are not expanded.

.PARAMETER EntryPath
    Exact, case-sensitive internal file path, using ZIP forward slashes.
    Wildcards are not expanded. Directory entries cannot be read as files.

.PARAMETER AsByteStream
    Returns the selected file as a single byte array instead of decoding text.

.PARAMETER DestinationPath
    Directory to extract files into. Without EntryPath, all package entries are
    extracted. With EntryPath, only those exact, case-sensitive file paths are
    extracted. Existing files are not overwritten unless Force is specified.

.PARAMETER Force
    Overwrites extracted files that already exist.

.OUTPUTS
    System.Management.Automation.PSCustomObject
    Listing properties: PackagePath, FullName, Name, Length, CompressedLength,
    LastWriteTime, and IsDirectory.

    System.String
    Complete text of the selected file.

    System.Byte[]
    Raw bytes of the selected file when AsByteStream is specified.

    System.IO.FileInfo
    Extracted files when DestinationPath is specified.

.EXAMPLE
    Get-NuGetPackageContent -Path .\Example.1.0.0.nupkg

.EXAMPLE
    Get-NuGetPackageContent .\Example.1.0.0.nupkg -EntryPath 'Example.nuspec'

.EXAMPLE
    $bytes = Get-NuGetPackageContent .\Example.1.0.0.nupkg -EntryPath 'lib/netstandard2.0/Example.dll' -AsByteStream

.EXAMPLE
    Get-NuGetPackageContent .\Example.1.0.0.nupkg -DestinationPath .\package

.EXAMPLE
    Get-NuGetPackageContent .\Example.1.0.0.nupkg -EntryPath 'Example.nuspec', 'README.md' -DestinationPath .\selected
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [ValidateNotNullOrEmpty()]
        [string[]]$Path,

        [Parameter(Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string[]]$EntryPath,

        [switch]$AsByteStream,

        [string]$DestinationPath,

        [switch]$Force
    )

    begin {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    }

    process {
        foreach ($package in $Path) {
            $archive = $null
            $stream = $null
            $reader = $null
            $buffer = $null
            try {
                if ($Force -and -not $PSBoundParameters.ContainsKey('DestinationPath')) {
                    throw 'Force can only be used with DestinationPath.'
                }
                $file = Get-Item -LiteralPath $package -Force -ErrorAction Stop
                if ($file -isnot [System.IO.FileInfo]) {
                    throw "'$package' is not a file system file."
                }

                $archive = [System.IO.Compression.ZipFile]::OpenRead($file.FullName)
                if ($PSBoundParameters.ContainsKey('DestinationPath')) {
                    if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
                        throw 'DestinationPath cannot be empty.'
                    }
                    if ($AsByteStream) {
                        throw 'AsByteStream cannot be used with DestinationPath.'
                    }
                    $destination = [System.IO.Path]::GetFullPath($DestinationPath)
                    if (Test-Path -LiteralPath $destination -PathType Leaf) {
                        throw "Destination path '$DestinationPath' is a file, not a directory."
                    }

                    $destinationPrefix = $destination.TrimEnd(
                        [System.IO.Path]::DirectorySeparatorChar,
                        [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
                    $comparison = if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
                        [System.StringComparison]::OrdinalIgnoreCase
                    }
                    else {
                        [System.StringComparison]::Ordinal
                    }

                    if ($PSBoundParameters.ContainsKey('EntryPath')) {
                        $entriesToExtract = foreach ($requestedPath in $EntryPath) {
                            $selectedEntry = $archive.GetEntry($requestedPath)
                            if ($null -eq $selectedEntry) {
                                throw "Entry '$requestedPath' was not found."
                            }
                            if ($selectedEntry.FullName.EndsWith('/')) {
                                throw "Entry '$requestedPath' is a directory, not a file."
                            }
                            $selectedEntry
                        }
                    }
                    else {
                        $entriesToExtract = $archive.Entries
                    }

                    foreach ($entry in $entriesToExtract) {
                        $relativePath = $entry.FullName.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
                        $outputPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($destination, $relativePath))
                        if (-not $outputPath.StartsWith($destinationPrefix, $comparison)) {
                            throw "Entry '$($entry.FullName)' would extract outside destination '$DestinationPath'."
                        }

                        $isDirectory = $entry.FullName.EndsWith('/')
                        $action = if ($isDirectory) { 'Create directory' } else { 'Extract file' }
                        if (-not $PSCmdlet.ShouldProcess($outputPath, "$action from '$($file.FullName)'")) {
                            continue
                        }

                        if ($isDirectory) {
                            New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
                            continue
                        }

                        $parentPath = [System.IO.Path]::GetDirectoryName($outputPath)
                        if (-not (Test-Path -LiteralPath $parentPath -PathType Container)) {
                            New-Item -ItemType Directory -Path $parentPath -Force | Out-Null
                        }
                        if ((Test-Path -LiteralPath $outputPath) -and -not $Force) {
                            throw "File '$outputPath' already exists. Use -Force to overwrite it."
                        }

                        $entryStream = $null
                        $outputStream = $null
                        try {
                            $entryStream = $entry.Open()
                            $mode = if ($Force) { [System.IO.FileMode]::Create } else { [System.IO.FileMode]::CreateNew }
                            $outputStream = [System.IO.File]::Open($outputPath, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                            $entryStream.CopyTo($outputStream)
                        }
                        finally {
                            if ($null -ne $outputStream) { $outputStream.Dispose() }
                            if ($null -ne $entryStream) { $entryStream.Dispose() }
                        }
                        Get-Item -LiteralPath $outputPath
                    }
                }
                elseif (-not $PSBoundParameters.ContainsKey('EntryPath')) {
                    if ($AsByteStream) {
                        throw 'AsByteStream requires EntryPath.'
                    }
                    foreach ($entry in $archive.Entries) {
                        $metadata = [pscustomobject]@{
                            PackagePath      = $file.FullName
                            FullName         = $entry.FullName
                            Name             = $entry.Name
                            Length           = $entry.Length
                            CompressedLength = $entry.CompressedLength
                            LastWriteTime    = $entry.LastWriteTime
                            IsDirectory      = $entry.FullName.EndsWith('/')
                        }
                        $displayProperties = [System.Management.Automation.PSPropertySet]::new(
                            'DefaultDisplayPropertySet',
                            [string[]]@('FullName', 'LastWriteTime', 'Length', 'CompressedLength'))
                        $metadata | Add-Member -MemberType MemberSet -Name PSStandardMembers -Value $displayProperties
                        $metadata
                    }
                }
                else {
                    if ($EntryPath.Count -ne 1) {
                        throw 'Specify exactly one EntryPath when reading package content.'
                    }
                    $entry = $archive.GetEntry($EntryPath[0])
                    if ($null -eq $entry) {
                        throw "Entry '$($EntryPath[0])' was not found."
                    }
                    if ($entry.FullName.EndsWith('/')) {
                        throw "Entry '$($EntryPath[0])' is a directory, not a file."
                    }

                    $stream = $entry.Open()
                    if ($AsByteStream) {
                        $buffer = [System.IO.MemoryStream]::new()
                        $stream.CopyTo($buffer)
                        Write-Output -NoEnumerate ($buffer.ToArray())
                    }
                    else {
                        $encoding = [System.Text.UTF8Encoding]::new($false, $true)
                        $reader = [System.IO.StreamReader]::new($stream, $encoding, $true)
                        $reader.ReadToEnd()
                    }
                }
            }
            catch {
                $operation = if ($PSBoundParameters.ContainsKey('DestinationPath')) { 'extract from' } else { 'read' }
                $message = "Failed to $operation NuGet package '$package': $($_.Exception.Message)"
                $exception = [System.IO.IOException]::new($message, $_.Exception)
                $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    $exception, 'NuGetPackageReadFailed', [System.Management.Automation.ErrorCategory]::ReadError, $package))
            }
            finally {
                if ($null -ne $reader) { $reader.Dispose() }
                elseif ($null -ne $stream) { $stream.Dispose() }
                if ($null -ne $buffer) { $buffer.Dispose() }
                if ($null -ne $archive) { $archive.Dispose() }
            }
        }
    }
}
