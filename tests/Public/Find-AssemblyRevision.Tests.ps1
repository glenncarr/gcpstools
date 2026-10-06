Describe 'Find-AssemblyRevision' {
	BeforeAll {
		. "$PSScriptRoot\..\..\src\gcpstools\Public\Find-AssemblyRevision.ps1"

		function svn { }

		$script:logXml = @'
<log>
  <logentry revision="107"><author>newer</author><date>2026-02-07T10:00:00.000000Z</date><msg>changed away</msg></logentry>
  <logentry revision="106"><author>alice</author><date>2026-02-06T10:00:00.000000Z</date><msg>still matching</msg></logentry>
  <logentry revision="105"><author>bob</author><date>2026-02-05T10:00:00.000000Z</date><msg>set value</msg></logentry>
  <logentry revision="104"><author>older</author><date>2026-02-04T10:00:00.000000Z</date><msg>previous value</msg></logentry>
</log>
'@
	}

	BeforeEach {
		Mock Write-Progress { }

		$script:revisionBySvn = @{
			'107' = '<versions><assemblies><assembly name="Example.Assembly"><revision patch="8">2</revision></assembly></assemblies></versions>'
			'106' = '<versions><assemblies><assembly name="Example.Assembly"><revision patch="7">1</revision></assembly></assemblies></versions>'
			'105' = '<versions><assemblies><assembly name="Example.Assembly"><revision patch="6">1</revision></assembly></assemblies></versions>'
			'104' = '<versions><assemblies><assembly name="Example.Assembly"><revision patch="5">0</revision></assembly></assemblies></versions>'
		}

		Mock svn {
			$global:LASTEXITCODE = 0
			if ($args[0] -eq 'log') {
				$script:logXml
			}
			else {
				$revisionIndex = [array]::IndexOf([string[]] $args, '-r')
				$revision = [string] $args[$revisionIndex + 1]
				$script:revisionBySvn[$revision]
			}
		}
	}

	It 'returns the newest matching interval and the revision that changed away from it' {
		$result = Find-AssemblyRevision -Path 'https://svn.example.com/repos/project/version.xml' `
			-AssemblyName 'Example.Assembly' -RevisionValue 1

		$result.AssemblyName | Should -Be 'Example.Assembly'
		$result.RevisionValue | Should -Be 1
		$result.PatchWhenSet | Should -Be '6'
		$result.SetInSvnRevision | Should -Be 105
		$result.SetBy | Should -Be 'bob'
		$result.SetMessage | Should -Be 'set value'
		$result.LastMatchingSvnRevision | Should -Be 106
		$result.ChangedInSvnRevision | Should -Be 107
		$result.ChangedDateUtc.ToString('o') | Should -Be '2026-02-07T10:00:00.0000000Z'
		$result.RepositoryUrl | Should -Be 'https://svn.example.com/repos/project/version.xml'
		Should -Invoke Write-Progress -ParameterFilter { $Status -like 'Checked * entries; current SVN revision *' } -Times 4 -Exactly
		Should -Invoke Write-Progress -ParameterFilter { $Completed } -Times 1 -Exactly
	}

	It 'warns and returns no result when no snapshot matches' {
		$warnings = @()
		$result = Find-AssemblyRevision -Path 'https://svn.example.com/repos/project/version.xml' `
			-AssemblyName 'Example.Assembly' -RevisionValue 9 -WarningVariable warnings

		$result | Should -BeNullOrEmpty
		$warnings | Should -HaveCount 1
		$warnings[0] | Should -Match 'No committed snapshot has revision value 9'
		Should -Invoke Write-Progress -ParameterFilter { $Completed } -Times 1 -Exactly
	}

	It 'clears progress when SVN fails during the search' {
		Mock svn {
			$global:LASTEXITCODE = 1
			'svn failed'
		}

		{ Find-AssemblyRevision -Path 'https://svn.example.com/repos/project/version.xml' `
			-AssemblyName 'Example.Assembly' -RevisionValue 1 } | Should -Throw '*SVN failed*'
		Should -Invoke Write-Progress -ParameterFilter { $Completed } -Times 1 -Exactly
	}

	It 'throws when the requested SVN command is unavailable' {
		{ Find-AssemblyRevision -Path '.\version.xml' -AssemblyName 'Example.Assembly' `
			-RevisionValue 1 -SvnPath 'missing-svn-client' } | Should -Throw '*was not found*'
	}
}