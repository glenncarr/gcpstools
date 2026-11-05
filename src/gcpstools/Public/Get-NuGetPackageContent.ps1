function Get-NuGetPackageContent {
<#
.SYNOPSIS
    Lists entries in a NuGet package or reads an internal file.

.DESCRIPTION
    Opens a local .nupkg as a ZIP archive using .NET, without extracting files
    or requiring external tools. By default, returns metadata objects that
    remain usable after the archive is closed.

    With EntryPath, returns the complete file as one string, preserving line
    endings. Text defaults to UTF-8 with BOM detection; invalid UTF-8 produces
    an error. Use AsByteStream for binary files.

.PARAMETER Path
    One or more literal file system paths to local packages. Accepts paths or
    FileInfo objects from the pipeline. Wildcards are not expanded.

.PARAMETER EntryPath
    Exact, case-sensitive internal file path, using ZIP forward slashes.
    Wildcards are not expanded. Directory entries cannot be read as files.

.PARAMETER AsByteStream
    Returns the selected file as a single byte array instead of decoding text.

.OUTPUTS
    System.Management.Automation.PSCustomObject
    Listing properties: PackagePath, FullName, Name, Length, CompressedLength,
    LastWriteTime, and IsDirectory.

    System.String
    Complete text of the selected file.

    System.Byte[]
    Raw bytes of the selected file when AsByteStream is specified.

.EXAMPLE
    Get-NuGetPackageContent -Path .\Example.1.0.0.nupkg

.EXAMPLE
    Get-NuGetPackageContent .\Example.1.0.0.nupkg -EntryPath 'Example.nuspec'

.EXAMPLE
    $bytes = Get-NuGetPackageContent .\Example.1.0.0.nupkg -EntryPath 'lib/netstandard2.0/Example.dll' -AsByteStream
#>
    [CmdletBinding(DefaultParameterSetName = 'List')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [ValidateNotNullOrEmpty()]
        [string[]]$Path,

        [Parameter(Mandatory, Position = 1, ParameterSetName = 'Read')]
        [ValidateNotNullOrEmpty()]
        [string]$EntryPath,

        [Parameter(ParameterSetName = 'Read')]
        [switch]$AsByteStream
    )

    begin {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    }

    process {
        foreach ($package in $Path) {
            $archive = $null
            $stream = $null
            $reader = $null
            $buffer = $null
            try {
                $file = Get-Item -LiteralPath $package -Force -ErrorAction Stop
                if ($file -isnot [System.IO.FileInfo]) {
                    throw "'$package' is not a file system file."
                }

                $archive = [System.IO.Compression.ZipFile]::OpenRead($file.FullName)
                if ($PSCmdlet.ParameterSetName -eq 'List') {
                    foreach ($entry in $archive.Entries) {
                        [pscustomobject]@{
                            PackagePath      = $file.FullName
                            FullName         = $entry.FullName
                            Name             = $entry.Name
                            Length           = $entry.Length
                            CompressedLength = $entry.CompressedLength
                            LastWriteTime    = $entry.LastWriteTime
                            IsDirectory      = $entry.FullName.EndsWith('/')
                        }
                    }
                }
                else {
                    $entry = $archive.GetEntry($EntryPath)
                    if ($null -eq $entry) {
                        throw "Entry '$EntryPath' was not found."
                    }
                    if ($entry.FullName.EndsWith('/')) {
                        throw "Entry '$EntryPath' is a directory, not a file."
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
                $message = "Failed to read NuGet package '$package': $($_.Exception.Message)"
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
