# build.ps1 - Automate local building and testing

[CmdletBinding()]
param (
    [switch]$Test,
    [switch]$Import,
    [switch]$Publish
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

if ($Publish) {
    Write-Host "Copying README into module folder for the Gallery..." -ForegroundColor Cyan
    Copy-Item "$PSScriptRoot\README.md" "$modulePath\README.md" -Force

    if (-not $env:PSGALLERY_KEY) {
        throw "PSGALLERY_KEY environment variable is not set."
    }
    Write-Host "Publishing module to the PowerShell Gallery..." -ForegroundColor Cyan
    Publish-Module -Path $modulePath -NuGetApiKey $env:PSGALLERY_KEY
}
