<#
.SYNOPSIS
    Lists files committed to Subversion within a recent time window as full
    local working-copy paths.

.DESCRIPTION
    Runs 'svn log' (verbose, XML) over the requested time range and maps the
    repository-relative paths of the changed items back onto the current working
    copy. Only files that were Added, Modified, or Replaced and that still exist
    on disk are returned, so the output can be piped straight into
    Find-InvalidUtf8.ps1.

.PARAMETER Hours
    How far back to look, in hours. Defaults to 24.

.PARAMETER Path
    Working-copy path to inspect. Defaults to the current directory.

.PARAMETER Action
    SVN change actions to include. Defaults to A (added), M (modified),
    R (replaced). 'D' (deleted) is intentionally excluded since those files no
    longer exist locally.

.EXAMPLE
    .\Get-RecentSvnFiles.ps1

.EXAMPLE
    .\Get-RecentSvnFiles.ps1 -Hours 72 | .\Find-InvalidUtf8.ps1

.EXAMPLE
    .\Get-RecentSvnFiles.ps1 -Path .\Public -Hours 8
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 100000)]
    [int]$Hours = 24,

    [string]$Path = '.',

    [ValidateSet('A', 'M', 'R', 'D')]
    [string[]]$Action = @('A', 'M', 'R')
)

if (-not (Get-Command svn -ErrorAction SilentlyContinue)) {
    throw "The 'svn' command-line client was not found on PATH."
}

$wcPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath

# Gather working-copy layout so repo paths can be mapped to local paths.
[xml]$infoXml = svn info --xml -- $wcPath 2>$null
if (-not $infoXml.info.entry) {
    throw "'$wcPath' does not appear to be an SVN working copy."
}
$entry     = $infoXml.info.entry
$repoRoot  = [Uri]::UnescapeDataString($entry.repository.root)
$wcUrl     = [Uri]::UnescapeDataString($entry.url)

# Repository-relative prefix of the queried path, e.g. "/trunk/Source/Core".
# The log below is scoped to $wcPath, so every changed path lives under this
# prefix and maps directly onto $wcPath.
$wcRepoRel = $wcUrl.Substring($repoRoot.Length)

# SVN accepts an ISO date/time inside {} for a revision boundary.
$since    = (Get-Date).AddHours(-$Hours).ToString('yyyy-MM-ddTHH:mm:ss')
$revRange = "{{{0}}}:HEAD" -f $since

[xml]$logXml = svn log -v --xml -r $revRange -- $wcPath 2>$null
if (-not $logXml.log.logentry) {
    Write-Verbose "No commits found in the last $Hours hour(s)."
    return
}

$results = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

foreach ($logentry in $logXml.log.logentry) {
    foreach ($p in $logentry.paths.path) {
        if ($Action -notcontains $p.action) { continue }
        if ($p.kind -and $p.kind -eq 'dir') { continue }

        $repoPath = $p.'#text'
        if (-not $repoPath.StartsWith($wcRepoRel, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $rel   = $repoPath.Substring($wcRepoRel.Length).TrimStart('/')
        $local = Join-Path $wcPath ($rel -replace '/', '\')

        if (Test-Path -LiteralPath $local -PathType Leaf) {
            [void]$results.Add((Resolve-Path -LiteralPath $local).ProviderPath)
        }
    }
}

$results | Sort-Object
