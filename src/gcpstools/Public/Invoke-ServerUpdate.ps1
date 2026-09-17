function Invoke-ServerUpdate {
<#
.SYNOPSIS
    Starts the installation of available Windows updates on one or more
    servers.

.DESCRIPTION
    For each computer, Invoke-ServerUpdate searches for updates that are
    neither installed nor hidden, downloads them, and installs them through the
    Windows Update Agent.

    The Windows Update Agent refuses to install updates from a remote session,
    so the work is performed by a scheduled task that runs as SYSTEM on the
    target computer. The task writes its result to a JSON file under
    %ProgramData%\gcpstools and is removed once it completes.

    By default the command returns as soon as the installation has been started
    on every computer. Use -Wait to wait for the installation to finish and
    return what was installed, and -AllowReboot to let a computer restart
    itself when the installation requires it.

    Installing updates is a state-changing operation, so the command supports
    -WhatIf and prompts for confirmation unless -Confirm:$false is used.

.PARAMETER ComputerName
    One or more computer names to update. Accepts pipeline input, including
    objects with a Name or ComputerName property.

.PARAMETER AllowReboot
    Lets the computer restart itself after the installation when a reboot is
    required. Without this switch the computer is left running and
    RebootRequired reports whether a restart is still pending.

.PARAMETER Wait
    Waits for the installation to finish and reports the updates that were
    installed instead of returning as soon as it has been started.

.PARAMETER TimeoutMinutes
    How long -Wait waits for a computer before giving up on it and reporting
    TimedOut. The installation keeps running on the computer. Defaults to 60.

.INPUTS
    System.String[]. Computer names can be piped to this command.

.OUTPUTS
    PSCustomObject, one per computer, with these properties:

        ComputerName     Name of the computer.
        Started          Whether the installation was started.
        TimedOut         Whether -Wait gave up before the install finished.
        UpdatesFound     Updates found, or null when -Wait was not used.
        UpdatesInstalled Updates installed, or null when -Wait was not used.
        RebootRequired   Whether a restart is needed to finish the install.
        Updates          Titles of the updates that were installed.
        Error            Error reported by the installation, if any.

.EXAMPLE
    Invoke-ServerUpdate -ComputerName 'APP01'

    Starts the installation on one server after confirming the action.

.EXAMPLE
    Invoke-ServerUpdate -ComputerName 'APP01', 'SQL01' -WhatIf

    Shows which servers would be updated without changing anything.

.EXAMPLE
    Invoke-ServerUpdate -ComputerName 'APP01' -Wait -AllowReboot -Confirm:$false

    Installs the updates, waits for them to finish, and lets the server reboot
    itself if that is required.

.EXAMPLE
    Get-ServerUpdateStatus -ComputerName 'APP01', 'SQL01' -AsObject |
        Where-Object AvailableUpdateCount -gt 0 |
        Invoke-ServerUpdate -Wait

    Updates only the servers that report available updates.

.LINK
    Get-ServerUpdateStatus
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
    [ValidateNotNullOrEmpty()]
    [Alias('Name')]
    [string[]]$ComputerName,

    [switch]$AllowReboot,

    [switch]$Wait,

    [ValidateRange(1, 1440)]
    [int]$TimeoutMinutes = 60
)

begin {
    # Runs on the target computer as SYSTEM; results are written as JSON.
    $installScript = @'
param(
    [Parameter(Mandatory = $true)]
    [string]$ResultPath,

    [switch]$AllowReboot
)

$result = [ordered]@{
    Searched       = 0
    Installed      = 0
    RebootRequired = $false
    ResultCode     = $null
    Updates        = @()
    Error          = $null
}

try {
    $session = New-Object -ComObject 'Microsoft.Update.Session'
    $found = $session.CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0')
    $result.Searched = $found.Updates.Count

    if ($found.Updates.Count -gt 0) {
        $wanted = New-Object -ComObject 'Microsoft.Update.UpdateColl'

        foreach ($update in $found.Updates) {
            if (-not $update.EulaAccepted) {
                $update.AcceptEula()
            }

            $null = $wanted.Add($update)
        }

        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $wanted
        $null = $downloader.Download()

        $ready = New-Object -ComObject 'Microsoft.Update.UpdateColl'

        foreach ($update in $wanted) {
            if ($update.IsDownloaded) {
                $null = $ready.Add($update)
                $result.Updates += $update.Title
            }
        }

        if ($ready.Count -gt 0) {
            $installer = $session.CreateUpdateInstaller()
            $installer.Updates = $ready
            $installed = $installer.Install()

            $result.Installed = $ready.Count
            $result.ResultCode = $installed.ResultCode
            $result.RebootRequired = $installed.RebootRequired
        }
    }
} catch {
    $result.Error = $_.Exception.Message
}

[PSCustomObject]$result | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $ResultPath -Encoding UTF8

if ($AllowReboot -and $result.RebootRequired) {
    Restart-Computer -Force
}
'@

    $remoteScript = {
        param($ScriptText, $AllowReboot, $WaitForCompletion, $TimeoutMinutes)

        $workDir = Join-Path $env:ProgramData 'gcpstools'
        $null = New-Item -ItemType Directory -Path $workDir -Force
        $scriptPath = Join-Path $workDir 'Install-WindowsUpdate.ps1'
        $resultPath = Join-Path $workDir 'Install-WindowsUpdate.json'

        Set-Content -LiteralPath $scriptPath -Value $ScriptText -Encoding UTF8
        Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue

        $taskName = 'gcpstools-InstallWindowsUpdate'
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ResultPath "{1}"' -f $scriptPath, $resultPath

        if ($AllowReboot) {
            $arguments += ' -AllowReboot'
        }

        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $null = Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force
        Start-ScheduledTask -TaskName $taskName

        if (-not $WaitForCompletion) {
            return [PSCustomObject]@{ TimedOut = $false; Result = $null }
        }

        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)

        while ((Get-Date) -lt $deadline -and (Get-ScheduledTask -TaskName $taskName).State -eq 'Running') {
            Start-Sleep -Seconds 10
        }

        if ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') {
            return [PSCustomObject]@{ TimedOut = $true; Result = $null }
        }

        $null = Unregister-ScheduledTask -TaskName $taskName -Confirm:$false

        $installResult = $null

        if (Test-Path -LiteralPath $resultPath) {
            $installResult = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json
        }

        [PSCustomObject]@{ TimedOut = $false; Result = $installResult }
    }
}

process {
    $serverNumber = 0

    foreach ($server in $ComputerName) {
        $serverNumber++

        if (-not $PSCmdlet.ShouldProcess($server, 'Install available Windows updates')) {
            continue
        }

        Write-Progress -Id 1 -Activity 'Installing Windows updates' -Status "$server ($serverNumber of $($ComputerName.Count))" -PercentComplete (100 * ($serverNumber - 1) / $ComputerName.Count)

        try {
            $outcome = Invoke-Command -ComputerName $server -ErrorAction Stop -ScriptBlock $remoteScript -ArgumentList $installScript, $AllowReboot.IsPresent, $Wait.IsPresent, $TimeoutMinutes
        } catch {
            Write-Error "Failed to start the Windows update installation on '$server': $($_.Exception.Message)"

            [PSCustomObject]@{
                ComputerName     = $server
                Started          = $false
                TimedOut         = $false
                UpdatesFound     = $null
                UpdatesInstalled = $null
                RebootRequired   = $null
                Updates          = @()
                Error            = $_.Exception.Message
            }

            continue
        }

        $installResult = $outcome.Result

        if ($outcome.TimedOut) {
            Write-Warning "The Windows update installation on '$server' did not finish within $TimeoutMinutes minute(s); it is still running."
        }

        [PSCustomObject]@{
            ComputerName     = $server
            Started          = $true
            TimedOut         = [bool]$outcome.TimedOut
            UpdatesFound     = $installResult.Searched
            UpdatesInstalled = $installResult.Installed
            RebootRequired   = $installResult.RebootRequired
            Updates          = @($installResult.Updates)
            Error            = $installResult.Error
        }
    }
}

end {
    Write-Progress -Id 1 -Activity 'Installing Windows updates' -Completed
}
}
