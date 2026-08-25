function Add-SvnUnversioned {
    <#
    .SYNOPSIS
        Adds unversioned files (status "?") to an SVN working copy with exclusion support.

    .DESCRIPTION
        Runs 'svn status', identifies unversioned files, and adds them to SVN.
        Supports -WhatIf to preview additions.
        Supports -Exclude to skip specific files or patterns.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param (
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName, Position = 0)]
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

                    $unversionedItems = svn st | Where-Object { $_.StartsWith("?") }

                    foreach ($line in $unversionedItems) {
                        $fileName = $line.TrimStart("?").Trim()

                        $shouldSkip = $false
                        if ($Exclude) {
                            foreach ($pattern in $Exclude) {
                                if ($fileName -like $pattern) {
                                    $shouldSkip = $true
                                    Write-Verbose "Skipping excluded item: $fileName (Matches '$pattern')"
                                    break
                                }
                            }
                        }

                        if ($shouldSkip) { continue }

                        $fullFilePath = Join-Path -Path $PWD -ChildPath $fileName

                        if ($PSCmdlet.ShouldProcess($fullFilePath, "Add Unversioned Item")) {
                            svn add $fileName
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