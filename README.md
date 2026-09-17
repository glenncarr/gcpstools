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

