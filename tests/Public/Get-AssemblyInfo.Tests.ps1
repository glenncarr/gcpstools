Describe 'Get-AssemblyInfo' {
	BeforeAll {
		. "$PSScriptRoot\..\..\src\gcpstools\Public\Get-AssemblyInfo.ps1"
		$script:assemblyPath = [System.Management.Automation.PSObject].Assembly.Location
	}

	It 'returns assembly identity and useful file metadata without loading the assembly' {
		$expected = [System.Reflection.AssemblyName]::GetAssemblyName($script:assemblyPath)
		$file = Get-Item -LiteralPath $script:assemblyPath
		$result = Get-AssemblyInfo -Path $script:assemblyPath

		$result.Path | Should -Be $file.FullName
		$result.Name | Should -Be $expected.Name
		$result.Version.ToString() | Should -Be $expected.Version.ToString()
		$result.FullName | Should -Be $expected.FullName
		$result.PublicKeyToken | Should -Be ([System.BitConverter]::ToString($expected.GetPublicKeyToken()).Replace('-', '').ToLowerInvariant())
		$result.Length | Should -Be $file.Length
		$result.LastWriteTimeUtc | Should -Be $file.LastWriteTimeUtc
		$result.FileVersion | Should -Be ([System.Diagnostics.FileVersionInfo]::GetVersionInfo($script:assemblyPath).FileVersion)
	}

	It 'accepts file objects through their FullName property' {
		$result = Get-Item -LiteralPath $script:assemblyPath | Get-AssemblyInfo

		$result.Path | Should -Be $script:assemblyPath
		$result.Name | Should -Be ([System.Reflection.AssemblyName]::GetAssemblyName($script:assemblyPath).Name)
	}

	It 'throws when the path is not a managed assembly' {
		{ Get-AssemblyInfo -Path $PSCommandPath } | Should -Throw
	}
}