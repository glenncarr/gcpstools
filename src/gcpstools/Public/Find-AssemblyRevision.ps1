function Find-AssemblyRevision {
	<#
	.SYNOPSIS
		Finds the most recent SVN history interval with a given assembly revision value.

	.DESCRIPTION
		Reads committed snapshots of version.xml, newest first. Reports when the requested
		value was set and when it changed again. Uncommitted working-copy changes are ignored.
		Requires the Subversion command-line client and repository access.

	.PARAMETER Path
		Local working-copy path to version.xml, or its HTTP/HTTPS SVN repository URL.

	.PARAMETER AssemblyName
		The exact, case-sensitive assembly name to search for.

	.PARAMETER RevisionValue
		The revision value to find.

	.PARAMETER SvnPath
		Path or command name for the Subversion command-line client. Defaults to 'svn'.

	.PARAMETER ChunkSize
		Number of history entries fetched per SVN log request, newest first. The search
		stops as soon as the matching interval is found, so recent values are located
		without reading the entire history.

	.EXAMPLE
		Find-AssemblyRevision -Path '.\version.xml' -AssemblyName 'Example.Assembly' -RevisionValue 1

	.EXAMPLE
		Find-AssemblyRevision -Path 'https://svn.example.com/repos/project/Source/version.xml' -AssemblyName 'Example.Assembly' -RevisionValue 1
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true, Position = 0)]
		[string] $Path,
		[Parameter(Mandatory = $true, Position = 1)]
		[string] $AssemblyName,
		[Parameter(Mandatory = $true, Position = 2)]
		[ValidateRange(0, 2147483647)]
		[int] $RevisionValue,
		[string] $SvnPath = 'svn',
		[ValidateRange(1, 2147483647)]
		[int] $ChunkSize = 25
	)

	$ErrorActionPreference = 'Stop'

	if (-not (Get-Command -Name $SvnPath -ErrorAction SilentlyContinue)) {
		throw "SVN client '$SvnPath' was not found. Install the command-line client or supply -SvnPath."
	}

	function Invoke-SvnXml {
		param([string[]] $Arguments)

		$output = & $SvnPath @Arguments
		if ($LASTEXITCODE -ne 0) {
			throw "SVN failed (exit code $LASTEXITCODE): $($Arguments -join ' ')"
		}
		return [xml] ($output -join "`n")
	}

	[uri] $repositoryUri = $null
	if ([uri]::TryCreate($Path, [UriKind]::Absolute, [ref] $repositoryUri) -and
		$repositoryUri.Scheme -in @('http', 'https')) {
		$url = $Path
	}
	else {
		Write-Verbose "Resolving SVN repository URL for '$Path'."
		$info = Invoke-SvnXml -Arguments @('info', '--xml', '--non-interactive', '--', $Path)
		$url = [string] $info.info.entry.url
	}
	if ([string]::IsNullOrWhiteSpace($url)) {
		throw "No SVN URL was returned for '$Path'."
	}

	$target = "${url}@HEAD"
	Write-Verbose "Searching SVN history for '$url' in chunks of $ChunkSize, newest first."
	$firstMatch = $null
	$lastMatch = $null
	$newerEntry = $null
	$changedAway = $null
	$patch = $null
	$checkedCount = 0
	$done = $false
	$upperBound = 'HEAD'

	try {
		while (-not $done -and $null -ne $upperBound) {
			Write-Verbose "Fetching up to $ChunkSize history entries from SVN revision $upperBound downward."
			$log = Invoke-SvnXml -Arguments @('log', '--xml', '--non-interactive', '-r', "${upperBound}:0", '--limit', [string] $ChunkSize, '--', $target)
			$entries = @($log.log.logentry | Where-Object { $null -ne $_ })
			if ($entries.Count -eq 0) {
				break
			}

			foreach ($entry in $entries) {
				$checkedCount++
				Write-Progress -Id 1 -Activity 'Searching SVN assembly revision history' `
					-Status "Checked $checkedCount entries; current SVN revision $($entry.revision)"
				Write-Verbose "Checking entry $checkedCount : SVN revision $($entry.revision) ($($entry.date))."
				$snapshot = Invoke-SvnXml -Arguments @('cat', '--non-interactive', '-r', [string] $entry.revision, '--', $target)
				$assembly = $snapshot.versions.assemblies.assembly |
					Where-Object { $_.GetAttribute('name') -ceq $AssemblyName } |
					Select-Object -First 1
				$revision = if ($null -ne $assembly) { $assembly.SelectSingleNode('revision') } else { $null }
				$matches = $null -ne $revision -and $revision.InnerText.Trim() -ceq [string] $RevisionValue

				if ($null -eq $revision) {
					Write-Verbose "No revision element found for '$AssemblyName' in this snapshot."
				}
				else {
					Write-Verbose "Assembly revision value: $($revision.InnerText.Trim()); patch: $($revision.GetAttribute('patch'))."
				}

				if ($matches) {
					Write-Verbose "Match found in SVN revision $($entry.revision)."
					if ($null -eq $lastMatch) {
						$lastMatch = $entry
						$changedAway = $newerEntry
					}
					$firstMatch = $entry
					$patch = $revision.GetAttribute('patch')
				}
				elseif ($null -ne $firstMatch) {
					Write-Verbose "Reached the preceding value in SVN revision $($entry.revision); the matching interval starts at SVN revision $($firstMatch.revision)."
					$done = $true
					break
				}
				$newerEntry = $entry
			}

			if ($done -or $entries.Count -lt $ChunkSize) {
				break
			}

			$oldestRevision = [long] $entries[-1].revision
			$upperBound = if ($oldestRevision -gt 0) { [string] ($oldestRevision - 1) } else { $null }
		}
	}
	finally {
		Write-Progress -Id 1 -Activity 'Searching SVN assembly revision history' -Completed
	}

	Write-Verbose "Search complete. Checked $checkedCount history entries."
	if ($null -eq $firstMatch) {
		Write-Warning "No committed snapshot has revision value $RevisionValue for '$AssemblyName'."
		return
	}

	[pscustomobject] @{
		AssemblyName = $AssemblyName
		RevisionValue = $RevisionValue
		PatchWhenSet = $patch
		SetInSvnRevision = [long] $firstMatch.revision
		SetDateUtc = [datetimeoffset]::Parse([string] $firstMatch.date).UtcDateTime
		SetBy = [string] $firstMatch.author
		SetMessage = [string] $firstMatch.msg
		LastMatchingSvnRevision = [long] $lastMatch.revision
		ChangedInSvnRevision = if ($null -ne $changedAway) { [long] $changedAway.revision } else { $null }
		ChangedDateUtc = if ($null -ne $changedAway) { [datetimeoffset]::Parse([string] $changedAway.date).UtcDateTime } else { $null }
		RepositoryUrl = $url
	}
}