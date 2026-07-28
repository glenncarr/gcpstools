function Find-FancyQuote {
<#
.SYNOPSIS
    Scans a file for "fancy" (non-ASCII) quote characters and reports where they occur.

.DESCRIPTION
    Reads each file and searches every line for typographic quote characters that
    are not the plain ASCII apostrophe (') or double quote ("). This includes
    curly/smart quotes, low-9 quotes, prime marks, and guillemets. Each match is
    reported with its line, column, the character, its Unicode code point, and the
    surrounding text so the offending quote can be located and, if desired, replaced
    with an ASCII equivalent.

    The file is read as UTF-8 by default. Use -Encoding to scan files stored in a
    legacy code page such as Windows-1252.

.PARAMETER Path
    One or more paths to the files to scan.

.PARAMETER Encoding
    The encoding used to read the file. Defaults to 'utf8'. Use 'windows-1252'
    (or a code page number) for legacy ANSI files.

.PARAMETER IncludeAccents
    Also flag the backtick (`) and acute accent (´), which are sometimes used as
    quotes. Off by default.

.EXAMPLE
    Find-FancyQuote -Path .\Documentation.xml

.EXAMPLE
    Get-ChildItem -Recurse -Filter *.xml | Find-FancyQuote -Encoding windows-1252
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias('FullName')]
    [string[]]$Path,

    [string]$Encoding = 'utf8',

    [switch]$IncludeAccents
)

begin {
    # Common non-ASCII quote-like characters, grouped by kind.
    $quoteCodePoints = @(
        0x2018, 0x2019, 0x201A, 0x201B,   # ‘ ’ ‚ ‛   single curly / low-9 / reversed
        0x201C, 0x201D, 0x201E, 0x201F,   # “ ” „ ‟   double curly / low-9 / reversed
        0x2032, 0x2033, 0x2035, 0x2036,   # ′ ″ ‵ ‶   primes
        0x00AB, 0x00BB, 0x2039, 0x203A    # « » ‹ ›   guillemets
    )

    if ($IncludeAccents) {
        $quoteCodePoints += @(0x0060, 0x00B4)   # ` ´   backtick, acute accent
    }

    # Suggested ASCII replacement for each character, keyed by code point.
    $asciiSuggestion = @{
        0x2018 = "'"; 0x2019 = "'"; 0x201A = "'"; 0x201B = "'"
        0x201C = '"'; 0x201D = '"'; 0x201E = '"'; 0x201F = '"'
        0x2032 = "'"; 0x2033 = '"'; 0x2035 = "'"; 0x2036 = '"'
        0x00AB = '"'; 0x00BB = '"'; 0x2039 = "'"; 0x203A = "'"
        0x0060 = "'"; 0x00B4 = "'"
    }

    $pattern = '[' + (($quoteCodePoints | ForEach-Object { '\u{0:X4}' -f $_ }) -join '') + ']'

    # Resolve the requested encoding once.
    $enc = switch -Regex ($Encoding) {
        '^\d+$'                     { [System.Text.Encoding]::GetEncoding([int]$Encoding); break }
        '^utf-?8$'                  { [System.Text.Encoding]::UTF8; break }
        '^(ascii)$'                 { [System.Text.Encoding]::ASCII; break }
        '^(unicode|utf-?16(le)?)$'  { [System.Text.Encoding]::Unicode; break }
        '^utf-?16be$'               { [System.Text.Encoding]::BigEndianUnicode; break }
        default                     { [System.Text.Encoding]::GetEncoding($Encoding) }
    }

    $regex = [regex]::new($pattern)
}

process {
    foreach ($p in $Path) {
        $resolved = Resolve-Path -LiteralPath $p -ErrorAction SilentlyContinue
        if (-not $resolved) {
            Write-Warning "File not found: $p"
            continue
        }

        $file = $resolved.ProviderPath
        $text = [System.IO.File]::ReadAllText($file, $enc)
        $lines = $text -split "`r`n|`n|`r"

        $findings = @()
        for ($n = 0; $n -lt $lines.Length; $n++) {
            $line = $lines[$n]
            foreach ($m in $regex.Matches($line)) {
                $cp = [int][char]$m.Value
                $findings += [pscustomobject]@{
                    File      = $file
                    Line      = $n + 1
                    Column    = $m.Index + 1
                    Char      = $m.Value
                    CodePoint = 'U+{0:X4}' -f $cp
                    Ascii     = $asciiSuggestion[$cp]
                    Text      = $line.Trim()
                }
            }
        }

        if ($findings.Count -eq 0) {
            Write-Host "No fancy quotes: $file" -ForegroundColor Green
        }
        else {
            Write-Host "Fancy quotes found: $file ($($findings.Count) match(es))" -ForegroundColor Yellow
            $findings
        }
    }
}
}
