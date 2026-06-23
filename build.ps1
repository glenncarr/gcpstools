# build.ps1 - Automate local building and testing

[CmdletBinding()]
param (
    [switch]$Test,
    [switch]$Import
)

$modulePath = "$PSScriptRoot\src\gcpstools"

if ($Test) {
    Write-Host "Running Pester tests..." -ForegroundColor Cyan
    if (-not (Get-Module -ListAvailable -Name Pester)) {
        Install-Module -Name Pester -Force -SkipPublisherCheck
    }
    Invoke-Pester -Path "$PSScriptRoot\tests" -Output Detailed
}

if ($Import) {
    Write-Host "Importing module..." -ForegroundColor Cyan
    Import-Module $modulePath -Force -Verbose
}
