<#
.SYNOPSIS
    Scans a file for invalid UTF-8 byte sequences and reports where they occur.

.DESCRIPTION
    Reads the target file as raw bytes and walks the buffer applying the UTF-8
    decoding rules (RFC 3629). Any byte that does not form a valid UTF-8 sequence
    is reported with its byte offset, the approximate line/column, and a snippet
    of the surrounding text so the offending comment/character can be located.

    A byte-order mark (BOM), if present, is detected and skipped.

.PARAMETER Path
    One or more paths to the files to scan.

.PARAMETER Context
    Number of characters of surrounding text to show around each bad byte.
    Defaults to 40.

.EXAMPLE
    .\Find-InvalidUtf8.ps1 -Path .\Public\API\Progistics.API.xml

.EXAMPLE
    Get-ChildItem -Recurse -Filter *.cs | .\Find-InvalidUtf8.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias('FullName')]
    [string[]]$Path,

    [ValidateRange(0, 500)]
    [int]$Context = 40
)

begin {
    function Test-Utf8Byte {
        param([byte[]]$Bytes, [int]$Index)

        $b = $Bytes[$Index]

        # ASCII (0xxxxxxx): always valid, 1 byte.
        if ($b -le 0x7F) { return [pscustomobject]@{ Length = 1; Valid = $true } }

        # Continuation byte (10xxxxxx) appearing where a leading byte is expected.
        if ($b -ge 0x80 -and $b -le 0xBF) { return [pscustomobject]@{ Length = 1; Valid = $false } }

        # Determine expected sequence length and the valid range of the first byte.
        if ($b -ge 0xC2 -and $b -le 0xDF) {
            $needed = 1; $min = 0x80; $max = 0x7FF
        }
        elseif ($b -ge 0xE0 -and $b -le 0xEF) {
            $needed = 2; $min = 0x800; $max = 0xFFFF
        }
        elseif ($b -ge 0xF0 -and $b -le 0xF4) {
            $needed = 3; $min = 0x10000; $max = 0x10FFFF
        }
        else {
            # 0xC0, 0xC1, 0xF5-0xFF are never valid leading bytes.
            return [pscustomobject]@{ Length = 1; Valid = $false }
        }

        # Not enough bytes left to complete the sequence.
        if (($Index + $needed) -ge $Bytes.Length) {
            return [pscustomobject]@{ Length = 1; Valid = $false }
        }

        $codepoint = $b -band (0x7F -shr $needed)
        for ($j = 1; $j -le $needed; $j++) {
            $cont = $Bytes[$Index + $j]
            if ($cont -lt 0x80 -or $cont -gt 0xBF) {
                return [pscustomobject]@{ Length = 1; Valid = $false }
            }
            $codepoint = ($codepoint -shl 6) -bor ($cont -band 0x3F)
        }

        # Reject overlong encodings, surrogates, and out-of-range code points.
        if ($codepoint -lt $min -or $codepoint -gt $max -or
            ($codepoint -ge 0xD800 -and $codepoint -le 0xDFFF)) {
            return [pscustomobject]@{ Length = 1; Valid = $false }
        }

        return [pscustomobject]@{ Length = ($needed + 1); Valid = $true }
    }
}

process {
    foreach ($p in $Path) {
        $resolved = Resolve-Path -LiteralPath $p -ErrorAction SilentlyContinue
        if (-not $resolved) {
            Write-Warning "File not found: $p"
            continue
        }

        $file = $resolved.ProviderPath
        $bytes = [System.IO.File]::ReadAllBytes($file)

        # Detect and skip a UTF-8 BOM if present.
        $start = 0
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $start = 3
        }

        $line = 1
        $col = 1
        $i = $start
        $findings = @()

        while ($i -lt $bytes.Length) {
            $b = $bytes[$i]

            # Track line/column using ASCII newlines (before evaluating the byte).
            if ($b -eq 0x0A) {
                $line++; $col = 1; $i++
                continue
            }

            $result = Test-Utf8Byte -Bytes $bytes -Index $i

            if (-not $result.Valid) {
                $from = [Math]::Max($start, $i - $Context)
                $to = [Math]::Min($bytes.Length - 1, $i + $Context)
                $len = $to - $from + 1

                # Decode the surrounding window, replacing bad bytes so it prints cleanly.
                $decoder = [System.Text.Encoding]::GetEncoding(
                    'utf-8',
                    [System.Text.EncoderReplacementFallback]::new('?'),
                    [System.Text.DecoderReplacementFallback]::new('?')
                )
                $snippet = $decoder.GetString($bytes, $from, $len) -replace '[\r\n]', ' '

                $findings += [pscustomobject]@{
                    File    = $file
                    Line    = $line
                    Column  = $col
                    Offset  = $i
                    ByteHex = ('0x{0:X2}' -f $b)
                    Snippet = $snippet
                }
                $col++
                $i++
            }
            else {
                $col++
                $i += $result.Length
            }
        }

        if ($findings.Count -eq 0) {
            Write-Host "Valid UTF-8: $file" -ForegroundColor Green
        }
        else {
            Write-Host "Invalid UTF-8: $file ($($findings.Count) bad byte(s))" -ForegroundColor Red
            $findings
        }
    }
}
