function Remove-StalePackageVersion {
    <#
    .SYNOPSIS
        Removes stale NuGet package version directories from a repository folder.

    .DESCRIPTION
        Recursively searches RootPath for directories whose names match a
        version pattern (semantic-version style by default) and whose last write
        time is older than the DaysOld threshold, then deletes them.
        Deleted directories are emitted to the pipeline. Supports -WhatIf and -Confirm.

    .PARAMETER RootPath
        The root directory to search for stale package version folders.

    .PARAMETER OlderThanDays
        The age threshold in days (0-365). Directories last modified more than
        this many days ago are removed. Defaults to 7.

    .PARAMETER VersionPattern
        A regular expression matched against each directory name to identify
        package version folders. Defaults to a semantic-version style pattern
        (e.g. 1.2.3, 0.0.1234, 2.0.0.5, 1.2.3-beta).

    .EXAMPLE
        Remove-StalePackageVersion -RootPath C:\packages

        Removes version folders under C:\packages that are older than 7 days.

    .EXAMPLE
        Remove-StalePackageVersion -RootPath C:\packages -OlderThanDays 30 -WhatIf

        Previews which version folders older than 30 days would be removed.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([System.IO.DirectoryInfo])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,

        [ValidateRange(0, 365)]
        [Alias('DaysOld')]
        [int]$OlderThanDays = 7,

        [string]$VersionPattern = '^\d+\.\d+\.\d+(\.\d+)?(-[0-9A-Za-z.-]+)?$'
    )

    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        throw "Root path does not exist or is not a directory: $RootPath"
    }

    $cutoffDate = (Get-Date).AddDays(-$OlderThanDays)
    $versionRegex = [regex]::new($VersionPattern)

    $staleDirectories = Get-ChildItem -LiteralPath $RootPath -Directory -Recurse -Force |
        Where-Object {
            $versionRegex.IsMatch($_.Name) -and $_.LastWriteTime -lt $cutoffDate
        }

    if (-not $staleDirectories) {
        Write-Verbose "No stale package version directories found under: $RootPath"
        return
    }

    $failures = [System.Collections.Generic.List[string]]::new()

    foreach ($directory in $staleDirectories) {
        if (-not $PSCmdlet.ShouldProcess($directory.FullName, 'Remove directory')) {
            continue
        }
        try {
            Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction Stop
            Write-Verbose "Deleted: $($directory.FullName)"
            $directory
        }
        catch {
            $failures.Add("$($directory.FullName): $($_.Exception.Message)")
        }
    }

    if ($failures.Count -gt 0) {
        $noun = if ($failures.Count -eq 1) { 'directory' } else { 'directories' }
        throw "Failed to delete $($failures.Count) package version $noun:`n$($failures -join "`n")"
    }
}