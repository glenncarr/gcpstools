function Watch-ServerUpgrade {
<#
.SYNOPSIS
    Monitors a remote Windows upgrade across reboot cycles.
.DESCRIPTION
    Waits for SMB, WinRM, and RDP ports to disconnect, then polls management ports
    and CIM until the reported OS build reaches the target or the timeout expires.
    Without ExpectedBuild, returns the first OS details retrieved after recovery;
    recovery alone does not confirm that an upgrade succeeded.
    No Windows release is assumed. Start before the first reboot, or while the
    target is offline. An older build during setup does not end monitoring.
.PARAMETER ComputerName
    The Windows computer to monitor.
.PARAMETER ExpectedBuild
    Optional minimum OS build number that confirms the upgrade. Omit to monitor
    recovery without verifying a target build. Examples: Windows Server 2016 =
    14393, Server 2019 = 17763, Server 2022 = 20348, Server 2025 = 26100;
    Windows 11 22H2 = 22621, 23H2 = 22631, and 24H2 = 26100.
.PARAMETER PollIntervalSeconds
    Delay between checks. Defaults to 15 seconds.
.PARAMETER TimeoutSeconds
    Overall monitoring timeout, including the initial reboot wait. Defaults to 3600.
    In-flight network operations can extend this by their connection timeout.
.PARAMETER Credential
    Optional credentials used to create a CIM session.
.PARAMETER Beep
    Plays an audible success or warning alert when monitoring ends.
.OUTPUTS
    System.Management.Automation.PSCustomObject. ComputerName, ExpectedBuild,
    BuildNumber, OSCaption, Status, ElapsedSeconds, and LastQueryError.
.EXAMPLE
    Watch-ServerUpgrade -ComputerName 'APP01' -ExpectedBuild 26100 -Verbose
    Monitors an upgrade to Windows Server 2025 (or Windows 11 24H2) or newer.
.EXAMPLE
    Watch-ServerUpgrade -ComputerName 'APP01' -ExpectedBuild 20348 -Verbose
    Monitors an upgrade to Windows Server 2022 or newer.
.EXAMPLE
    Watch-ServerUpgrade -ComputerName 'APP01' -Verbose
    Reports OS details after recovery without verifying upgrade success.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [ValidateRange(1, 2147483647)]
        [int]$ExpectedBuild,

        [ValidateRange(1, 2147483647)]
        [int]$PollIntervalSeconds = 15,

        [ValidateRange(1, 2147483647)]
        [int]$TimeoutSeconds = 3600,

        [pscredential]$Credential,
        [switch]$Beep
    )

    if (-not (Get-Command -Name Test-ServerUpgradePort -CommandType Function -ErrorAction SilentlyContinue)) {
        . "$PSScriptRoot\..\Private\Test-ServerUpgradePort.ps1"
    }

    $hasExpectedBuild = $PSBoundParameters.ContainsKey('ExpectedBuild')
    $startTime = Get-Date
    $deadline = $startTime.AddSeconds($TimeoutSeconds)
    $sawOffline = $false
    $recovered = $false
    $os = $null
    $lastQueryError = $null
    $status = 'TimedOut'
    $targetDescription = if ($hasExpectedBuild) { "target build $ExpectedBuild" } else { 'no target build verification' }
    Write-Verbose "[$($startTime.ToString('yyyy-MM-dd HH:mm:ss'))] '$ComputerName': waiting for a reboot; $targetDescription."

    while ((Get-Date) -lt $deadline) {
        $smbOpen = Test-ServerUpgradePort -ComputerName $ComputerName -Port 445
        $winrmOpen = Test-ServerUpgradePort -ComputerName $ComputerName -Port 5985
        $rdpOpen = Test-ServerUpgradePort -ComputerName $ComputerName -Port 3389

        if (-not $smbOpen -and -not $winrmOpen -and -not $rdpOpen) {
            if (-not $sawOffline) {
                Write-Verbose "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] '$ComputerName': management ports are offline."
            }
            $sawOffline = $true
        } elseif ($sawOffline) {
            $recovered = $true
            $session = $null
            try {
                $cimParams = @{
                    ClassName = 'Win32_OperatingSystem'
                    OperationTimeoutSec = 10
                    ErrorAction = 'Stop'
                    Verbose = $false
                }
                if ($PSBoundParameters.ContainsKey('Credential')) {
                    $session = New-CimSession -ComputerName $ComputerName -Credential $Credential -OperationTimeoutSec 10 -ErrorAction Stop -Verbose:$false
                    $cimParams.CimSession = $session
                } else {
                    $cimParams.ComputerName = $ComputerName
                }
                $queriedOS = Get-CimInstance @cimParams
                if (-not $queriedOS -or [string]::IsNullOrEmpty([string]$queriedOS.BuildNumber)) {
                    throw 'CIM returned no OS build number.'
                }
                $currentBuild = [int]$queriedOS.BuildNumber
                $os = $queriedOS
                $lastQueryError = $null
                Write-Verbose "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] '$ComputerName': $($os.Caption), build $currentBuild."
                if (-not $hasExpectedBuild) {
                    $status = 'Recovered'
                    break
                }
                if ($currentBuild -ge $ExpectedBuild) {
                    $status = 'Succeeded'
                    break
                }
            } catch {
                $lastQueryError = $_.Exception.Message
                Write-Verbose "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] '$ComputerName': CIM not ready; retrying. $lastQueryError"
            } finally {
                if ($session) {
                    Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue -Verbose:$false
                }
            }
        }

        $now = Get-Date
        $remaining = ($deadline - $now).TotalSeconds
        if ($remaining -gt 0) {
            $delay = [math]::Min($PollIntervalSeconds, [math]::Ceiling($remaining))
            $elapsed = [math]::Round(($now - $startTime).TotalSeconds, 1)
            $waitingFor = if (-not $sawOffline) {
                'still online; waiting for the first disconnect'
            } elseif (-not $smbOpen -and -not $winrmOpen -and -not $rdpOpen) {
                'still offline; waiting for management ports to recover'
            } elseif ($lastQueryError) {
                'management ports online; waiting for CIM to become available'
            } else {
                "management ports online; waiting for target build $ExpectedBuild"
            }
            Write-Verbose "[$($now.ToString('yyyy-MM-dd HH:mm:ss'))] '$ComputerName': $waitingFor. SMB=$smbOpen; WinRM=$winrmOpen; RDP=$rdpOpen; elapsed ${elapsed}s; next check in ${delay}s."
            Start-Sleep -Seconds $delay
        }
    }

    if ($status -notin @('Succeeded', 'Recovered')) {
        if ($os) {
            $status = 'TargetBuildNotReached'
            Write-Warning "'$ComputerName': target build $ExpectedBuild was not reached before timeout; last reported build $($os.BuildNumber). Setup may still be running or a rollback may have occurred."
        } elseif ($recovered) {
            $status = 'QueryFailed'
            Write-Warning "'$ComputerName': management ports recovered, but the OS build could not be verified before timeout."
        } else {
            Write-Warning "'$ComputerName': timed out waiting for management ports to disconnect and recover."
        }
    }

    if ($Beep) {
        try {
            if ($status -in @('Succeeded', 'Recovered')) {
                [Console]::Beep(1000, 500)
                [Console]::Beep(1200, 500)
                [Console]::Beep(1400, 800)
            } else {
                [Console]::Beep(400, 1000)
            }
        } catch {
            Write-Verbose "'$ComputerName': audible alert unavailable. $($_.Exception.Message)"
        }
    }

    [PSCustomObject]@{
        ComputerName = $ComputerName
        ExpectedBuild = $(if ($hasExpectedBuild) { $ExpectedBuild } else { $null })
        BuildNumber = $(if ($os) { [int]$os.BuildNumber } else { $null })
        OSCaption = $(if ($os) { $os.Caption } else { $null })
        Status = $status
        ElapsedSeconds = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
        LastQueryError = $lastQueryError
    }
}