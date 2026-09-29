# gcpstools

Glenn's custom PowerShell tools module.

## Installation

Install from the [PowerShell Gallery](https://www.powershellgallery.com/packages/gcpstools):

```powershell
Install-Module -Name gcpstools -Scope CurrentUser
```

`-Scope CurrentUser` installs into your user profile and does not require an
elevated (admin) session. Omit it to install for all users (requires admin).

## Usage

```powershell
# Import the module
Import-Module ./src/gcpstools

# Run tests
./build.ps1 -Test
```

## Get-ServerUpdateStatus

`Get-ServerUpdateStatus` reports the most recently installed Windows update,
how many updates are still available, whether an installation is running right
now, and whether the computer is waiting for a restart. Computer names are
white and VM state is colored by state; the status is green when a computer is
current, orange when updates are available, cyan while updates are being
installed, yellow while a restart is pending, and red when the status could not
be retrieved. Each computer is reported through a progress bar and printed as
soon as it is checked, since the queries can take a while:

```powershell
Get-ServerUpdateStatus -ComputerName 'APP01', 'SQL01'
```

Add `-IncludeVM` on a Hyper-V host to also report each of its VMs. Computers
without Hyper-V are still reported:

```powershell
Get-ServerUpdateStatus -ComputerName 'HV01' -IncludeVM
```

```text
HV01
  Windows Update: KB5126043 installed 2026-09-17; no updates available
  APP01 - Running
    Windows Update: KB5126043 installed 2026-08-13; 3 updates available
  TEST01 - Off
    Windows Update: not running
```

Use `-AsObject` to get one object per computer (and per VM) for filtering or
reporting:

```powershell
Get-ServerUpdateStatus -ComputerName 'HV01' -IncludeVM -AsObject |
   Where-Object AvailableUpdateCount -gt 0
```

The `Installing` property tells you which computers are busy installing updates
(the Windows Update Agent installer is busy, or an `Invoke-ServerUpdate` run is
still going), and `RebootPending` which ones are waiting to be restarted:

```powershell
Get-ServerUpdateStatus -ComputerName 'APP01', 'SQL01' -AsObject |
   Where-Object RebootPending
```

Querying a computer requires CIM access and PowerShell remoting; unreachable
computers are reported as unavailable, and `-Verbose` shows why.

## Invoke-ServerUpdate

`Invoke-ServerUpdate` installs the updates that `Get-ServerUpdateStatus`
reports. Because the Windows Update Agent refuses to install updates from a
remote session, the install runs in a scheduled task as SYSTEM on each target
and its result is written to `%ProgramData%\gcpstools`.

```powershell
Invoke-ServerUpdate -ComputerName 'APP01', 'SQL01'
```

The command prompts before touching each server; use `-Confirm:$false` to skip
the prompt or `-WhatIf` to see what would happen. By default it returns as soon
as the installation has started. Use `-Wait` to wait for the result, and
`-AllowReboot` to let a server restart itself when the update requires it:

```powershell
Invoke-ServerUpdate -ComputerName 'APP01' -Wait -AllowReboot -Confirm:$false
```

Both commands compose, so only the servers that need updates are touched:

```powershell
Get-ServerUpdateStatus -ComputerName 'APP01', 'SQL01' -AsObject |
   Where-Object AvailableUpdateCount -gt 0 |
   Invoke-ServerUpdate -Wait
```

## Invoke-ServerCommand

`Invoke-ServerCommand` opens a PowerShell remoting session for each server,
executes the same script block, returns its output, and closes the session.
Pipe computer names to the command or provide them with `-ComputerName`:

```powershell
'SERVER01', 'SERVER02', 'SERVER03', 'SERVER04' |
   Invoke-ServerCommand -ScriptBlock {
      Remove-StaleDotNetRuntime -WhatIf -Verbose
   }
```

Use `-ArgumentList` for values consumed by parameters in the script block, and
use `-WhatIf` to skip remote execution.

## Get-SlackChannelHistory

`Get-SlackChannelHistory` reads messages from a Slack channel over a date range.
It authenticates with a Slack token supplied via `-Token` or the `SLACK_TOKEN`
environment variable. See `Get-Help Get-SlackChannelHistory -Full` for the
complete setup walkthrough.

### Creating the Slack app from a manifest

To avoid adding OAuth scopes by hand, the cmdlet can emit a ready-made Slack app
manifest. Use one switch, on its own:

```powershell
# User-token (xoxp-) app — reads channels the running user already belongs to
Get-SlackChannelHistory -AppManifest | Set-Content slack-app-manifest.yaml

# Bot-token (xoxb-) app — one shared app invited into channels
Get-SlackChannelHistory -BotManifest | Set-Content slack-app-manifest-bot.yaml
```

Copies of both manifests are also checked into the repository root
(`slack-app-manifest.yaml` and `slack-app-manifest-bot.yaml`).

Then, at <https://api.slack.com/apps>:

1. Click **Create New App** → **From an app manifest**.
2. Pick your workspace, paste the YAML (or upload the saved file), and create
   the app.
3. Open **OAuth & Permissions** → **Install to Workspace** → **Allow**.
4. For the user manifest, copy the **User OAuth Token** (`xoxp-`). For the bot
   manifest, copy the **Bot User OAuth Token** (`xoxb-`) and invite the app to
   each private channel with `/invite @Channel History Reader`.
5. Supply the token via `-Token` or `SLACK_TOKEN`. No Redirect URL is required.

Both switches only print text; they never contact Slack and cannot be combined
with the history-retrieval parameters.

## Add-SvnUnversioned / Remove-SvnUnversioned

`Add-SvnUnversioned` runs `svn add` on every file reported as unversioned
(`?`) by `svn status`; `Remove-SvnUnversioned` deletes them instead. Both
accept a pipeline of paths and an `-Exclude` list of wildcard patterns, and
both support `-WhatIf`:

```powershell
Add-SvnUnversioned -Path . -Exclude '*.log', '*.tmp'
Remove-SvnUnversioned -Path . -Exclude '*.log', '*.tmp' -WhatIf
```

## Compare-DirectoryContentParallel

`Compare-DirectoryContentParallel` hashes and compares files between a source
and destination directory using parallel threads. Requires PowerShell 7+.

```powershell
Compare-DirectoryContentParallel -Source C:\client1\App -Destination C:\client2\App
```

Use `-FileList` to check a specific set of relative paths instead of scanning
recursively, and `-ShowAll` (alias `-IncludeMatch`) to include files that
already match instead of only differences.

## Compare-WsdlDirectory

`Compare-WsdlDirectory` compares WSDL/XSD service contracts between two
directories and reports structural differences (messages, operations, types,
fields). Requires PowerShell 7+.

```powershell
Compare-WsdlDirectory 'C:\client1\WCFServices' 'C:\client2\WCFServices' |
    Where-Object Category -eq 'Field'
```

## Find-FancyQuote

`Find-FancyQuote` scans files for non-ASCII quote characters (smart quotes,
primes, guillemets) and reports the line, column, character, and an ASCII
replacement suggestion:

```powershell
Get-ChildItem -Recurse -Filter *.xml | Find-FancyQuote -Encoding windows-1252
```

## Find-InvalidUtf8

`Find-InvalidUtf8` scans files for byte sequences that are not valid UTF-8
(per RFC 3629) and reports the offset, line, column, and a snippet of
surrounding text:

```powershell
Get-ChildItem -Recurse -Filter *.cs | Find-InvalidUtf8
```

## Format-DirectoryDiff

`Format-DirectoryDiff` applies ANSI color to directory-comparison output for
terminal display (green = match, yellow = missing, red = mismatch, magenta =
corruption). Requires PowerShell 7+.

```powershell
Compare-DirectoryContent -Ref C:\old -Diff C:\new | Format-DirectoryDiff
```

## Get-InternalsVisibleToAttribute

`Get-InternalsVisibleToAttribute` reads a .NET assembly's
`InternalsVisibleTo` attributes, filtered by a wildcard pattern for the
friend assembly name:

```powershell
Get-InternalsVisibleToAttribute -Path .\MyLibrary.dll -FriendAssemblyNamePattern '*Tests*'
```

## Get-RecentSvnFiles

`Get-RecentSvnFiles` lists files committed to SVN within a time window
(added, modified, or replaced) as full local working-copy paths. Requires the
`svn` CLI. Output pipes directly into other tools such as `Find-InvalidUtf8`:

```powershell
Get-RecentSvnFiles -Hours 72 -Path .\Public | Find-InvalidUtf8
```

## Get-SvnLastRevision

`Get-SvnLastRevision` returns the SVN revision number of the most recent
commit for a file or path. Requires the `svn` CLI.

```powershell
Get-SvnLastRevision -Path .\src\MyFile.cs
```

## Update-DotNetRuntime

`Update-DotNetRuntime` updates installed .NET shared frameworks to the latest
patch for each installed major/minor band. It uses Microsoft's release metadata,
verifies each installer download with the published SHA-512 hash, and skips
end-of-life channels unless `-IncludeEol` is specified. Run it elevated because
the runtime installers require administrator rights:

```powershell
Update-DotNetRuntime -Band '8.0', '10.0' -CleanupStale -KeepVersions 2 -Confirm:$false
```

`-CleanupStale` hands the cleanup to `Remove-StaleDotNetRuntime`, so it uses the
.NET Uninstall Tool unless `-KeepVersions` is greater than 1.

Preview the changes first with `-WhatIf`. To run the update against several
servers through PowerShell remoting, make sure this module is installed on every
target and use `Invoke-ServerCommand`:

```powershell
'APP01', 'SQL01' | Invoke-ServerCommand -ScriptBlock {
   Update-DotNetRuntime -WhatIf -Verbose
}
```

## Out-Diff

`Out-Diff` colors and displays unified-diff-format text for visual comparison
in the terminal (cyan = index header, green = additions, red = deletions):

```powershell
svn diff | Out-Diff
```

## Remove-ObjectDirectory

`Remove-ObjectDirectory` recursively removes all `obj` build directories
under a path. Supports `-WhatIf` and `-Confirm`:

```powershell
Remove-ObjectDirectory -Path C:\MyProject -WhatIf
```

## Remove-StaleDotNetRuntime

`Remove-StaleDotNetRuntime` removes superseded .NET shared-framework
versions, keeping the newest patch in each major.minor band. Requires an
elevated session and supports `-WhatIf`/`-Confirm`:

```powershell
Remove-StaleDotNetRuntime -Confirm:$false
```

By default the removal is delegated to the
[.NET Uninstall Tool](https://learn.microsoft.com/dotnet/core/additional-tools/uninstall-tool)
(`dotnet-core-uninstall --all-lower-patches`), which uninstalls each version
through its original installer instead of deleting files, and keeps versions
that Visual Studio may need. The tool is installed with winget when it is
missing. Add `-IncludeSdk` to also remove superseded SDKs:

```powershell
Remove-StaleDotNetRuntime -IncludeSdk -Confirm:$false
```

The tool's filter options are mutually exclusive, so it cannot express every
request. The original file-system removal is used instead when `-Path` or
`-Band` is given, when `-KeepVersions` is greater than 1, or when the tool is
unavailable or fails:

```powershell
Remove-StaleDotNetRuntime -Band '8.0' -KeepVersions 2 -Confirm:$false
```

## Remove-StalePackageVersion

`Remove-StalePackageVersion` removes NuGet package version directories older
than a threshold, based on `LastWriteTime`. Supports `-WhatIf`/`-Confirm`:

```powershell
Remove-StalePackageVersion -RootPath C:\packages -OlderThanDays 30 -WhatIf
```

## Search-AppEventLog

`Search-AppEventLog` searches the Windows Application event log for entries
whose message or source matches a wildcard pattern:

```powershell
Search-AppEventLog -SearchString '*error*' -MaxEvents 500
```

## Search-SvnLog

`Search-SvnLog` searches SVN commit history for a pattern in commit messages,
with optional file filtering. Patterns are regex (case-insensitive) by
default; use `-SimpleMatch` for a literal search:

```powershell
Search-SvnLog -Pattern 'bug fix' -IncludeFile 'SettingsService\.cs' -Limit 100
```

## Set-RegexHistorySearch

`Set-RegexHistorySearch` registers a PSReadLine key handler (default
`Ctrl+Alt+r`) that opens an interactive, regex-capable command-history
search, deduplicated across sessions. Typically called once from your
PowerShell profile:

```powershell
Set-RegexHistorySearch -Key 'F9'
```

## Test-AssemblyProperty

`Test-AssemblyProperty` uses reflection to confirm whether one or more
properties exist on a .NET type in an assembly, reporting the property type
and any serialization attributes found:

```powershell
Test-AssemblyProperty $exe 'AMPServiceReference.TransmitItem' 'sequence', 'newField' |
    Format-Table Property, Exists, Serialized
```

## Test-Xml

`Test-Xml` validates an XML file against an XSD schema and reports validation
errors with their severity and line number:

```powershell
Test-Xml -XmlPath .\document.xml -XsdUrl 'http://myserver/schema.xsd' -TargetNamespace 'urn:myorg:myschema'
```

