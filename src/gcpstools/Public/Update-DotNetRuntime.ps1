function Update-DotNetRuntime {
    <#
    .SYNOPSIS
        Updates installed .NET shared frameworks to the latest patch in each band.

    .DESCRIPTION
        Discovers the installed Microsoft.NETCore.App, Microsoft.AspNetCore.App,
        and Microsoft.WindowsDesktop.App shared frameworks. For every installed
        major.minor band, retrieves Microsoft's release metadata, downloads the
        matching Windows runtime installer, verifies its SHA-512 hash, and installs
        a newer patch when one is available.

        End-of-life channels are skipped unless -IncludeEol is specified. Use
        -CleanupStale to remove superseded patches after a band is current.

    .PARAMETER Band
        Limits processing to the specified major.minor bands, such as '8.0'.
        By default, every installed band is processed.

    .PARAMETER IncludeEol
        Includes end-of-life .NET channels. These channels no longer receive
        security updates.

    .PARAMETER CleanupStale
        Removes superseded patch versions from successfully processed bands.

    .PARAMETER KeepVersions
        The number of newest patch versions to retain when -CleanupStale is used.

    .PARAMETER DownloadPath
        Directory used for temporary runtime installers.

    .EXAMPLE
        Update-DotNetRuntime -WhatIf

        Shows the runtime updates available for every installed supported band.

    .EXAMPLE
        Update-DotNetRuntime -Band '8.0', '10.0' -CleanupStale -KeepVersions 2 -Confirm:$false

        Updates the specified bands and retains their two newest patch versions.

    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [ValidatePattern('^\d+\.\d+$')]
        [string[]]$Band,

        [switch]$IncludeEol,

        [switch]$CleanupStale,

        [ValidateRange(1, 1000)]
        [int]$KeepVersions = 1,

        [ValidateNotNullOrEmpty()]
        [string]$DownloadPath = $env:TEMP
    )

    function Format-UpdateResult {
        param(
            [string]$Framework,
            [string]$Architecture,
            [string]$Band,
            [string]$CurrentVersion,
            [string]$TargetVersion,
            [string]$Status,
            [Nullable[int]]$ExitCode,
            [bool]$RebootRequired,
            [string]$ErrorMessage
        )

        [PSCustomObject][ordered]@{
            Framework      = $Framework
            Architecture   = $Architecture
            Band           = $Band
            CurrentVersion = $CurrentVersion
            TargetVersion  = $TargetVersion
            Status         = $Status
            ExitCode       = $ExitCode
            RebootRequired = $RebootRequired
            Error          = $ErrorMessage
        }
    }

    function Get-VersionInfo {
        param([string]$Value)

        $match = [regex]::Match($Value, '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?<suffix>-.+)?$')
        if (-not $match.Success) {
            return $null
        }

        [PSCustomObject]@{
            Display   = $Value
            SortValue = [version]('{0}.{1}.{2}' -f $match.Groups['major'].Value, $match.Groups['minor'].Value, $match.Groups['patch'].Value)
            IsStable  = -not $match.Groups['suffix'].Success
            Band      = '{0}.{1}' -f $match.Groups['major'].Value, $match.Groups['minor'].Value
        }
    }

    function Get-NativeArchitecture {
        $architecture = @($env:PROCESSOR_ARCHITEW6432, $env:PROCESSOR_ARCHITECTURE) |
            Where-Object { $_ } |
            Select-Object -First 1

        if ($architecture -match 'ARM64') {
            return 'arm64'
        }

        if ($architecture -match '64') {
            return 'x64'
        }

        return 'x86'
    }

    function Get-InstalledFramework {
        $nativeArchitecture = Get-NativeArchitecture
        $programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
        $roots = @(
            [PSCustomObject]@{ Path = $programFiles; Architecture = $nativeArchitecture },
            [PSCustomObject]@{ Path = ${env:ProgramFiles(x86)}; Architecture = 'x86' }
        )
        $frameworks = @{
            'Microsoft.NETCore.App'       = 'runtime'
            'Microsoft.AspNetCore.App'     = 'aspnetcore-runtime'
            'Microsoft.WindowsDesktop.App' = 'windowsdesktop'
        }
        $seenRoots = @{}

        foreach ($root in $roots) {
            if (-not $root.Path) {
                continue
            }

            $sharedPath = Join-Path $root.Path 'dotnet\shared'
            if ($seenRoots.ContainsKey($sharedPath) -or -not (Test-Path -LiteralPath $sharedPath -PathType Container)) {
                continue
            }
            $seenRoots[$sharedPath] = $true

            foreach ($framework in $frameworks.GetEnumerator()) {
                $frameworkPath = Join-Path $sharedPath $framework.Key
                if (-not (Test-Path -LiteralPath $frameworkPath -PathType Container)) {
                    continue
                }

                foreach ($directory in Get-ChildItem -LiteralPath $frameworkPath -Directory) {
                    $version = Get-VersionInfo $directory.Name
                    if ($null -eq $version) {
                        continue
                    }

                    [PSCustomObject]@{
                        Framework     = $framework.Key
                        Component     = $framework.Value
                        Architecture  = $root.Architecture
                        FrameworkPath = $frameworkPath
                        Version       = $version
                    }
                }
            }
        }
    }

    $installed = @(Get-InstalledFramework)
    if ($installed.Count -eq 0) {
        Write-Warning 'No installed .NET shared frameworks were found.'
        return
    }

    try {
        $releaseIndex = Invoke-RestMethod -Uri 'https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/releases-index.json' -ErrorAction Stop
    }
    catch {
        throw "Failed to retrieve .NET release metadata: $($_.Exception.Message)"
    }

    $releaseCache = @{}
    $cleanupTargets = [System.Collections.Generic.List[object]]::new()
    $groups = $installed | Group-Object Framework, Component, Architecture, { $_.Version.Band }

    foreach ($group in $groups) {
        $sample = $group.Group[0]
        $installedBand = $sample.Version.Band
        if ($Band -and $installedBand -notin $Band) {
            continue
        }

        $current = $group.Group |
            Sort-Object -Property @{ Expression = { $_.Version.SortValue }; Descending = $true }, @{ Expression = { $_.Version.IsStable }; Descending = $true } |
            Select-Object -First 1
        $currentVersion = $current.Version.Display
        $channel = @($releaseIndex.'releases-index' | Where-Object { $_.'channel-version' -eq $installedBand }) | Select-Object -First 1

        if ($null -eq $channel) {
            Format-UpdateResult -Framework $sample.Framework -Architecture $sample.Architecture -Band $installedBand -CurrentVersion $currentVersion -TargetVersion $null -Status 'MetadataUnavailable' -ExitCode $null -RebootRequired $false -ErrorMessage "No release metadata was found for .NET $installedBand."
            continue
        }

        if (-not $IncludeEol -and $channel.'support-phase' -eq 'eol') {
            Format-UpdateResult -Framework $sample.Framework -Architecture $sample.Architecture -Band $installedBand -CurrentVersion $currentVersion -TargetVersion $channel.'latest-release' -Status 'SkippedEol' -ExitCode $null -RebootRequired $false -ErrorMessage $null
            continue
        }

        if (-not $releaseCache.ContainsKey($installedBand)) {
            try {
                $releaseMetadata = Invoke-RestMethod -Uri $channel.'releases.json' -ErrorAction Stop
                $releaseCache[$installedBand] = @($releaseMetadata.releases | Where-Object { $_.'release-version' -eq $channel.'latest-release' }) | Select-Object -First 1
            }
            catch {
                $releaseCache[$installedBand] = $null
                Write-Verbose "Could not retrieve release details for .NET ${installedBand}: $($_.Exception.Message)"
            }
        }

        $release = $releaseCache[$installedBand]
        if ($null -eq $release -or $null -eq $release.$($sample.Component)) {
            Format-UpdateResult -Framework $sample.Framework -Architecture $sample.Architecture -Band $installedBand -CurrentVersion $currentVersion -TargetVersion $channel.'latest-release' -Status 'MetadataUnavailable' -ExitCode $null -RebootRequired $false -ErrorMessage "No installer metadata was found for $($sample.Framework) $installedBand."
            continue
        }

        $component = $release.$($sample.Component)
        $target = Get-VersionInfo $component.version
        if ($null -eq $target) {
            Format-UpdateResult -Framework $sample.Framework -Architecture $sample.Architecture -Band $installedBand -CurrentVersion $currentVersion -TargetVersion $component.version -Status 'MetadataUnavailable' -ExitCode $null -RebootRequired $false -ErrorMessage "The target version '$($component.version)' is not a supported runtime version."
            continue
        }

        $requiresUpdate = $target.SortValue -gt $current.Version.SortValue -or
            ($target.SortValue -eq $current.Version.SortValue -and $target.IsStable -and -not $current.Version.IsStable)
        if (-not $requiresUpdate) {
            Format-UpdateResult -Framework $sample.Framework -Architecture $sample.Architecture -Band $installedBand -CurrentVersion $currentVersion -TargetVersion $target.Display -Status 'Current' -ExitCode $null -RebootRequired $false -ErrorMessage $null
            if ($CleanupStale) {
                $cleanupTargets.Add($sample)
            }
            continue
        }

        $rid = 'win-{0}' -f $sample.Architecture
        $installer = @($component.files | Where-Object { $_.rid -eq $rid -and $_.name -match '\.exe$' }) | Select-Object -First 1
        if ($null -eq $installer) {
            Format-UpdateResult -Framework $sample.Framework -Architecture $sample.Architecture -Band $installedBand -CurrentVersion $currentVersion -TargetVersion $target.Display -Status 'InstallerUnavailable' -ExitCode $null -RebootRequired $false -ErrorMessage "No Windows installer was found for $rid."
            continue
        }

        $action = "Download and install $($sample.Framework) $($target.Display) ($($sample.Architecture))"
        if (-not $PSCmdlet.ShouldProcess($sample.FrameworkPath, $action)) {
            Format-UpdateResult -Framework $sample.Framework -Architecture $sample.Architecture -Band $installedBand -CurrentVersion $currentVersion -TargetVersion $target.Display -Status 'WhatIf' -ExitCode $null -RebootRequired $false -ErrorMessage $null
            continue
        }

        $installerPath = Join-Path $DownloadPath $installer.name
        try {
            if (-not (Test-Path -LiteralPath $DownloadPath -PathType Container)) {
                New-Item -ItemType Directory -Path $DownloadPath -Force -ErrorAction Stop | Out-Null
            }

            Invoke-WebRequest -Uri $installer.url -OutFile $installerPath -UseBasicParsing -ErrorAction Stop
            $actualHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA512 -ErrorAction Stop).Hash
            if ($actualHash -ne $installer.hash) {
                throw 'The SHA-512 hash did not match the value supplied by Microsoft.'
            }

            $process = Start-Process -FilePath $installerPath -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru -ErrorAction Stop
            if ($process.ExitCode -notin 0, 3010) {
                throw "The installer exited with code $($process.ExitCode)."
            }

            Format-UpdateResult -Framework $sample.Framework -Architecture $sample.Architecture -Band $installedBand -CurrentVersion $currentVersion -TargetVersion $target.Display -Status 'Updated' -ExitCode $process.ExitCode -RebootRequired ($process.ExitCode -eq 3010) -ErrorMessage $null
            if ($CleanupStale) {
                $cleanupTargets.Add($sample)
            }
        }
        catch {
            Format-UpdateResult -Framework $sample.Framework -Architecture $sample.Architecture -Band $installedBand -CurrentVersion $currentVersion -TargetVersion $target.Display -Status 'Failed' -ExitCode $null -RebootRequired $false -ErrorMessage $_.Exception.Message
        }
        finally {
            if (Test-Path -LiteralPath $installerPath -PathType Leaf) {
                Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($CleanupStale) {
        foreach ($target in ($cleanupTargets | Select-Object FrameworkPath, Version -Unique)) {
            try {
                Remove-StaleDotNetRuntime -Path $target.FrameworkPath -Band $target.Version.Band -KeepVersions $KeepVersions -Confirm:$false | Out-Null
            }
            catch {
                Write-Warning "Failed to remove stale .NET runtime versions from $($target.FrameworkPath): $($_.Exception.Message)"
            }
        }
    }
}