function Search-AppEventLog {
<#
.SYNOPSIS
    Searches the Application event log for entries matching a string.

.PARAMETER SearchString
    Text to match against event Message or Source (wildcard).

.PARAMETER MaxEvents
    Maximum number of most-recent entries to scan. Default: 1000.

.EXAMPLE
    Search-AppEventLog -SearchString 'error'

.EXAMPLE
    Search-AppEventLog -SearchString 'MyApp' -MaxEvents 500
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$SearchString,

    [Parameter(Mandatory=$false)]
    [int]$MaxEvents = 1000
)

Add-Type -AssemblyName System.Core

$log = New-Object System.Diagnostics.EventLog("Application")
$entries = $log.Entries

$results = @()
$count = [Math]::Min($MaxEvents, $entries.Count)
$startIndex = $entries.Count - $count

for ($i = $entries.Count - 1; $i -ge $startIndex; $i--) {
    $entry = $entries[$i]
    if ($entry.Message -like "*$SearchString*" -or $entry.Source -like "*$SearchString*") {
        $results += [PSCustomObject]@{
            TimeGenerated = $entry.TimeGenerated
            Source        = $entry.Source
            EntryType     = $entry.EntryType
            EventID       = $entry.InstanceId
            Message       = $entry.Message
        }
    }
}

if ($results.Count -eq 0) {
    Write-Host "No matching events found for '$SearchString' in the last $count entries."
} else {
    Write-Host "Found $($results.Count) matching event(s):"
    $results | Format-Table -AutoSize -Wrap
}
}
