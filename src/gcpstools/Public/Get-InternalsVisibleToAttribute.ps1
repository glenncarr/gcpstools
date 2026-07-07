function Get-InternalsVisibleToAttribute {
<#
.SYNOPSIS
    Retrieves InternalsVisibleTo attributes from a .NET assembly.

.DESCRIPTION
    Loads the specified .NET assembly and inspects its
    System.Runtime.CompilerServices.InternalsVisibleToAttribute custom attributes,
    returning those whose friend assembly name matches the supplied pattern.

.PARAMETER Path
    The file system path to the .NET assembly (.dll or .exe) to inspect.

.PARAMETER FriendAssemblyNamePattern
    A wildcard pattern used to filter the InternalsVisibleTo friend assembly names
    (matched with the -like operator).

.EXAMPLE
    Get-InternalsVisibleToAttribute.ps1 -Path .\MyLibrary.dll -FriendAssemblyNamePattern '*Tests*'

    Returns the InternalsVisibleTo attributes of MyLibrary.dll whose friend assembly
    name contains "Tests".
#>
[CmdletBinding()]
param( [Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$FriendAssemblyNamePattern )

try {
    $assembly = [System.Reflection.Assembly]::LoadFrom((Resolve-Path $Path))
    $attributes = $assembly.GetCustomAttributes([System.Runtime.CompilerServices.InternalsVisibleToAttribute], $false)
    if ($attributes) {
        $attributes | Where-Object { $_.AssemblyName -like $FriendAssemblyNamePattern }
    }
}
catch {
    Write-Error "Failed to load or inspect the assembly '$Path'. Error: $($_.Exception.Message)"
}
}