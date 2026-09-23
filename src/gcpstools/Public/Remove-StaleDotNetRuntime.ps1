function Remove-StaleDotNetRuntime {
    <#
    .SYNOPSIS
        Removes superseded .NET shared framework (runtime) versions.

    .DESCRIPTION
        Inspects the installed .NET shared frameworks (Microsoft.NETCore.App,
        Microsoft.AspNetCore.App, Microsoft.WindowsDesktop.App, and any other
        framework found under the dotnet 'shared' folder) and removes every
        version that has been superseded by a newer patch within the same
        major.minor band. The newest version of each band is always kept.

        Prerelease versions are ranked below the matching stable release, so a
        stable 8.0.11 supersedes 8.0.11-preview.1.

        Removing a shared framework requires an elevated session. Supports
        -WhatIf and -Confirm; by default each removal must be confirmed.

    .PARAMETER Path
        One or more shared framework directories to evaluate (the folder that
        contains the version subdirectories). Defaults to every framework found
        under the 64-bit and 32-bit dotnet installations.

    .PARAMETER Band
        Limits processing to the specified major.minor bands, for example
        '6.0' or '8.0'. By default all bands are evaluated.

    .PARAMETER KeepVersions
        The number of most recent versions to keep in each major.minor band.
        Defaults to 1.

    .EXAMPLE
        Remove-StaleDotNetRuntime -WhatIf

        Shows which superseded shared framework versions would be removed.

    .EXAMPLE
        Remove-StaleDotNetRuntime -Confirm:$false

        Removes every superseded shared framework version without prompting.

    .EXAMPLE
        Remove-StaleDotNetRuntime -Band '6.0', '8.0' -KeepVersions 2

        Keeps the two newest patches of the 6.0 and 8.0 bands and removes the rest.

    .OUTPUTS
        System.IO.DirectoryInfo
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([System.IO.DirectoryInfo])]
    param(
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string[]]$Path,

        [ValidatePattern('^\d+\.\d+$')]
        [string[]]$Band,

        [ValidateRange(1, 1000)]
        [int]$KeepVersions = 1
    )

    begin {
        $versionRegex = [regex]::new('^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?:-(?<pre>[0-9A-Za-z.-]+))?$')
        $removed = $false

        function Test-Elevated {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = [Security.Principal.WindowsPrincipal]::new($identity)
            $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }

        function Get-DefaultSharedPath {
            $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
                Where-Object { $_ } |
                Select-Object -Unique |
                ForEach-Object { Join-Path $_ 'dotnet\shared' }

            foreach ($root in $roots) {
                if (Test-Path -LiteralPath $root -PathType Container) {
                    (Get-ChildItem -LiteralPath $root -Directory).FullName
                }
            }
        }

        if (-not $WhatIfPreference -and -not (Test-Elevated)) {
            Write-Warning 'Not running elevated; removing a .NET shared framework requires administrator rights and will likely fail with access denied.'
        }

        $resolvedPaths = [System.Collections.Generic.List[string]]::new()
    }

    process {
        foreach ($item in $Path) {
            if ($item) { $resolvedPaths.Add($item) }
        }
    }

    end {
        if ($resolvedPaths.Count -eq 0) {
            $discovered = Get-DefaultSharedPath
            foreach ($item in $discovered) { $resolvedPaths.Add($item) }
        }

        if ($resolvedPaths.Count -eq 0) {
            Write-Warning 'No .NET shared framework directories were found.'
            return
        }

        $failures = [System.Collections.Generic.List[string]]::new()

        foreach ($frameworkPath in ($resolvedPaths | Select-Object -Unique)) {
            if (-not (Test-Path -LiteralPath $frameworkPath -PathType Container)) {
                Write-Verbose "Skipping missing framework directory: $frameworkPath"
                continue
            }

            $versions = Get-ChildItem -LiteralPath $frameworkPath -Directory |
                ForEach-Object {
                    $match = $versionRegex.Match($_.Name)
                    if (-not $match.Success) {
                        Write-Verbose "Ignoring non-version directory: $($_.FullName)"
                        return
                    }

                    [PSCustomObject]@{
                        Directory  = $_
                        Band       = '{0}.{1}' -f $match.Groups['major'].Value, $match.Groups['minor'].Value
                        Version    = [version]('{0}.{1}.{2}' -f $match.Groups['major'].Value, $match.Groups['minor'].Value, $match.Groups['patch'].Value)
                        IsStable   = -not $match.Groups['pre'].Success
                        Prerelease = $match.Groups['pre'].Value
                    }
                }

            if (-not $versions) {
                Write-Verbose "No installed versions found in: $frameworkPath"
                continue
            }

            foreach ($group in ($versions | Group-Object Band)) {
                if ($Band -and $group.Name -notin $Band) {
                    continue
                }

                $ordered = $group.Group | Sort-Object Version, IsStable, Prerelease -Descending
                $keep = $ordered | Select-Object -First $KeepVersions
                $stale = $ordered | Select-Object -Skip $KeepVersions

                Write-Verbose "$frameworkPath [$($group.Name)]: keeping $(($keep.Directory.Name) -join ', ')"

                foreach ($candidate in $stale) {
                    $target = $candidate.Directory.FullName
                    if (-not $PSCmdlet.ShouldProcess($target, 'Remove .NET shared framework version')) {
                        continue
                    }

                    try {
                        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
                        Write-Verbose "Deleted: $target"
                        $removed = $true
                        $candidate.Directory
                    }
                    catch {
                        $failures.Add("${target}: $($_.Exception.Message)")
                    }
                }
            }
        }

        if (-not $removed) {
            Write-Verbose 'No superseded .NET shared framework versions were removed.'
        }

        if ($failures.Count -gt 0) {
            $noun = if ($failures.Count -eq 1) { 'version' } else { 'versions' }
            throw "Failed to delete $($failures.Count) .NET shared framework ${noun}:`n$($failures -join "`n")"
        }
    }
}
