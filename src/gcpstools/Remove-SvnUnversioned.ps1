function Remove-SvnUnversioned {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory = $false)]
        [string]$Path = (Get-Location)
    )

    Push-Location $Path
    try {
        svn status --no-ignore |
            Where-Object { $_ -match '^[\?I]' } |
            ForEach-Object {
                $item = $_.Substring(8)
                if ($PSCmdlet.ShouldProcess($item, 'Remove-Item')) {
                    Remove-Item -Path $item -Recurse -Force `
                        -Verbose:($VerbosePreference -eq 'Continue') `
                        -WhatIf:($WhatIfPreference)
                }
            }
    }
    finally {
        Pop-Location
    }
}