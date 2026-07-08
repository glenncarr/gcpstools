Describe 'Set-RegexHistorySearch' {
    BeforeAll {
        if (-not (Get-Module -ListAvailable -Name PSReadLine)) {
            Write-Warning 'PSReadLine not available - skipping Set-RegexHistorySearch tests.'
            return
        }
        Import-Module PSReadLine -ErrorAction Stop
        . "$PSScriptRoot\..\..\src\gcpstools\Public\Set-RegexHistorySearch.ps1"
    }

    It 'Does not throw when called with the default key' {
        if (-not (Get-Module -Name PSReadLine)) {
            Set-ItResult -Skipped -Because 'PSReadLine not available'
            return
        }
        { Set-RegexHistorySearch } | Should -Not -Throw
    }

    It 'Registers the key handler with the default chord Ctrl+Alt+r' {
        if (-not (Get-Module -Name PSReadLine)) {
            Set-ItResult -Skipped -Because 'PSReadLine not available'
            return
        }
        Set-RegexHistorySearch
        $handler = Get-PSReadLineKeyHandler -Bound |
            Where-Object { $_.Function -eq 'RegexHistorySearch' -and $_.Key -eq 'Ctrl+Alt+r' }
        $handler | Should -Not -BeNullOrEmpty
    }

    It 'Registers the key handler with a custom chord' {
        if (-not (Get-Module -Name PSReadLine)) {
            Set-ItResult -Skipped -Because 'PSReadLine not available'
            return
        }
        Set-RegexHistorySearch -Key 'Ctrl+Alt+t'
        $handler = Get-PSReadLineKeyHandler -Bound | Where-Object Key -eq 'Ctrl+Alt+t'
        $handler | Should -Not -BeNullOrEmpty
    }

    AfterAll {
        # Remove the custom binding registered by the tests so it doesn't leak
        # into the interactive session.
        if (Get-Module -Name PSReadLine) {
            Remove-PSReadLineKeyHandler -Key 'Ctrl+Alt+t' -ErrorAction SilentlyContinue
        }
    }
}
