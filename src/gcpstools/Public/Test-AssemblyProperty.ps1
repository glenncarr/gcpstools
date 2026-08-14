function Test-AssemblyProperty {
	<#
	.SYNOPSIS
		Confirms whether one or more properties exist on a type inside a .NET
		assembly (e.g. the WSDL-generated proxy classes compiled into
		EndOfDay.exe), using reflection.

	.DESCRIPTION
		Loads the specified assembly for reflection and, for each requested
		property name, reports whether it is declared on the given type. This is
		useful for verifying that a service reference was regenerated and that
		newly added WSDL/XSD fields made it into the compiled proxy code.

		For each property it also reports the property type and whether the
		member carries a serialization attribute (DataMemberAttribute,
		XmlElementAttribute, XmlAttributeAttribute or SoapElementAttribute),
		which indicates the property is actually part of the serialized wire
		contract rather than just a plain CLR property.

		The assembly is loaded from a temporary copy so that a running
		application holding a lock on the original file does not block the check.
		Loading is done in a fresh child PowerShell process so repeated calls do
		not accumulate assemblies in the current session.

		Emits one object per requested property with these columns:
			Type, Property, Exists, PropertyType, Serialized, SerializationAttributes

	.PARAMETER AssemblyPath
		Path to the assembly (.exe or .dll) to inspect.

	.PARAMETER TypeName
		Full name of the type to examine (e.g.
		'AMPServiceReference.ListTransmitItemsResponse'). If the namespace is
		omitted the first type whose simple name matches is used. If -TypeName
		is omitted entirely, every type in the assembly is examined (optionally
		scoped with -Namespace).

	.PARAMETER PropertyName
		One or more property names to check for on the type. If omitted, every
		property declared on the type is listed instead (each reported with
		Exists = True).

	.PARAMETER Namespace
		When -TypeName is omitted, restricts the examined types to those in this
		exact namespace. Defaults to 'AMPServiceReference'. Pass an empty string
		('') to examine every type in the assembly.

	.PARAMETER CamelCase
		Converts any SCREAMING_SNAKE_CASE property names supplied via
		-PropertyName to camelCase before matching (e.g. 'UTC_TIMESTAMP_FORMAT'
		becomes 'utcTimestampFormat'). Names not in SCREAMING_SNAKE_CASE are left
		unchanged.

	.PARAMETER Static
		Also search static properties (instance + non-public are searched by
		default).

	.EXAMPLE
		Test-AssemblyProperty `
			'C:\dev\Progistics\trunk\source\Assemblies\EndOfDay.exe' `
			'AMPServiceReference.TransmitItem' `
			'sequence', 'newField'

	.EXAMPLE
		# List every property on the type
		Test-AssemblyProperty $exe 'AMPServiceReference.TransmitItem' |
			Format-Table Property, PropertyType, Serialized -AutoSize

	.EXAMPLE
		# List every property on every proxy type in a namespace
		Test-AssemblyProperty $exe -Namespace 'AMPServiceReference' |
			Format-Table Type, Property, PropertyType -AutoSize

	.EXAMPLE
		# Only report the properties that are missing
		Test-AssemblyProperty $exe 'AMPServiceReference.TransmitItem' $expected |
			Where-Object { -not $_.Exists }

	.EXAMPLE
		# Confirm the new fields are part of the serialized contract
		Test-AssemblyProperty $exe 'AMPServiceReference.TransmitItem' $expected |
			Format-Table Property, Exists, Serialized, SerializationAttributes -AutoSize
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true, Position = 0)]
		[Alias('Path')]
		[string]$AssemblyPath,

		[Parameter(Mandatory = $false, Position = 1)]
		[Alias('Type')]
		[string]$TypeName,

		[Parameter(Mandatory = $false, Position = 2, ValueFromRemainingArguments = $true)]
		[Alias('Property', 'Properties')]
		[string[]]$PropertyName,

		[Parameter(Mandatory = $false)]
		[string]$Namespace = 'AMPServiceReference',

		[switch]$CamelCase,

		[switch]$Static
	)

	$resolved = (Resolve-Path -LiteralPath $AssemblyPath -ErrorAction Stop).ProviderPath

	# Convert any SCREAMING_SNAKE_CASE property names supplied by the caller to
	# camelCase (e.g. 'UTC_TIMESTAMP_FORMAT' -> 'utcTimestampFormat') so callers
	# can pass constant-style names and still match the generated proxy members.
	if ($CamelCase -and $PropertyName) {
		$PropertyName = $PropertyName | ForEach-Object {
			if ($_ -cmatch '^[A-Z0-9]+(_[A-Z0-9]+)*$') {
				$segments = $_ -split '_'
				$camel = $segments[0].ToLowerInvariant()
				for ($i = 1; $i -lt $segments.Count; $i++) {
					$segment = $segments[$i]
					if ($segment.Length -gt 0) {
						$camel += $segment.Substring(0, 1).ToUpperInvariant() + $segment.Substring(1).ToLowerInvariant()
					}
				}
				$camel
			}
			else {
				$_
			}
		}
	}

	# Run the reflection in a child process so we can load from a temp copy
	# (avoids file locks from a running app) without polluting the current
	# session with a permanently loaded assembly.
	$worker = {
		param($AssemblyPath, $TypeName, $PropertyNamesCsv, $NamespaceFilter, $IncludeStatic)

		$propertyNames = if ([string]::IsNullOrEmpty($PropertyNamesCsv)) {
			@()
		}
		else {
			$PropertyNamesCsv -split "`n"
		}

		$tempPath = [System.IO.Path]::Combine(
			[System.IO.Path]::GetTempPath(),
			[System.IO.Path]::GetRandomFileName() + [System.IO.Path]::GetExtension($AssemblyPath))

		Copy-Item -LiteralPath $AssemblyPath -Destination $tempPath -Force

		try {
			$asm = [System.Reflection.Assembly]::LoadFrom($tempPath)

			# GetTypes() throws ReflectionTypeLoadException if any type fails to
			# load; recover the ones that did load so a single bad type does not
			# abort the whole listing.
			$getLoadableTypes = {
				param($assembly)
				try {
					$assembly.GetTypes()
				}
				catch [System.Reflection.ReflectionTypeLoadException] {
					$_.Exception.Types | Where-Object { $null -ne $_ }
				}
			}

			# Resolve the set of types to examine. When -TypeName is supplied we
			# look at just that type; otherwise we examine every type (optionally
			# scoped to -Namespace).
			$types = @()
			if (-not [string]::IsNullOrEmpty($TypeName)) {
				$type = $asm.GetType($TypeName, $false, $true)
				if ($null -eq $type) {
					$type = (& $getLoadableTypes $asm) |
						Where-Object { $_.Name -eq $TypeName -or $_.FullName -eq $TypeName } |
						Select-Object -First 1
				}
				if ($null -eq $type) {
					throw "Type '$TypeName' was not found in '$AssemblyPath'."
				}
				$types = @($type)
			}
			else {
				$types = & $getLoadableTypes $asm
				if (-not [string]::IsNullOrEmpty($NamespaceFilter)) {
					$types = $types | Where-Object { $_.Namespace -eq $NamespaceFilter }
				}
				$types = $types | Sort-Object FullName
			}

			$flags = [System.Reflection.BindingFlags]::Instance -bor
					 [System.Reflection.BindingFlags]::Public -bor
					 [System.Reflection.BindingFlags]::NonPublic
			if ($IncludeStatic) {
				$flags = $flags -bor [System.Reflection.BindingFlags]::Static
			}

			$serializationAttributeNames = @(
				'DataMemberAttribute',
				'XmlElementAttribute',
				'XmlAttributeAttribute',
				'SoapElementAttribute'
			)

			# When no property names are supplied, list every property declared on
			# the type (sorted) instead of checking specific ones.
			$listAll = ($propertyNames.Count -eq 0)

			foreach ($type in $types) {
				# Build a name -> PropertyInfo map. Using GetProperties() and
				# grouping avoids GetProperty(name, flags) throwing an ambiguous
				# match exception on types with overloaded indexers (e.g. an
				# 'Item' property with multiple signatures).
				$allProps = $type.GetProperties($flags)
				$propMap = @{}
				foreach ($p in $allProps) {
					if (-not $propMap.ContainsKey($p.Name)) {
						$propMap[$p.Name] = $p
					}
				}

				$namesForType = if ($listAll) {
					$allProps | ForEach-Object { $_.Name } | Sort-Object -Unique
				}
				else {
					$propertyNames
				}

				foreach ($name in $namesForType) {
					$prop = $propMap[$name]

					$serializeAttrs = @()
					if ($null -ne $prop) {
						$serializeAttrs = $prop.GetCustomAttributes($false) |
							ForEach-Object { $_.GetType().Name } |
							Where-Object { $serializationAttributeNames -contains $_ }
					}

					[pscustomobject]@{
						Type                    = $type.FullName
						Property                = $name
						Exists                  = ($null -ne $prop)
						PropertyType            = if ($prop) { $prop.PropertyType.FullName } else { $null }
						Serialized              = ($serializeAttrs.Count -gt 0)
						SerializationAttributes = ($serializeAttrs -join ', ')
					}
				}
			}
		}
		finally {
			Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
		}
	}

	# Join names with newline so they survive the process boundary as a single arg.
	$namesCsv = ($PropertyName -join "`n")

	$pwsh = (Get-Process -Id $PID).Path
	& $pwsh -NoProfile -NonInteractive -Command $worker -args $resolved, $TypeName, $namesCsv, $Namespace, ([bool]$Static)

	Write-Verbose "Parameter values:"
	Write-Verbose "  AssemblyPath : $resolved"
	Write-Verbose "  TypeName     : $(if ([string]::IsNullOrEmpty($TypeName)) { '<all types>' } else { $TypeName })"
	Write-Verbose "  PropertyName : $(if ($PropertyName) { $PropertyName -join ', ' } else { '<all properties>' })"
	Write-Verbose "  Namespace    : $(if ([string]::IsNullOrEmpty($Namespace)) { '<all namespaces>' } else { $Namespace })"
	Write-Verbose "  Static       : $([bool]$Static)"
}
