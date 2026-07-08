Describe 'Format-DirectoryDiff' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\gcpstools\Public\Format-DirectoryDiff.ps1"
    }

    It 'Throws on PowerShell 5.x' {
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            Set-ItResult -Skipped -Because 'Only relevant on PS5.x'
            return
        }
        $obj = [PSCustomObject]@{ Status = 'Match'; FileName = 'test.txt'; SourceLWT = $null; DestLWT = $null }
        { $obj | Format-DirectoryDiff } | Should -Throw
    }

    It 'Does not throw for valid input on PS7+' {
        if ($PSVersionTable.PSVersion.Major -lt 7) {
            Set-ItResult -Skipped -Because 'Requires PowerShell 7+'
            return
        }
        $now = Get-Date
        $obj = [PSCustomObject]@{ Status = 'Match'; FileName = 'test.txt'; SourceLWT = $now; DestLWT = $now }
        { $obj | Format-DirectoryDiff } | Should -Not -Throw
    }

    It 'Does not throw for all known status values on PS7+' {
        if ($PSVersionTable.PSVersion.Major -lt 7) {
            Set-ItResult -Skipped -Because 'Requires PowerShell 7+'
            return
        }
        $now = Get-Date
        $statuses = 'Match', 'MissingInDest', 'ContentMismatch', 'SilentCorruption'
        foreach ($status in $statuses) {
            $obj = [PSCustomObject]@{ Status = $status; FileName = 'f.txt'; SourceLWT = $now; DestLWT = $now }
            { $obj | Format-DirectoryDiff } | Should -Not -Throw
        }
    }
}
