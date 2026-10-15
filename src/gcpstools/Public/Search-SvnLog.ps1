function Search-SvnLog {
<#
.SYNOPSIS
    Searches SVN log history for one or more patterns in commit messages.

.DESCRIPTION
    Queries svn log through repository HEAD without updating the working copy,
    parses the structured XML output, and displays full details for every commit
    whose message matches any of the given patterns. An informational message is
    shown when the working copy is behind the repository.

.PARAMETER Pattern
    One or more patterns to match against SVN commit messages.
    By default these are regular expressions (case-insensitive).
    Use -SimpleMatch to treat them as literal strings.

.PARAMETER Path
    Working-copy path to run svn log against. Defaults to the current directory.

.PARAMETER Limit
    Maximum number of log entries to retrieve from SVN. 0 means no limit (all history). Default: 5.

.PARAMETER CaseSensitive
    When specified, the search is case-sensitive.

.PARAMETER SimpleMatch
    When specified, treats Pattern values as literal strings instead of regular expressions.

.PARAMETER IncludeFile
    A regex pattern to match against the changed file paths in each commit.
    Only commits containing at least one changed path matching this pattern are shown.
    Respects -SimpleMatch and -CaseSensitive.

.PARAMETER Descending
    When specified, displays results from newest to oldest.
    Default order is oldest to newest (newest last).

.PARAMETER First
    Display only the first N matching revisions (oldest).

.PARAMETER Last
    Display only the last N matching revisions (newest).

.PARAMETER ShowPaths
    Includes changed paths in the output. This is the default; retained for compatibility.

.PARAMETER HidePaths
    Omits changed paths and their labels from the output. Takes precedence over -ShowPaths.

.PARAMETER Clipboard
    Copies the plain-text rendering of the results to the clipboard while still
    displaying the colored results on screen.

.EXAMPLE
    Search-SvnLog.ps1 -Pattern "fix null reference"

.EXAMPLE
    Search-SvnLog.ps1 -Pattern "bug fix" -IncludeFile "SettingsService\.cs"

.EXAMPLE
    Search-SvnLog.ps1 C:\MyRepo "deploy(ment|ed)" -Limit 1000

.EXAMPLE
    Search-SvnLog.ps1 -Pattern "^JIRA-\d+" -CaseSensitive

.EXAMPLE
    Search-SvnLog.ps1 -Pattern "bug 1234","bug 5678" -SimpleMatch

.EXAMPLE
    Search-SvnLog.ps1 -Pattern "deploy" -Clipboard
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Path = (Get-Location).Path,

    [Parameter(Position = 1)]
    [string[]] $Pattern,

    [Parameter()]
    [ValidateRange(0, [int]::MaxValue)]
    [int] $Limit = 5,

    [Parameter()]
    [switch] $CaseSensitive,

    [Parameter()]
    [switch] $SimpleMatch,

    [Parameter()]
    [string] $IncludeFile,

    [Parameter()]
    [switch] $Descending,

    [Parameter()]
    [switch] $ShowPaths = $true,

    [Parameter()]
    [switch] $HidePaths,

    [Parameter()]
    [ValidateRange(1, [int]::MaxValue)]
    [int] $First,

    [Parameter()]
    [ValidateRange(1, [int]::MaxValue)]
    [int] $Last,

    [Parameter()]
    [switch] $Clipboard,

    [Parameter()]
    [ValidateRange(0, [int]::MaxValue)]
    [int] $PageSize = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$showPaths = $ShowPaths -and -not $HidePaths

# --- Color palette for patterns ------------------------------------------------
$colorPalette = @(
    @{ Fg = 'White';  Bg = 'DarkBlue'    }
    @{ Fg = 'White';  Bg = 'DarkGreen'   }
    @{ Fg = 'White';  Bg = 'DarkMagenta' }
    @{ Fg = 'Black';  Bg = 'DarkYellow'  }
    @{ Fg = 'White';  Bg = 'DarkRed'     }
    @{ Fg = 'White';  Bg = 'DarkCyan'    }
    @{ Fg = 'Black';  Bg = 'Gray'        }
)

# --- Build regex list for each pattern -----------------------------------------
$regexOptions = if ($CaseSensitive) {
    [System.Text.RegularExpressions.RegexOptions]::None
} else {
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
}

$regexList = [System.Collections.Generic.List[System.Text.RegularExpressions.Regex]]::new()
if ($Pattern) {
    foreach ($pat in $Pattern) {
        $escaped = if ($SimpleMatch) { [System.Text.RegularExpressions.Regex]::Escape($pat) } else { $pat }
        try {
            $regexList.Add([System.Text.RegularExpressions.Regex]::new($escaped, $regexOptions))
        } catch [System.ArgumentException] {
            Write-Error "Invalid regular expression '$pat': $($_.Exception.Message)"
            return
        }
    }
}

# --- Check whether the working copy is behind the repository ------------------
$statusArgs = @('status', '--show-updates', '--xml', $Path)
$statusOutput = svn @statusArgs 2>&1
$workingCopyIsOutOfDate = $false
if ($LASTEXITCODE -eq 0) {
    [xml]$statusXml = $statusOutput | Out-String
    $workingCopyIsOutOfDate = $statusXml.SelectNodes('/status/target/entry/repos-status').Count -gt 0
}

if ($workingCopyIsOutOfDate) {
    $message = "Working copy '$Path' is out of date. The log is fetched through repository HEAD; the working copy was not updated."
    Write-Warning $message
}

# --- Build svn arguments -------------------------------------------------------
$svnArgs = @('log', '--xml', '--verbose', '--revision', 'HEAD:1', $Path)
if ($Limit -gt 0) {
    $svnArgs += '--limit', $Limit
}

# --- Retrieve and parse log ----------------------------------------------------
$rawXml = svn @svnArgs 2>&1

if ($LASTEXITCODE -ne 0) {
    $errorText = $rawXml | Where-Object { $_ -is [string] } | Out-String
    Write-Error "svn log failed (exit $LASTEXITCODE):`n$errorText"
    return
}

[xml]$logXml = $rawXml | Out-String

$entries = @($logXml.SelectNodes('/log/logentry'))
if (-not $entries) {
    Write-Host "No log entries found." -ForegroundColor Yellow
    return
}

# --- Build file filter regex if specified --------------------------------------
$fileRegex = $null
if ($IncludeFile) {
    $escapedFile = if ($SimpleMatch) { [System.Text.RegularExpressions.Regex]::Escape($IncludeFile) } else { $IncludeFile }
    try {
        $fileRegex = [System.Text.RegularExpressions.Regex]::new($escapedFile, $regexOptions)
    } catch [System.ArgumentException] {
        Write-Error "Invalid IncludeFile pattern '$IncludeFile': $($_.Exception.Message)"
        return
    }
}

# --- Filter and group matching entries by first matching pattern ---------------
$results = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($entry in $entries) {
    if ($regexList.Count -gt 0 -and -not $entry.msg) { continue }

    # Apply file filter if specified
    if ($fileRegex) {
        $paths = if ($entry.paths) { $entry.paths.path } else { $null }
        if (-not $paths) { continue }
        $fileMatch = $false
        foreach ($p in $paths) {
            if ($fileRegex.IsMatch($p.'#text')) {
                $fileMatch = $true
                break
            }
        }
        if (-not $fileMatch) { continue }
    }

    if ($regexList.Count -gt 0) {
        for ($i = 0; $i -lt $regexList.Count; $i++) {
            if ($regexList[$i].IsMatch($entry.msg)) {
                $results.Add([pscustomobject]@{ Entry = $entry; PatternIndex = $i })
                break  # first matching pattern wins the color
            }
        }
    } else {
        # No message pattern — include all entries that passed the file filter
        $results.Add([pscustomobject]@{ Entry = $entry; PatternIndex = 0 })
    }
}

if ($results.Count -eq 0) {
    Write-Host "No commits found matching the specified criteria." -ForegroundColor Yellow
    return
}

# --- Sort results (default: oldest first) --------------------------------------
if (-not $Descending) {
    $results.Reverse()
}

# --- Apply -First / -Last slicing ----------------------------------------------
if ($First -and $Last) {
    Write-Error "Cannot specify both -First and -Last."
    return
}
if ($First) {
    if ($First -lt $results.Count) {
        $results = [System.Collections.Generic.List[pscustomobject]]($results.GetRange(0, $First))
    }
}
if ($Last) {
    if ($Last -lt $results.Count) {
        $results = [System.Collections.Generic.List[pscustomobject]]($results.GetRange($results.Count - $Last, $Last))
    }
}

# --- Display results -----------------------------------------------------------
$displayCount = 0

# Build the plain-text lines for clipboard output.
function Format-PlainSvnEntry {
    param($Entry, [int]$PatternIndex)

    $header = "r$($Entry.revision) | $(if ($Entry.author) { $Entry.author } else { '(none)' })"
    if ($Pattern -and $Pattern.Count -gt 1) {
        $header += " | [$($PatternIndex + 1)] $($Pattern[$PatternIndex])"
    }
    if ($Entry.date) {
        $d = [datetime]::Parse($Entry.date, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
        $header += " | $d"
    }
    $header

    $msg = ($(if ($Entry.msg) { $Entry.msg } else { '' }) -replace '\r', '').TrimEnd()
    if ($showPaths) { 'Message:' }
    foreach ($line in ($msg -split '\n')) { "  $line" }

    if ($showPaths) {
        $paths = if ($Entry.paths) { $Entry.paths.path } else { $null }
        if ($paths) {
            'Paths:'
            foreach ($p in $paths) {
                $cfPath   = $p.GetAttribute('copyfrom-path')
                $cfRev    = $p.GetAttribute('copyfrom-rev')
                $copyFrom = if ($cfPath) { "  [copied from $cfPath@$cfRev]" } else { '' }
                $nk       = $p.GetAttribute('node-kind')
                $nodeKind = if ($nk) { " ($nk)" } else { '' }
                "  [$($p.action)]$nodeKind $($p.'#text')$copyFrom"
            }
        }
    }
}

function Write-ColorSvnEntry {
    param($Entry, [int]$PatternIndex)

    $color = $colorPalette[$PatternIndex % $colorPalette.Count]
    $author = if ($Entry.author) { $Entry.author } else { '(none)' }

    Write-Host 'r' -NoNewline -ForegroundColor Yellow
    Write-Host $Entry.revision -NoNewline -ForegroundColor $color.Fg -BackgroundColor $color.Bg
    Write-Host " | $author" -NoNewline
    if ($Pattern -and $Pattern.Count -gt 1) {
        Write-Host ' | ' -NoNewline
        Write-Host "[$($PatternIndex + 1)] $($Pattern[$PatternIndex])" -NoNewline -ForegroundColor $color.Fg -BackgroundColor $color.Bg
    }
    if ($Entry.date) {
        $date = [datetime]::Parse($Entry.date, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
        Write-Host " | $date" -NoNewline
    }
    Write-Host ''

    $message = ($(if ($Entry.msg) { $Entry.msg } else { '' }) -replace '\r', '').TrimEnd()
    if ($showPaths) { Write-Host 'Message:' -ForegroundColor Yellow }
    foreach ($line in ($message -split '\n')) {
        if ($Pattern) {
            Write-Host "  $line" -ForegroundColor $color.Fg -BackgroundColor $color.Bg
        } else {
            Write-Host "  $line"
        }
    }

    if ($showPaths) {
        $paths = if ($Entry.paths) { $Entry.paths.path } else { $null }
        if ($paths) {
            Write-Host 'Paths:' -ForegroundColor Yellow
            foreach ($path in $paths) {
                $action = $path.action
                $copyFromPath = $path.GetAttribute('copyfrom-path')
                $copyFromRevision = $path.GetAttribute('copyfrom-rev')
                $copyFrom = if ($copyFromPath) { "  [copied from $copyFromPath@$copyFromRevision]" } else { '' }
                $nodeKindValue = $path.GetAttribute('node-kind')
                $nodeKind = if ($nodeKindValue) { " ($nodeKindValue)" } else { '' }
                $pathText = $path.'#text'
                $prefix = "  [$action]$nodeKind "
                $pathColor = switch ($action) {
                    'A' { 'Green'   }
                    'D' { 'Red'     }
                    'M' { 'Cyan'    }
                    'R' { 'Magenta' }
                    default { 'White' }
                }

                if ($fileRegex -and $fileRegex.IsMatch($pathText)) {
                    $match = $fileRegex.Match($pathText)
                    $before = $pathText.Substring(0, $match.Index)
                    $after = $pathText.Substring($match.Index + $match.Length)
                    Write-Host "$prefix$before" -NoNewline -ForegroundColor $pathColor
                    Write-Host $match.Value -NoNewline -ForegroundColor $color.Fg -BackgroundColor $color.Bg
                    Write-Host "$after$copyFrom" -ForegroundColor $pathColor
                } else {
                    Write-Host "$prefix$pathText$copyFrom" -ForegroundColor $pathColor
                }
            }
        }
    }
}

foreach ($result in $results) {
    if ($displayCount -gt 0) {
        Write-Host ('-' * 60) -ForegroundColor DarkGray
    }
    Write-ColorSvnEntry $result.Entry $result.PatternIndex
    $displayCount++

    if ($PageSize -gt 0 -and $displayCount -lt $results.Count -and ($displayCount % $PageSize) -eq 0) {
        Write-Host "-- $displayCount of $($results.Count) -- Press any key for more, Q to quit --" -ForegroundColor DarkGray -NoNewline
        $keyInfo = [System.Console]::ReadKey($true)
        Write-Host ''
        if ($keyInfo.Key -eq [System.ConsoleKey]::Q) { break }
    }
}

if ($Clipboard) {
    if (-not (Get-Command Set-Clipboard -ErrorAction SilentlyContinue)) {
        Write-Warning "Set-Clipboard is not available on this platform; skipping clipboard copy."
    } else {
        $clipLines = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $results.Count; $i++) {
            if ($i -gt 0) { $clipLines.Add('-' * 60) }
            foreach ($l in (Format-PlainSvnEntry $results[$i].Entry $results[$i].PatternIndex)) {
                $clipLines.Add($l)
            }
        }
        ($clipLines -join [Environment]::NewLine) | Set-Clipboard
        Write-Host "Copied $($results.Count) revision(s) as plain text to the clipboard." -ForegroundColor Green
    }
}
}
