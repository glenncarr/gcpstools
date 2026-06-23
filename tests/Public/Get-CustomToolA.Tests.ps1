Describe 'Get-CustomToolA' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\gcpstools\Public\Get-CustomToolA.ps1"
    }

    It 'Should return expected output' {
        $result = Get-CustomToolA
        $result | Should -Be 'CustomToolA output'
    }
}
