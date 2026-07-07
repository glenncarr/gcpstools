function Remove-SvnUnversioned {
    <#
    .SYNOPSIS
        Removes unversioned files (status "?") from an SVN working copy with exclusion support.

    .DESCRIPTION
        Runs 'svn status', identifies unversioned files, and deletes them.
        Supports -WhatIf to preview deletions.
        Supports -Exclude to skip specific files or patterns.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param (
        [Parameter(Mandatory = $false,
                   ValueFromPipeline = $true,
                   ValueFromPipelineByPropertyName = $true,
                   Position = 0)]
        [Alias("FullName")]
        [string[]]$Path = ".",

        [Parameter(Mandatory = $false)]
        [string[]]$Exclude
    )

    process {
        foreach ($item in $Path) {
            if (Test-Path -Path $item) {
                $targetPath = Convert-Path -Path $item
                Push-Location -Path $targetPath

                try {
                    Write-Verbose "Scanning: $targetPath"

                    # Get unversioned items
                    $unversionedItems = svn st | Where-Object { $_.StartsWith("?") }

                    foreach ($line in $unversionedItems) {
                        # Clean the filename
                        $fileName = $line.TrimStart("?").Trim()

                        # --- EXCLUSION LOGIC ---
                        $shouldSkip = $false
                        if ($Exclude) {
                            foreach ($pattern in $Exclude) {
                                # Use -Like for wildcard support (e.g. *.log)
                                if ($fileName -like $pattern) {
                                    $shouldSkip = $true
                                    Write-Verbose "Skipping excluded item: $fileName (Matches '$pattern')"
                                    break
                                }
                            }
                        }

                        if ($shouldSkip) { continue }
                        # -----------------------

                        $fullFilePath = Join-Path -Path $PWD -ChildPath $fileName

                        # The -WhatIf check
                        if ($PSCmdlet.ShouldProcess($fullFilePath, "Delete Unversioned Item")) {
                            Remove-Item -LiteralPath $fileName -Force -Recurse -ErrorAction SilentlyContinue
                        }
                    }
                }
                catch {
                    Write-Error "Error processing $targetPath : $_"
                }
                finally {
                    Pop-Location
                }
            }
            else {
                Write-Warning "Path not found: $item"
            }
        }
    }
}
