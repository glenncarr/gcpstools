function ConvertTo-NativePath {
<#
.SYNOPSIS
    Normalizes a path to a full path using the current operating system's directory separators.

.DESCRIPTION
    Replaces both '\' and '/' with the platform directory separator, then resolves the result
    with [System.IO.Path]::GetFullPath. Relative paths are resolved against the current
    PowerShell file system location. The path does not need to exist.

.PARAMETER Path
    One or more paths to normalize.

.EXAMPLE
    ConvertTo-NativePath '/src/project/Example.cs'

.EXAMPLE
    'src\gcpstools/Public\..\gcpstools.psd1' | ConvertTo-NativePath
#>
[CmdletBinding()]
[OutputType([string])]
param (
    [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
    [Alias('FullName')]
    [string[]]$Path
)

process {
    $basePath = $PSCmdlet.SessionState.Path.CurrentFileSystemLocation.ProviderPath
    foreach ($item in $Path) {
        $normalized = $item -replace '[\\/]', [System.IO.Path]::DirectorySeparatorChar
        [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($basePath, $normalized))
    }
}
}
