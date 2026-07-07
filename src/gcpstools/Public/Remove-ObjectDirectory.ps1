function Remove-ObjectDirectory {
[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$Path = "."
)

# Remove all "obj" directories recursively from the current path
Get-ChildItem -Path $Path -Recurse -Filter obj -Directory | ForEach-Object {
  if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove Directory')) {
    Remove-Item -Path $_.FullName -Force -Recurse -Verbose
  }
}
}
