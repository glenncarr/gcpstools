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
        $script:upToDateStatusXml = '<status><target path="C:\repo" /></status>'
        $script:staleStatusXml = '<status><target path="C:\repo"><entry path="C:\repo\App.cs"><wc-status item="normal" props="none" revision="1" /><repos-status item="modified" props="none" /></entry></target></status>'
    }

    BeforeEach {
        $script:statusXml = $script:upToDateStatusXml
        $script:statusArgs = @()
        $script:logArgs = @()
        Mock svn {
            $global:LASTEXITCODE = 0
            if ($args[0] -eq 'status') {
                $script:statusArgs = @($args)
                $script:statusXml
            } else {
                $script:logArgs = @($args)
                $script:sampleXml
            }
        }
    }

    It 'always renders colored host output with the revision and message' {
        $out = Search-SvnLog -Path 'C:\repo' -Pattern 'fix' 6>&1
        $joined = $out | Out-String
        $joined | Should -Match 'r\s+101'
        $joined | Should -Match 'fix null reference in parser'

        $revisionRecord = @($out | Where-Object {
            $_.MessageData -is [System.Management.Automation.HostInformationMessage] -and
            $_.MessageData.Message -eq '101'
        })
        $revisionRecord.Count | Should -Be 1
        $revisionRecord[0].MessageData.ForegroundColor | Should -Be White
        $revisionRecord[0].MessageData.BackgroundColor | Should -Be DarkBlue
    }

    It 'queries repository HEAD and reports when the working copy is out of date' {
        $script:statusXml = $script:staleStatusXml
        $warningMessages = @()

        $out = Search-SvnLog -Path 'C:\repo' -Pattern 'fix' -WarningVariable warningMessages 6>&1

        $script:statusArgs | Should -Contain '--show-updates'
        $script:statusArgs | Should -Contain '--xml'
        $script:logArgs | Should -Contain '--revision'
        $script:logArgs | Should -Contain 'HEAD:1'
        ($warningMessages -join "`n") | Should -Match 'Working copy .* is out of date'
        ($warningMessages -join "`n") | Should -Match 'The working copy was not updated'
        ($out | Out-String) | Should -Match 'r\s+101'
    }

    It 'uses one separator line between commits' {
        $out = Search-SvnLog -Path 'C:\repo' 6>&1
        $separators = @($out | Where-Object {
            $_.MessageData -is [System.Management.Automation.HostInformationMessage] -and
            $_.MessageData.Message -eq ('-' * 60)
        })

        $separators.Count | Should -Be 1
    }

    It 'does not expose PlainText or UseColor switches' {
        $parameters = (Get-Command Search-SvnLog).Parameters
        $parameters.ContainsKey('PlainText') | Should -BeFalse
        $parameters.ContainsKey('UseColor') | Should -BeFalse
    }

    It 'includes changed paths in the default colored output' {
        $out = Search-SvnLog -Path 'C:\repo' -Pattern 'fix' 6>&1
        $joined = $out | Out-String
        $joined | Should -Match 'Message:'
        $joined | Should -Match 'Paths:'
        $joined | Should -Match '/trunk/src/App\.cs'
    }

    It 'hides changed paths when -HidePaths is specified' {
        $out = Search-SvnLog -Path 'C:\repo' -Pattern 'fix' -HidePaths 6>&1
        ($out | Out-String) | Should -Not -Match '/trunk/src/App\.cs'
    }

    It 'filters commits by pattern' {
        $out = Search-SvnLog -Path 'C:\repo' -Pattern 'new feature' 6>&1
        ($out | Out-String) | Should -Match 'r\s+102'
        ($out | Out-String) | Should -Not -Match 'r\s+101'
    }

    It 'includes changed paths after the message by default and with -ShowPaths' {
        $defaultOutput = Search-SvnLog -Path 'C:\repo' -Pattern 'fix' 6>&1
        $joined = $defaultOutput | Out-String
        $joined | Should -Match 'Message:'
        $joined | Should -Match 'Paths:'
        $joined | Should -Match '/trunk/src/App\.cs'
        $joined.IndexOf('Message:') | Should -BeLessThan $joined.IndexOf('Paths:')

        $explicitPaths = Search-SvnLog -Path 'C:\repo' -Pattern 'fix' -ShowPaths 6>&1
        ($explicitPaths | Out-String) | Should -Match '/trunk/src/App\.cs'
    }

    It 'suppresses changed paths and labels with -HidePaths' {
        $withoutPaths = Search-SvnLog -Path 'C:\repo' -Pattern 'fix' -HidePaths 6>&1
        ($withoutPaths | Out-String) | Should -Not -Match 'Paths:'
        ($withoutPaths | Out-String) | Should -Not -Match 'Message:'
        ($withoutPaths | Out-String) | Should -Not -Match '/trunk/src/App\.cs'
    }

    It 'returns no matching revisions for a non-matching pattern' {
        $out = Search-SvnLog -Path 'C:\repo' -Pattern 'ZZZ_NO_MATCH' 6>&1
        ($out | Out-String) | Should -Not -Match 'r10'
        ($out | Out-String) | Should -Match 'No commits found matching the specified criteria.'
    }

    It 'returns a plain-text message when the log is empty' {
        $script:sampleXml = '<log />'

        $out = Search-SvnLog -Path 'C:\repo' -Pattern 'fix' 6>&1

        ($out | Out-String) | Should -Match 'No log entries found.'
    }
}
