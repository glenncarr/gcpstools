function Format-DirectoryDiff {
    <#
    .SYNOPSIS
        Applies color formatting to Directory Comparison results.
    #>
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline = $true)]
        $InputObject
    )

    begin {
        if ($PSVersionTable.PSVersion.Major -lt 7) {
            throw "This function requires PowerShell 7.0 or newer."
        }
        $items = [System.Collections.Generic.List[PSObject]]::new()
    }

    process {
        $items.Add($InputObject)
    }

    end {
        if ($items.Count -eq 0) { return }

        $items | Format-Table FileName, @{
            Name   = "Status"
            Expression = { 
                switch ($_.Status) {
                    "Match"             { $Color = $PSStyle.Foreground.BrightGreen }
                    "MissingInDest"     { $Color = $PSStyle.Foreground.BrightYellow }
                    "ContentMismatch"   { $Color = $PSStyle.Foreground.BrightRed }
                    "SilentCorruption"  { $Color = $PSStyle.Foreground.BrightMagenta }
                    Default { $Color = "" }
                }
                "$($Color)$($_.Status)$($PSStyle.Reset)" }
        }, 
        @{
            Name   = "SourceLWT"
            Expression = { 
                if ($_.SourceLWT -gt $_.DestLWT) {
                    $Color = $PSStyle.Foreground.BrightWhite
                }
                "$($Color)$($_.SourceLWT)$($PSStyle.Reset)"
                }
        },         
        @{
            Name   = ">/</="
            Expression = { if ($_.SourceLWT -lt $_.DestLWT) { "<" } elseif ($_.SourceLWT -gt $_.DestLWT) { ">" } else { "=" } }
            Alignment = "Center"
        },
        @{
            Name   = "DestLWT"
            Expression = { 
                if ($_.SourceLWT -lt $_.DestLWT) {
                    $Color = $PSStyle.Foreground.BrightWhite
                }
                "$($Color)$($_.DestLWT)$($PSStyle.Reset)"
                }
        }
    }
}