Describe 'Search-AppEventLog' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\gcpstools\Public\Search-AppEventLog.ps1"
    }

    It 'Does not throw for a search string that matches nothing' {
        { Search-AppEventLog -SearchString 'ZZZ_NO_MATCH_IN_LOG_ZZZ_99999' -MaxEvents 50 } |
            Should -Not -Throw
    }

    It 'Does not throw for a MaxEvents value of 1' {
        { Search-AppEventLog -SearchString 'ZZZ_NO_MATCH_IN_LOG_ZZZ_99999' -MaxEvents 1 } |
            Should -Not -Throw
    }
}
