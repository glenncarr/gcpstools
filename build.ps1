# build.ps1 - Automate local building and testing

[CmdletBinding()]
param (
    [switch]$Test,
    [switch]$Analyze,
    [switch]$Import,
    [switch]$Publish
)

$modulePath = "$PSScriptRoot\src\gcpstools"

if ($Analyze) {
    Write-Host "Running PSScriptAnalyzer..." -ForegroundColor Cyan
    if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
        Install-Module -Name PSScriptAnalyzer -Force -Scope CurrentUser
    }
    Import-Module PSScriptAnalyzer
    $findings = Invoke-ScriptAnalyzer -Path $modulePath -Recurse
    if ($findings) {
        $findings | Format-Table Severity, RuleName, ScriptName, Line, Message -AutoSize -Wrap
        if ($findings | Where-Object Severity -eq 'Error') {
            throw "PSScriptAnalyzer reported errors."
        }
    } else {
        Write-Host "PSScriptAnalyzer: no findings." -ForegroundColor Green
    }
}

if ($Test) {
    Write-Host "Running Pester tests..." -ForegroundColor Cyan
    $pester = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pester -or $pester.Version -lt [version]'5.0.0') {
        Install-Module -Name Pester -MinimumVersion 5.0.0 -Force -SkipPublisherCheck -Scope CurrentUser
    }
    Import-Module Pester -MinimumVersion 5.0.0 -Force
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
