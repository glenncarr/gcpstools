function Get-SvnLastRevision {
<#
.SYNOPSIS
    Returns the SVN revision number of the most recent commit for a file or path.

.PARAMETER Path
    The file or directory path to query. Defaults to the current directory.

.EXAMPLE
    Get-SvnLastRevision.ps1 -Path .\src\MyFile.cs

.EXAMPLE
    Get-SvnLastRevision.ps1
#>
[CmdletBinding()]
[OutputType([int])]
param(
    [Parameter(Position = 0)]
    [string]$Path = "."
)

$stdout = svn info --xml $Path 2>$null

if ($LASTEXITCODE -ne 0) {
    Write-Error "svn info failed for '$Path'."
    return
}

[xml]$info = $stdout -join "`n"

[int]$info.info.entry.commit.revision
}
