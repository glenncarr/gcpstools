#Requires -Version 7.0
#Requires -Modules PSReadLine

function Set-RegexHistorySearch {
<#
.SYNOPSIS
    Registers a PSReadLine key handler that searches command history with a regex.

.DESCRIPTION
    Dot-source this file from your $PROFILE.  Press the bound key to open an
    inline prompt, type a .NET regex, then pick from matching history entries
    with arrow keys.  Matches are returned newest-first and deduplicated.

    Key behaviour:
      Enter                – confirm pattern / select entry
      Escape               – cancel at any point and restore the original buffer
      ↑ / ↓                – move the selection one entry
      PageUp / PageDown    – move the selection one page
      Home / End           – jump to the first / last entry

    History is read from PSReadLine's persistent save file, so matches include
    commands from previous sessions.  Multi-line commands are reconstructed and
    shown on a single line (newlines rendered as '↵') but inserted in full.

.PARAMETER Key
    PSReadLine chord to bind.  Defaults to 'Ctrl+Alt+r'.
    Any chord accepted by Set-PSReadLineKeyHandler is valid, e.g. 'F9'.

.EXAMPLE
    # Add to $PROFILE:
    . "$HOME\scripts\Set-RegexHistorySearch.ps1"

.EXAMPLE
    # Custom binding:
    . "$HOME\scripts\Set-RegexHistorySearch.ps1" -Key 'F9'
#>

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Registers a PSReadLine key handler; there is no destructive state change to gate behind ShouldProcess.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The key handler scriptblock signature (key, arg) is mandated by PSReadLine.')]
param(
    [string] $Key = 'Ctrl+Alt+r'
)

# ---------------------------------------------------------------------------
# Console list-picker – captured as a closure so PSReadLine can call it
# without polluting the global namespace.
# ---------------------------------------------------------------------------
$selectFromList = {
    param([string[]] $Items)

    $pageSize = [Math]::Min($Items.Count, 10)
    $index    = 0
    $offset   = 0   # first visible item index
    $startTop = [Console]::CursorTop
    $esc      = [char]27
    $width    = [Console]::WindowWidth - 1

    $draw = {
        [Console]::SetCursorPosition(0, $startTop)
        for ($i = 0; $i -lt $pageSize; $i++) {
            $itemIdx = $offset + $i
            $text = $Items[$itemIdx]
            if ($text.Length -gt ($width - 2)) { $text = $text.Substring(0, $width - 2) }
            $pad  = ' ' * [Math]::Max(0, $width - $text.Length - 2)
            if ($itemIdx -eq $index) {
                [Console]::Write("$esc[7m> $text$pad$esc[0m`n")
            } else {
                [Console]::Write("  $text$pad`n")
            }
        }
    }

    # Reserve display rows below current cursor position
    for ($i = 0; $i -lt $pageSize; $i++) { [Console]::WriteLine() }
    $startTop = [Console]::CursorTop - $pageSize
    & $draw

    # Returns the selected item index, or -1 if cancelled.
    $result = -1
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Enter')  { $result = $index; break }
        if ($k.Key -eq 'Escape') { $result = -1;     break }

        $prev = $index
        switch ($k.Key) {
            'UpArrow'   { $index-- }
            'DownArrow' { $index++ }
            'PageUp'    { $index -= $pageSize }
            'PageDown'  { $index += $pageSize }
            'Home'      { $index = 0 }
            'End'       { $index = $Items.Count - 1 }
        }

        if ($index -lt 0)                { $index = 0 }
        if ($index -ge $Items.Count)     { $index = $Items.Count - 1 }
        if ($index -eq $prev)            { continue }
        if ($index -lt $offset)          { $offset = $index }
        elseif ($index -ge $offset + $pageSize) { $offset = $index - $pageSize + 1 }
        & $draw
    }

    # Erase picker rows
    [Console]::SetCursorPosition(0, $startTop)
    $blank = ' ' * $width
    for ($i = 0; $i -lt $pageSize; $i++) { [Console]::WriteLine($blank) }
    [Console]::SetCursorPosition(0, $startTop)

    return $result
}

# ---------------------------------------------------------------------------
# Reads PSReadLine's persistent history file and reconstructs entries
# newest-first.  Multi-line commands are stored as backtick-continued physical
# lines; this joins them back into single entries.
# ---------------------------------------------------------------------------
$getHistory = {
    $path = (Get-PSReadLineOption).HistorySavePath
    if ([string]::IsNullOrEmpty($path) -or -not [System.IO.File]::Exists($path)) {
        return @()
    }

    $entries = [System.Collections.Generic.List[string]]::new()
    $sb      = [System.Text.StringBuilder]::new()
    foreach ($line in [System.IO.File]::ReadLines($path)) {
        if ($line.EndsWith('`')) {
            [void]$sb.Append($line, 0, $line.Length - 1).Append("`n")
        } else {
            [void]$sb.Append($line)
            [void]$entries.Add($sb.ToString())
            [void]$sb.Clear()
        }
    }
    if ($sb.Length -gt 0) { [void]$entries.Add($sb.ToString()) }

    $entries.Reverse()
    return $entries.ToArray()
}

# ---------------------------------------------------------------------------
# Key handler – uses GetNewClosure() so $selectFromList and $getHistory
# are captured
# ---------------------------------------------------------------------------
$handlerBlock = {
    param($key, $arg)

    # Save current buffer so Escape can restore it
    $savedLine   = $null
    $savedCursor = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$savedLine, [ref]$savedCursor)

    # Show an inline prompt and collect the regex pattern character by character
    [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
    [Microsoft.PowerShell.PSConsoleReadLine]::Insert('history~> ')

    $chars = [System.Collections.Generic.List[char]]::new()
    :inputLoop while ($true) {
        $k = [Console]::ReadKey($true)
        switch ($k.Key) {
            'Enter'     { break inputLoop }
            'Escape'    { $chars.Clear(); break inputLoop }
            'Backspace' {
                if ($chars.Count -gt 0) {
                    $chars.RemoveAt($chars.Count - 1)
                    [Microsoft.PowerShell.PSConsoleReadLine]::BackwardDeleteChar()
                }
            }
            default {
                if ($k.KeyChar -ne "`0") {
                    $chars.Add($k.KeyChar)
                    [Microsoft.PowerShell.PSConsoleReadLine]::Insert($k.KeyChar)
                }
            }
        }
    }

    $pattern = -join $chars
    [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()

    if ([string]::IsNullOrWhiteSpace($pattern)) {
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert($savedLine)
        return
    }

    # Compile the regex once so an invalid pattern is reported clearly instead
    # of silently matching nothing.
    try {
        $regex = [System.Text.RegularExpressions.Regex]::new(
            $pattern,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    } catch {
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert("# invalid regex: $pattern")
        Start-Sleep -Milliseconds 900
        [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert($savedLine)
        return
    }

    # Collect matches: newest-first, case-insensitive, deduplicated
    $seen   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $hits   = @(
        & $getHistory |
            Where-Object { $_ -and $regex.IsMatch($_) } |
            Where-Object { $seen.Add($_) }
    )

    if ($hits.Count -eq 0) {
        # Flash a brief "no matches" notice then restore the original line
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert("# no matches: $pattern")
        Start-Sleep -Milliseconds 700
        [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert($savedLine)
        return
    }

    if ($hits.Count -eq 1) {
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert($hits[0])
        return
    }

    # Multiple matches – show interactive picker.  Multi-line entries are
    # collapsed to a single display line, but the full command is inserted.
    $display = $hits | ForEach-Object { $_ -replace '\r?\n', ' ↵ ' }
    [Console]::WriteLine()
    $chosenIndex = & $selectFromList -Items $display
    if ($chosenIndex -ge 0) {
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert($hits[$chosenIndex])
    } else {
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert($savedLine)
    }
}.GetNewClosure()

Set-PSReadLineKeyHandler `
    -Key              $Key `
    -BriefDescription 'RegexHistorySearch' `
    -LongDescription  "Search command history with a .NET regex ($Key)" `
    -ScriptBlock      $handlerBlock
}
