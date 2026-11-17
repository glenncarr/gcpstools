function Get-AssemblyInfo {
	<#
	.SYNOPSIS
		Displays identity and file metadata for a .NET assembly.

	.DESCRIPTION
		Reads the assembly identity without loading the assembly into the current
		PowerShell process. Also reports useful file version and file-system metadata.

	.PARAMETER Path
		Path to one or more managed .dll or .exe files. File objects can be piped
		in by their FullName property.

	.EXAMPLE
		Get-AssemblyInfo -Path '.\MyLibrary.dll' | Format-List

	.EXAMPLE
		Get-ChildItem .\bin -Filter *.dll | Get-AssemblyInfo |
			Format-Table Name, Version, FileVersion, ProcessorArchitecture
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
		[Alias('AssemblyPath', 'LiteralPath', 'FullName')]
		[ValidateNotNullOrEmpty()]
		[string[]] $Path
	)

	process {
		foreach ($assemblyPath in $Path) {
			$resolvedPath = (Resolve-Path -LiteralPath $assemblyPath -ErrorAction Stop).ProviderPath
			$file = Get-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop
			if ($file -isnot [System.IO.FileInfo]) {
				throw "Path '$assemblyPath' is not a file."
			}

			$assemblyName = [System.Reflection.AssemblyName]::GetAssemblyName($resolvedPath)
			$tokenBytes = $assemblyName.GetPublicKeyToken()
			$publicKeyToken = if ($tokenBytes -and $tokenBytes.Length -gt 0) {
				[System.BitConverter]::ToString($tokenBytes).Replace('-', '').ToLowerInvariant()
			}
			else {
				$null
			}
			$fileVersionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($resolvedPath)

			[pscustomobject][ordered]@{
				Path                   = $resolvedPath
				Name                   = $assemblyName.Name
				Version                = $assemblyName.Version
				CultureName            = $assemblyName.CultureName
				PublicKeyToken         = $publicKeyToken
				IsStrongNameSigned     = ($null -ne $publicKeyToken)
				ProcessorArchitecture = $assemblyName.ProcessorArchitecture.ToString()
				ContentType            = $assemblyName.ContentType.ToString()
				FullName               = $assemblyName.FullName
				FileVersion            = $fileVersionInfo.FileVersion
				ProductVersion         = $fileVersionInfo.ProductVersion
				FileDescription        = $fileVersionInfo.FileDescription
				ProductName            = $fileVersionInfo.ProductName
				CompanyName            = $fileVersionInfo.CompanyName
				OriginalFilename      = $fileVersionInfo.OriginalFilename
				Length                 = $file.Length
				LastWriteTimeUtc       = $file.LastWriteTimeUtc
			}
		}
	}
}