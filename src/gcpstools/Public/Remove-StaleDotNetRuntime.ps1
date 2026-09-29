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

        By default the removal is delegated to the .NET Uninstall Tool
        (dotnet-core-uninstall --all-lower-patches), which uninstalls each
        version through its original installer instead of deleting files. When
        the tool is missing it is installed with winget. The tool keeps versions
        that Visual Studio may require.

        The tool's filter options are mutually exclusive, so it cannot express
        every request. The original file-system removal is used instead when
        -Path or -Band is specified, when -KeepVersions is greater than 1, when
        the tool is unavailable, or when the tool fails.

        Prerelease versions are ranked below the matching stable release, so a
        stable 8.0.11 supersedes 8.0.11-preview.1.

        Removing a shared framework requires an elevated session. Supports
        -WhatIf and -Confirm; by default each removal must be confirmed.

    .PARAMETER Path
        One or more shared framework directories to evaluate (the folder that
        contains the version subdirectories). Defaults to every framework found
        under the 64-bit and 32-bit dotnet installations. Specifying this
        parameter forces the file-system removal.

    .PARAMETER Band
        Limits processing to the specified major.minor bands, for example
        '6.0' or '8.0'. By default all bands are evaluated. Specifying this
        parameter forces the file-system removal.

    .PARAMETER KeepVersions
        The number of most recent versions to keep in each major.minor band.
        Defaults to 1. A value greater than 1 forces the file-system removal.

    .PARAMETER IncludeSdk
        Also removes superseded .NET SDKs. Only the .NET Uninstall Tool can
        remove SDKs; the file-system fallback ignores them.

    .EXAMPLE
        Remove-StaleDotNetRuntime -WhatIf

        Shows which superseded shared framework versions would be removed.

    .EXAMPLE
        Remove-StaleDotNetRuntime -Confirm:$false

        Removes every superseded shared framework version without prompting.

    .EXAMPLE
        Remove-StaleDotNetRuntime -IncludeSdk -Confirm:$false

        Also removes the SDKs that have been superseded by a higher patch.

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
        [int]$KeepVersions = 1,

        [switch]$IncludeSdk
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

        function Get-SharedFrameworkVersion {
            foreach ($frameworkPath in (Get-DefaultSharedPath)) {
                Get-ChildItem -LiteralPath $frameworkPath -Directory -ErrorAction SilentlyContinue
            }
        }

        function Get-UninstallToolPath {
            $command = Get-Command 'dotnet-core-uninstall' -CommandType Application -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($command) {
                return $command.Source
            }

            foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
                if (-not $root) { continue }

                $candidate = Join-Path $root 'dotnet-core-uninstall\dotnet-core-uninstall.exe'
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    return $candidate
                }
            }
        }

        function Install-UninstallTool {
            if (-not (Get-Command 'winget' -CommandType Application -ErrorAction SilentlyContinue)) {
                Write-Verbose 'winget was not found; the .NET Uninstall Tool cannot be installed automatically.'
                return
            }

            if (-not $PSCmdlet.ShouldProcess('Microsoft.DotNet.UninstallTool', 'Install the .NET Uninstall Tool with winget')) {
                return
            }

            Write-Verbose 'Installing the .NET Uninstall Tool with winget.'
            & winget install --id Microsoft.DotNet.UninstallTool --source winget --accept-package-agreements --accept-source-agreements 2>&1 |
                ForEach-Object { Write-Verbose "$_" }

            if ($LASTEXITCODE -ne 0) {
                Write-Verbose "winget exited with code $LASTEXITCODE."
                return
            }

            Get-UninstallToolPath
        }

        function Invoke-UninstallTool {
            param(
                [string]$ToolPath,
                [string]$Target
            )

            if ($WhatIfPreference) {
                $arguments = @('dry-run', '--all-lower-patches', $Target)
            }
            elseif ($PSCmdlet.ShouldProcess("$Target superseded versions", 'Remove with the .NET Uninstall Tool')) {
                $arguments = @('remove', '--all-lower-patches', $Target, '--yes')
            }
            else {
                return
            }

            Write-Verbose "Running: `"$ToolPath`" $($arguments -join ' ')"
            & $ToolPath @arguments 2>&1 | ForEach-Object { Write-Verbose "$_" }

            if ($LASTEXITCODE -ne 0) {
                throw "'$ToolPath $($arguments -join ' ')' exited with code $LASTEXITCODE."
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
        # The tool's filter options are exclusive, so it can only express the default request.
        if ($resolvedPaths.Count -eq 0 -and -not $Band -and $KeepVersions -eq 1) {
            $toolPath = Get-UninstallToolPath
            if (-not $toolPath) {
                $toolPath = Install-UninstallTool
            }

            if ($toolPath) {
                $targets = @('--runtime', '--aspnet-runtime', '--windows-desktop-runtime')
                if ($IncludeSdk) { $targets += '--sdk' }

                $before = @(Get-SharedFrameworkVersion)

                try {
                    foreach ($target in $targets) {
                        Invoke-UninstallTool -ToolPath $toolPath -Target $target
                    }

                    if (-not $WhatIfPreference) {
                        $remaining = @(Get-SharedFrameworkVersion).FullName
                        $before | Where-Object { $_.FullName -notin $remaining }
                    }

                    return
                }
                catch {
                    Write-Warning "The .NET Uninstall Tool did not complete: $($_.Exception.Message) Falling back to removing the directories."
                }
            }
            else {
                Write-Verbose 'The .NET Uninstall Tool is not available; falling back to removing the directories.'
            }
        }

        if ($IncludeSdk) {
            Write-Warning 'Only the .NET Uninstall Tool can remove SDKs; the fallback removal skips them.'
        }

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
