function Set-HelperData {
    <#
    .SYNOPSIS
        Internal helper function.
    .DESCRIPTION
        A private helper function not exported by the module.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Data
    )

    # Internal implementation
    Write-Verbose "Setting helper data: $Data"
}
