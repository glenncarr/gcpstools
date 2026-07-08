Describe 'Test-Xml' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\gcpstools\Public\Test-Xml.ps1"
    }

    It 'Writes an error for a non-existent XML file' {
        { Test-Xml -XmlPath 'C:\nonexistent_file.xml' `
                   -XsdUrl 'http://example.com/schema.xsd' `
                   -TargetNamespace 'urn:test' `
                   -ErrorAction Stop } | Should -Throw
    }

    It 'Writes an error when the schema cannot be loaded' {
        $xmlFile = Join-Path $TestDrive 'test.xml'
        Set-Content -Path $xmlFile -Value '<root />'

        { Test-Xml -XmlPath $xmlFile `
                   -XsdUrl 'http://127.0.0.1:1/invalid-schema' `
                   -TargetNamespace 'urn:test' `
                   -ErrorAction Stop } | Should -Throw
    }
}
