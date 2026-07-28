# build.ps1 - Automate local building and testing

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param (
    [switch]$Test,
    [switch]$Analyze,
    [switch]$Import,
    [switch]$Publish,

    [ValidateSet('Major', 'Minor', 'Patch')]
    [string]$BumpVersion,

    [switch]$Tag
)

$modulePath = "$PSScriptRoot\src\gcpstools"
$manifestPath = "$modulePath\gcpstools.psd1"

if ($BumpVersion) {
    Write-Host "Bumping $BumpVersion version..." -ForegroundColor Cyan

    $manifest = Import-PowerShellDataFile $manifestPath
    $current = [version]$manifest.ModuleVersion
    $new = switch ($BumpVersion) {
        'Major' { [version]::new($current.Major + 1, 0, 0) }
        'Minor' { [version]::new($current.Major, $current.Minor + 1, 0) }
        'Patch' { [version]::new($current.Major, $current.Minor, $current.Build + 1) }
    }

    # Targeted replace so manifest comments and formatting are preserved
    # (Update-ModuleManifest would rewrite the whole file).
    $content = Get-Content -Raw -LiteralPath $manifestPath
    $updated = [regex]::Replace(
        $content,
        "(?m)^(\s*ModuleVersion\s*=\s*')[^']*(')",
        "`${1}$new`${2}")
    if ($updated -eq $content) {
        throw "Could not find ModuleVersion in $manifestPath."
    }
    Set-Content -LiteralPath $manifestPath -Value $updated -NoNewline -Encoding UTF8
    Write-Host "ModuleVersion: $current -> $new" -ForegroundColor Green

    # Roll the CHANGELOG [Unreleased] section into a dated release heading.
    $changelogPath = "$PSScriptRoot\CHANGELOG.md"
    if (Test-Path $changelogPath) {
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $changelog = Get-Content -Raw -LiteralPath $changelogPath
        $rolled = [regex]::Replace(
            $changelog,
            "(?m)^## \[Unreleased\][^\S\r\n]*(?=\r?\n|$)",
            "## [Unreleased]`r`n`r`n## [$new] - $today")
        if ($rolled -ne $changelog) {
            Set-Content -LiteralPath $changelogPath -Value $rolled -NoNewline -Encoding UTF8
            Write-Host "CHANGELOG: added heading [$new] - $today" -ForegroundColor Green
        } else {
            Write-Warning "No '## [Unreleased]' heading found in CHANGELOG.md; skipped."
        }
    }

    Write-Host "Next steps: review changes, commit, then run '.\build.ps1 -Tag' (or 'git tag v$new' and push) to publish." -ForegroundColor Yellow
}

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

if ($Tag) {
    Write-Host "Preparing git release tag..." -ForegroundColor Cyan

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git was not found on PATH."
    }

    if ((git rev-parse --is-inside-work-tree 2>$null) -ne 'true') {
        throw "Not inside a git working tree."
    }

    # The tag points at HEAD, so refuse a dirty tree: the version bump and
    # CHANGELOG update must be committed before tagging.
    if (git status --porcelain) {
        throw "Working tree has uncommitted changes. Commit the version bump before tagging."
    }

    $version = (Import-PowerShellDataFile $manifestPath).ModuleVersion
    $tagName = "v$version"

    # Refuse to clobber an existing tag (locally or on the remote).
    git rev-parse -q --verify "refs/tags/$tagName" *> $null
    if ($LASTEXITCODE -eq 0) {
        throw "Tag '$tagName' already exists locally. Bump the version or delete the tag first."
    }

    $action = "create annotated tag '$tagName' and push it to origin (this triggers the Gallery publish workflow)"
    if ($PSCmdlet.ShouldProcess('origin', $action)) {
        git tag -a $tagName -m $tagName
        if ($LASTEXITCODE -ne 0) { throw "git tag failed." }

        git push origin $tagName
        if ($LASTEXITCODE -ne 0) {
            # Roll back the local tag so a retry starts clean.
            git tag -d $tagName | Out-Null
            throw "git push failed; local tag '$tagName' was removed."
        }
        Write-Host "Pushed tag '$tagName'. The publish workflow will run on GitHub." -ForegroundColor Green
    } else {
        Write-Host "Tagging cancelled." -ForegroundColor Yellow
    }
}
