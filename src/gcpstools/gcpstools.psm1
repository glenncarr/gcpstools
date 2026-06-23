# Module root script for gcpstools
# Dot-source all private and public functions

$Private = Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1" -ErrorAction SilentlyContinue
$Public = Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1" -ErrorAction SilentlyContinue

foreach ($file in @($Private + $Public)) {
    try {
        . $file.FullName
    } catch {
        Write-Error "Failed to import $($file.FullName): $_"
    }
}

# Export only public functions
Export-ModuleMember -Function $Public.BaseName
