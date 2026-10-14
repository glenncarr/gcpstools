Describe 'Search-SvnLog' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\gcpstools\Public\Search-SvnLog.ps1"

        # Placeholder so 'svn' resolves and can be mocked even when SVN is not installed.
        function svn { }

        $script:sampleXml = @'
<?xml version="1.0" encoding="UTF-8"?>
<log>
<logentry revision="101">
<author>alice</author>
<date>2026-01-01T10:00:00.000000Z</date>
<paths>
<path action="M" node-kind="file">/trunk/src/App.cs</path>
</paths>
<msg>fix null reference in parser</msg>
</logentry>
<logentry revision="102">
<author>bob</author>
<date>2026-02-01T10:00:00.000000Z</date>
<paths>
<path action="A" node-kind="file">/trunk/src/Feature.cs</path>
</paths>
<msg>add new feature</msg>
</logentry>
</log>
'@
    }

    BeforeEach {
        Mock svn {
            $global:LASTEXITCODE = 0
            $script:sampleXml
        }
    }

    It 'returns plain-text output by default containing the revision and message' {
        $out = Search-SvnLog -Path 'C:\repo' -Pattern 'fix'
        ($out -join "`n") | Should -Match 'r101'
        ($out -join "`n") | Should -Match 'fix null reference in parser'
    }

    It 'omits the "Message:" label in plain-text output' {
        $out = Search-SvnLog -Path 'C:\repo' -Pattern 'fix'
        $out | Should -Not -Contain 'Message:'
        ($out -join "`n") | Should -Not -Match 'Message:'
    }

    It 'produces no ANSI escape sequences in plain-text output' {
        $out = Search-SvnLog -Path 'C:\repo' -Pattern 'fix'
        ($out -join "`n") | Should -Not -Match ([char]27)
    }

    It 'uses colored host output when -UseColor is specified' {
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            Mock Get-Module { [pscustomobject]@{ Name = 'PwshSpectreConsole' } } -ParameterFilter { $ListAvailable -and $Name -eq 'PwshSpectreConsole' }
            Mock Import-Module {}
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Format-SpectrePanel' }
        }

        $out = Search-SvnLog -Path 'C:\repo' -Pattern 'fix' -UseColor 6>&1
        ($out | Out-String) | Should -Match 'Fetching SVN log for:'
        ($out | Out-String) | Should -Match 'Total matches: 1'
    }

    It 'filters commits by pattern' {
        $out = Search-SvnLog -Path 'C:\repo' -Pattern 'new feature'
        ($out -join "`n") | Should -Match 'r102'
        ($out -join "`n") | Should -Not -Match 'r101'
    }

    It 'includes changed paths after the message and adds the label only with -ShowPaths' {
        $withPaths = Search-SvnLog -Path 'C:\repo' -Pattern 'fix' -ShowPaths
        $joined = $withPaths -join "`n"
        $joined | Should -Match 'Message:'
        $joined | Should -Match 'Paths:'
        $joined | Should -Match '/trunk/src/App\.cs'
        # Paths must appear after the message
        $joined.IndexOf('Message:') | Should -BeLessThan $joined.IndexOf('Paths:')

        $withoutPaths = Search-SvnLog -Path 'C:\repo' -Pattern 'fix'
        ($withoutPaths -join "`n") | Should -Not -Match 'Paths:'
        ($withoutPaths -join "`n") | Should -Not -Match 'Message:'
    }

    It 'returns no matching revisions for a non-matching pattern' {
        $out = Search-SvnLog -Path 'C:\repo' -Pattern 'ZZZ_NO_MATCH'
        ($out -join "`n") | Should -Not -Match 'r10'
        $out | Should -Contain 'No commits found matching the specified criteria.'
    }

    It 'returns a plain-text message when the log is empty' {
        $script:sampleXml = '<log />'

        $out = Search-SvnLog -Path 'C:\repo' -Pattern 'fix'

        $out | Should -Contain 'No log entries found.'
    }
}
