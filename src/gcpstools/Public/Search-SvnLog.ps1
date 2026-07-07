#Requires -Version 7.0

function Search-SvnLog {
<#
.SYNOPSIS
    Searches SVN log history for one or more patterns in commit messages.

.DESCRIPTION
    Runs svn log from the current (or specified) working directory, parses the
    structured XML output, and displays full details for every commit whose
    message matches any of the given patterns. Each pattern's matches are
    displayed in a distinct color.

.PARAMETER Pattern
    One or more patterns to match against SVN commit messages.
    By default these are regular expressions (case-insensitive).
    Use -SimpleMatch to treat them as literal strings.

.PARAMETER Path
    Working-copy path to run svn log against. Defaults to the current directory.

.PARAMETER Limit
    Maximum number of log entries to retrieve from SVN. 0 means no limit (all history).

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

.EXAMPLE
    .\Search-SvnLog.ps1 -Pattern "fix null reference"

.EXAMPLE
    .\Search-SvnLog.ps1 -Pattern "bug fix" -IncludeFile "SettingsService\.cs"

.EXAMPLE
    .\Search-SvnLog.ps1 "deploy(ment|ed)" -Path C:\MyRepo -Limit 1000

.EXAMPLE
    .\Search-SvnLog.ps1 "^JIRA-\d+" -CaseSensitive

.EXAMPLE
    .\Search-SvnLog.ps1 -Pattern "bug 1234","bug 5678" -SimpleMatch
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]] $Pattern,

    [Parameter(Position = 1)]
    [string] $Path = (Get-Location).Path,

    [Parameter()]
    [ValidateRange(0, [int]::MaxValue)]
    [int] $Limit = 200,

    [Parameter()]
    [switch] $CaseSensitive,

    [Parameter()]
    [switch] $SimpleMatch,

    [Parameter()]
    [string] $IncludeFile,

    [Parameter()]
    [switch] $Descending,

    [Parameter()]
    [switch] $ShowPaths,

    [Parameter()]
    [ValidateRange(1, [int]::MaxValue)]
    [int] $First,

    [Parameter()]
    [ValidateRange(1, [int]::MaxValue)]
    [int] $Last,

    [Parameter()]
    [ValidateRange(0, [int]::MaxValue)]
    [int] $PageSize = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Color palette for patterns ------------------------------------------------
$colorPalette = @(
    @{ Fg = 'White';  Bg = 'DarkBlue';    Spectre = 'blue'    }
    @{ Fg = 'White';  Bg = 'DarkGreen';   Spectre = 'green'   }
    @{ Fg = 'White';  Bg = 'DarkMagenta'; Spectre = 'purple'  }
    @{ Fg = 'Black';  Bg = 'DarkYellow';  Spectre = 'yellow'  }
    @{ Fg = 'White';  Bg = 'DarkRed';     Spectre = 'red'     }
    @{ Fg = 'White';  Bg = 'DarkCyan';    Spectre = 'teal'    }
    @{ Fg = 'Black';  Bg = 'Gray';        Spectre = 'grey'    }
)

# --- Check for PwshSpectreConsole module ---------------------------------------
$hasSpectre = $null -ne (Get-Module -ListAvailable -Name PwshSpectreConsole)
if (-not $hasSpectre) {
    Write-Host "PwshSpectreConsole module not found. Install it for enhanced output?" -ForegroundColor Yellow
    Write-Host "  [Y] Yes  [N] No (continue without it)" -ForegroundColor DarkGray -NoNewline
    $keyInfo = [System.Console]::ReadKey($true)
    Write-Host ''
    if ($keyInfo.Key -eq [System.ConsoleKey]::Y) {
        Write-Host "Installing PwshSpectreConsole..." -ForegroundColor Cyan
        Install-Module PwshSpectreConsole -Scope CurrentUser -Force -AllowClobber
        $hasSpectre = $true
    }
}
if ($hasSpectre) {
    Import-Module PwshSpectreConsole -ErrorAction SilentlyContinue
    $hasSpectre = $null -ne (Get-Command Format-SpectrePanel -ErrorAction SilentlyContinue)
}

# --- Build regex list for each pattern -----------------------------------------
$regexOptions = $CaseSensitive ? [System.Text.RegularExpressions.RegexOptions]::None
                               : [System.Text.RegularExpressions.RegexOptions]::IgnoreCase

$regexList = [System.Collections.Generic.List[System.Text.RegularExpressions.Regex]]::new()
if ($Pattern) {
    foreach ($pat in $Pattern) {
        $escaped = $SimpleMatch ? [System.Text.RegularExpressions.Regex]::Escape($pat) : $pat
        try {
            $regexList.Add([System.Text.RegularExpressions.Regex]::new($escaped, $regexOptions))
        } catch [System.ArgumentException] {
            Write-Error "Invalid regular expression '$pat': $($_.Exception.Message)"
            return
        }
    }
}

# --- Build svn arguments -------------------------------------------------------
$svnArgs = @('log', '--xml', '--verbose', $Path)
if ($Limit -gt 0) {
    $svnArgs += '--limit', $Limit
}

Write-Host "Fetching SVN log for: $Path" -ForegroundColor Cyan
if ($Limit -gt 0) {
    Write-Host "  (limited to last $Limit entries)" -ForegroundColor DarkGray
} else {
    Write-Host "  (no limit — retrieving all entries)" -ForegroundColor DarkGray
}
Write-Host ''
if ($Pattern) {
    Write-Host "Patterns:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Pattern.Count; $i++) {
        $c = $colorPalette[$i % $colorPalette.Count]
        Write-Host "  [$($i + 1)] " -NoNewline -ForegroundColor Cyan
        Write-Host $Pattern[$i] -NoNewline -ForegroundColor $c.Fg -BackgroundColor $c.Bg
        Write-Host ''
    }
}
if ($IncludeFile) {
    Write-Host "File filter: $IncludeFile" -ForegroundColor Cyan
}
Write-Host ''

# --- Retrieve and parse log ----------------------------------------------------
$rawXml = svn @svnArgs 2>&1

if ($LASTEXITCODE -ne 0) {
    $errorText = $rawXml | Where-Object { $_ -is [string] } | Out-String
    Write-Error "svn log failed (exit $LASTEXITCODE):`n$errorText"
    return
}

[xml]$logXml = $rawXml | Out-String

$entries = $logXml.log.logentry
if (-not $entries) {
    Write-Host "No log entries found." -ForegroundColor Yellow
    return
}

# --- Build file filter regex if specified --------------------------------------
$fileRegex = $null
if ($IncludeFile) {
    $escapedFile = $SimpleMatch ? [System.Text.RegularExpressions.Regex]::Escape($IncludeFile) : $IncludeFile
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
        $paths = $entry.paths?.path
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

Write-Host "Found $($results.Count) matching commit(s)" -ForegroundColor Green
Write-Host ''

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

foreach ($result in $results) {
    $entry = $result.Entry
    $color = $colorPalette[$result.PatternIndex % $colorPalette.Count]

    # Core fields — single line: Revision, Author, Pattern, Date
    Write-Host "r" -NoNewline -ForegroundColor Yellow
    Write-Host $entry.revision -NoNewline -ForegroundColor $color.Fg -BackgroundColor $color.Bg
    Write-Host " | " -NoNewline -ForegroundColor DarkGray
    Write-Host ($entry.author ?? '(none)') -NoNewline
    if ($Pattern -and $Pattern.Count -gt 1) {
        Write-Host " | " -NoNewline -ForegroundColor DarkGray
        Write-Host "[$($result.PatternIndex + 1)] $($Pattern[$result.PatternIndex])" -NoNewline -ForegroundColor $color.Fg -BackgroundColor $color.Bg
    }
    $rawDate = $entry.date
    if ($rawDate) {
        $parsedDate = [datetime]::Parse($rawDate, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $localDate  = $parsedDate.ToLocalTime()
        $timeSpan   = [datetime]::Now - $localDate
        $ago = if ($timeSpan.TotalDays -ge 365) {
            $years = [math]::Floor($timeSpan.TotalDays / 365)
            "$years year$(if ($years -ne 1) {'s'}) ago"
        } elseif ($timeSpan.TotalDays -ge 30) {
            $months = [math]::Floor($timeSpan.TotalDays / 30)
            "$months month$(if ($months -ne 1) {'s'}) ago"
        } elseif ($timeSpan.TotalDays -ge 7) {
            $weeks = [math]::Floor($timeSpan.TotalDays / 7)
            "$weeks week$(if ($weeks -ne 1) {'s'}) ago"
        } elseif ($timeSpan.TotalDays -ge 1) {
            $days = [math]::Floor($timeSpan.TotalDays)
            "$days day$(if ($days -ne 1) {'s'}) ago"
        } elseif ($timeSpan.TotalHours -ge 1) {
            $hours = [math]::Floor($timeSpan.TotalHours)
            "$hours hour$(if ($hours -ne 1) {'s'}) ago"
        } else {
            $mins = [math]::Floor($timeSpan.TotalMinutes)
            "$mins minute$(if ($mins -ne 1) {'s'}) ago"
        }
        Write-Host " | " -NoNewline -ForegroundColor DarkGray
        Write-Host $localDate -NoNewline
        Write-Host " ($ago)" -NoNewline -ForegroundColor DarkGray
    }
    Write-Host ''

    # Changed paths
    if ($ShowPaths) {
    $paths = $entry.paths?.path
    if ($paths) {
        if ($hasSpectre) {
            $pathLines = foreach ($p in $paths) {
                $action    = $p.action
                $cfPath    = $p.GetAttribute('copyfrom-path')
                $cfRev     = $p.GetAttribute('copyfrom-rev')
                $copyFrom  = if ($cfPath) { "  [copied from $(Get-SpectreEscapedText $cfPath)@$cfRev]" } else { '' }
                $nk        = $p.GetAttribute('node-kind')
                $nodeKind  = if ($nk) { " ($nk)" } else { '' }
                $pathText  = Get-SpectreEscapedText $p.'#text'
                $spectrePathColor = switch ($action) {
                    'A' { 'green'   }
                    'D' { 'red'     }
                    'M' { 'cyan1'   }
                    'R' { 'purple'  }
                    default { 'white' }
                }
                "[$spectrePathColor]$(Get-SpectreEscapedText "[$action]")$nodeKind $pathText$copyFrom[/]"
            }
            $pathContent = $pathLines -join "`n"
            $prevRendering = $PSStyle.OutputRendering
            $PSStyle.OutputRendering = 'Ansi'
            $panel = ($pathContent | Format-SpectrePanel -Header "Paths" -Color $color.Spectre -Expand | Out-String).Trim()
            $PSStyle.OutputRendering = $prevRendering
            [System.Console]::WriteLine($panel)
        } else {
            Write-Host "Paths    :" -ForegroundColor Yellow
            foreach ($p in $paths) {
                $action    = $p.action
                $cfPath    = $p.GetAttribute('copyfrom-path')
                $cfRev     = $p.GetAttribute('copyfrom-rev')
                $copyFrom  = if ($cfPath) { "  [copied from $cfPath@$cfRev]" } else { '' }
                $nk        = $p.GetAttribute('node-kind')
                $nodeKind  = if ($nk) { " ($nk)" } else { '' }
                $pathText  = $p.'#text'
                $prefix    = "           [$action]$nodeKind "

                if ($fileRegex -and $fileRegex.IsMatch($pathText)) {
                    # Highlight the matching portion of the path
                    $m = $fileRegex.Match($pathText)
                    $before = $pathText.Substring(0, $m.Index)
                    $match  = $m.Value
                    $after  = $pathText.Substring($m.Index + $m.Length)
                    Write-Host $prefix -NoNewline -ForegroundColor Cyan
                    Write-Host $before -NoNewline -ForegroundColor Cyan
                    Write-Host $match -NoNewline -ForegroundColor $color.Fg -BackgroundColor $color.Bg
                    Write-Host "$after$copyFrom" -ForegroundColor Cyan
                } else {
                    $pathColor = switch ($action) {
                        'A' { 'Green'   }
                        'D' { 'Red'     }
                        'M' { 'Cyan'    }
                        'R' { 'Magenta' }
                        default { 'White' }
                    }
                    Write-Host "$prefix$pathText$copyFrom" -ForegroundColor $pathColor
                }
            }
        }
    }
    }

    # Commit message — colored by matching pattern only if -Pattern was specified
    $msg = ($entry.msg ?? '') -replace '\r', ''
    if ($hasSpectre) {
        $spectreColor = $color.Spectre
        $escapedMsg = $msg | Get-SpectreEscapedText
        $prevRendering = $PSStyle.OutputRendering
        $PSStyle.OutputRendering = 'Ansi'
        $panel = ($escapedMsg | Format-SpectrePanel -Header "Message" -Color $spectreColor -Expand | Out-String).TrimStart()
        $PSStyle.OutputRendering = $prevRendering
        [System.Console]::Write($panel)
    } else {
        Write-Host "Message  :" -ForegroundColor Yellow
        $lines = $msg -split '\n'
        foreach ($line in $lines) {
            if ($Pattern) {
                Write-Host "  $line" -NoNewline -ForegroundColor $color.Fg -BackgroundColor $color.Bg
                Write-Host ''
            } else {
                Write-Host "  $line"
            }
        }
    }

    $displayCount++

    # Pause after PageSize commits
    if ($PageSize -gt 0 -and $displayCount -lt $results.Count -and ($displayCount % $PageSize) -eq 0) {
        Write-Host "-- $displayCount of $($results.Count) -- Press any key for more, Q to quit --" -ForegroundColor DarkGray -NoNewline
        $keyInfo = [System.Console]::ReadKey($true)
        Write-Host ''
        if ($keyInfo.Key -eq [System.ConsoleKey]::Q) { break }
    }
}

Write-Host "Total matches: $($results.Count)" -ForegroundColor Green
Write-Host ''
}
