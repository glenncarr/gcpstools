function Get-PendingRebootFromCim {
<#
.SYNOPSIS
    Internal helper detecting a pending restart over CIM.

.DESCRIPTION
    Used when PowerShell remoting is unavailable, so that a pending restart is
    still reported. Returns $null when the registry could not be read.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ComputerName
)

$hklm = [uint32]2147483650
$keys = @(
    @{ Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'; Name = 'RebootPending' }
    @{ Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update'; Name = 'RebootRequired' }
)

$read = $false

foreach ($key in $keys) {
    try {
        $subKeys = Invoke-CimMethod -ComputerName $ComputerName -Namespace 'root\cimv2' -ClassName 'StdRegProv' -MethodName 'EnumKey' -Arguments @{
            hDefKey     = $hklm
            sSubKeyName = $key.Path
        } -ErrorAction Stop -Verbose:$false

        $read = $true

        if (@($subKeys.sNames) -contains $key.Name) {
            return $true
        }
    } catch {
        Write-Verbose "Failed to read '$($key.Path)' on '$ComputerName': $($_.Exception.Message)"
    }
}

if ($read) {
    return $false
}

$null
}

function Get-WindowsUpdateStatus {
<#
.SYNOPSIS
    Internal helper returning the update status of a single computer.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ComputerName
)

$result = [PSCustomObject]@{
    LastInstalledUpdate  = $null
    LastInstalledOn      = $null
    AvailableUpdateCount = $null
    Installing           = $null
    RebootPending        = $null
    Status               = 'unavailable'
}

Write-Verbose "Checking Windows update status on '$ComputerName'."

try {
    $hotfix = Get-CimInstance -ComputerName $ComputerName -ClassName Win32_QuickFixEngineering -ErrorAction Stop -Verbose:$false |
        Sort-Object InstalledOn -Descending |
        Select-Object -First 1
} catch {
    Write-Verbose "Failed to retrieve Windows update status from '$ComputerName': $($_.Exception.Message)"
    return $result
}

if ($hotfix) {
    $result.LastInstalledUpdate = $hotfix.HotFixID
    $result.LastInstalledOn = $hotfix.InstalledOn

    $installed = '{0} installed {1:yyyy-MM-dd}' -f $hotfix.HotFixID, $hotfix.InstalledOn
} else {
    $installed = 'no updates installed'
}

try {
    $pending = Invoke-Command -ComputerName $ComputerName -ErrorAction Stop -Verbose:$false -ScriptBlock {
        $session = New-Object -ComObject 'Microsoft.Update.Session'

        $rebootPending = $false

        try {
            $rebootPending = [bool](New-Object -ComObject 'Microsoft.Update.SystemInfo').RebootRequired
        } catch {
            $rebootPending = $false
        }

        if (-not $rebootPending) {
            $rebootPending =
                (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        }

        # A pending restart can make the search fail, so it is reported even
        # when the available update count cannot be determined.
        $found = $null
        $searchError = $null

        try {
            $found = @($session.CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0').Updates).Count
        } catch {
            $searchError = $_.Exception.Message
        }

        # IsBusy covers any installer on the computer; the task covers an
        # install started by Invoke-ServerUpdate that has not begun yet.
        $installing = $false

        try {
            $installing = [bool]$session.CreateUpdateInstaller().IsBusy
        } catch {
            $installing = $false
        }

        $task = Get-ScheduledTask -TaskName 'gcpstools-InstallWindowsUpdate' -ErrorAction SilentlyContinue

        if ($task -and "$($task.State)" -eq 'Running') {
            $installing = $true
        }

        [PSCustomObject]@{
            AvailableUpdateCount = $found
            Installing           = $installing
            RebootPending        = $rebootPending
            SearchError          = $searchError
        }
    }

    $info = @($pending)[0]
    $result.Installing = [bool]$info.Installing
    $result.RebootPending = [bool]$info.RebootPending

    if ($null -eq $info.AvailableUpdateCount) {
        Write-Verbose "Failed to check for available Windows updates on '$ComputerName': $($info.SearchError)"
        $available = 'available updates unknown'
    } else {
        $count = [int]$info.AvailableUpdateCount
        $result.AvailableUpdateCount = $count

        $available = switch ($count) {
            0 { 'no updates available' }
            1 { '1 update available' }
            default { "$count updates available" }
        }
    }

    if ($result.Installing) {
        $available = '{0}; installing updates' -f $available
    }

    if ($result.RebootPending) {
        $available = '{0}; restart pending' -f $available
    }
} catch {
    Write-Verbose "Failed to check for available Windows updates on '$ComputerName': $($_.Exception.Message)"
    $available = 'available updates unknown'

    $result.RebootPending = Get-PendingRebootFromCim -ComputerName $ComputerName

    if ($result.RebootPending) {
        $available = '{0}; restart pending' -f $available
    }
}

$result.Status = '{0}; {1}' -f $installed, $available
$result
}

function Get-WindowsUpdateStatusColor {
<#
.SYNOPSIS
    Internal helper mapping an update status string to a console color.
#>
param(
    [string]$Status
)

if ($Status -match 'unavailable|unknown') {
    'Red'
} elseif ($Status -match 'installing updates') {
    'Cyan'
} elseif ($Status -match 'restart pending') {
    'Yellow'
} elseif ($Status -match 'not running') {
    'DarkGray'
} elseif ($Status -match 'no updates available') {
    'Green'
} else {
    'Orange'
}
}

function ConvertTo-UpdateStatusObject {
<#
.SYNOPSIS
    Internal helper flattening an update status into an output object.
#>
param(
    [string]$ComputerName,
    $HyperVServer,
    $State,
    $Status
)

[PSCustomObject]@{
    ComputerName         = $ComputerName
    HyperVServer         = $HyperVServer
    State                = $State
    LastInstalledUpdate  = $Status.LastInstalledUpdate
    LastInstalledOn      = $Status.LastInstalledOn
    AvailableUpdateCount = $Status.AvailableUpdateCount
    Installing           = $Status.Installing
    RebootPending        = $Status.RebootPending
    UpdateStatus         = $Status.Status
}
}

function Write-ColorLine {
<#
.SYNOPSIS
    Internal helper writing a colored console line.

.DESCRIPTION
    ConsoleColor has no orange, so 'Orange' is rendered with a 24-bit ANSI
    escape sequence and falls back to DarkYellow on hosts without virtual
    terminal support.
#>
param(
    [string]$Text,
    [string]$Color,
    [switch]$NoNewline
)

if ($Color -eq 'Orange') {
    if ($Host.UI.SupportsVirtualTerminal) {
        $esc = [char]27
        Write-Host "$esc[38;2;255;140;0m$Text$esc[0m" -NoNewline:$NoNewline
        return
    }

    $Color = 'DarkYellow'
}

Write-Host $Text -ForegroundColor $Color -NoNewline:$NoNewline
}

function Get-ServerUpdateStatus {
<#
.SYNOPSIS
    Reports the Windows update status of one or more servers, and optionally of
    the VMs they host.

.DESCRIPTION
    For each computer, Get-ServerUpdateStatus reports three things: the most
    recently installed update (from Win32_QuickFixEngineering), how many updates
    are still available (from a Windows Update Agent search for updates that are
    neither installed nor hidden), and whether an installation is currently
    running on that computer. Any Windows computer can be queried; Hyper-V is
    only needed for -IncludeVM.

    An installation is reported as in progress when the Windows Update Agent
    installer is busy, or when the scheduled task that Invoke-ServerUpdate
    registers is still running. Those computers are shown in cyan and their
    status ends with 'installing updates'.

    A computer waiting to be restarted ends with 'restart pending' and is shown
    in yellow. A pending restart can also stop the update search from working,
    so it is reported even when the number of available updates is unknown, and
    it is read over CIM when PowerShell remoting is unavailable. RebootPending
    is null when neither method could determine it.

    By default the result is written to the console in color:

        HV01
          Windows Update: KB5126043 installed 2026-09-17; no updates available
          APP01 - Running
            Windows Update: KB5126043 installed 2026-08-13; 3 updates available
          TEST01 - Off
            Windows Update: not running

    Computer names are white and VM state is colored by state (green running,
    gray off, yellow otherwise). The update status is green when a computer is
    current, orange when updates are available, cyan while updates are being
    installed, yellow while a restart is pending, and red when the status could
    not be retrieved.

    Because a single query can take several seconds, progress is reported per
    computer and each line is printed as soon as that computer has been
    checked, rather than after the whole server has been processed.

    Querying a computer requires CIM access (for the installed update) and
    PowerShell remoting (for the update search). Failures are not treated as
    errors: the computer is reported as 'unavailable', or as
    'available updates unknown' when only the update search failed, and
    -Verbose explains the underlying reason.

.PARAMETER ComputerName
    One or more computer names to query. Accepts pipeline input, including
    objects with a Name or ComputerName property.

.PARAMETER IncludeVM
    Also reports each VM hosted by the queried computers. Requires the Hyper-V
    module locally. Computers that do not run Hyper-V are still reported and
    show '(VM list unavailable)'; hosts without VMs show '(no VMs)'. VMs that
    are not running are listed without being queried.

.PARAMETER AsObject
    Returns an object per computer (and per VM with -IncludeVM) instead of
    writing colored output. Each object has these properties:

        ComputerName         Name of the computer or VM.
        HyperVServer         Host name for VM entries, otherwise null.
        State                VM state for VM entries, otherwise null.
        LastInstalledUpdate  Hotfix ID of the newest installed update.
        LastInstalledOn      Date that update was installed.
        AvailableUpdateCount Number of updates available, or null if unknown.
        Installing           Whether an installation is currently running.
        RebootPending        Whether the computer is waiting for a restart.
        UpdateStatus         The status text shown in the console output.

.INPUTS
    System.String[]. Computer names can be piped to this command.

.OUTPUTS
    None by default; the status is written to the host. With -AsObject, one
    PSCustomObject per computer and per VM.

.EXAMPLE
    Get-ServerUpdateStatus -ComputerName 'APP01', 'SQL01'

    Shows the update status of two servers.

.EXAMPLE
    Get-ServerUpdateStatus -ComputerName 'HV01', 'HV02' -IncludeVM

    Shows the update status of two Hyper-V hosts followed by their VMs.

.EXAMPLE
    Get-ServerUpdateStatus -ComputerName 'HV01' -IncludeVM -AsObject |
        Where-Object AvailableUpdateCount -gt 0

    Lists only the machines that have updates waiting to be installed.

.EXAMPLE
    Get-Content .\servers.txt | Get-ServerUpdateStatus -AsObject |
        Export-Csv .\update-status.csv -NoTypeInformation

    Builds a report from a list of servers.

.EXAMPLE
    Get-ServerUpdateStatus -ComputerName 'APP01' -Verbose

    Shows why a computer could not be queried.

.EXAMPLE
    Get-ServerUpdateStatus -ComputerName 'APP01', 'SQL01' -AsObject |
        Where-Object Installing

    Lists the servers that are installing updates right now.

.EXAMPLE
    Get-ServerUpdateStatus -ComputerName 'APP01', 'SQL01' -AsObject |
        Where-Object RebootPending

    Lists the servers that are waiting to be restarted.

.LINK
    Invoke-ServerUpdate
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
    [ValidateNotNullOrEmpty()]
    [Alias('Name')]
    [string[]]$ComputerName,

    [switch]$IncludeVM,

    [switch]$AsObject
)

process {
    $serverNumber = 0

    foreach ($server in $ComputerName) {
        $serverNumber++

        Write-Progress -Id 1 -Activity 'Checking Windows update status' -Status "$server ($serverNumber of $($ComputerName.Count))" -PercentComplete (100 * ($serverNumber - 1) / $ComputerName.Count)

        $serverStatus = Get-WindowsUpdateStatus -ComputerName $server

        if ($AsObject) {
            ConvertTo-UpdateStatusObject -ComputerName $server -Status $serverStatus
        } else {
            Write-ColorLine -Text $server -Color White
            Write-ColorLine -Text ('  Windows Update: {0}' -f $serverStatus.Status) -Color (Get-WindowsUpdateStatusColor -Status $serverStatus.Status)
        }

        if (-not $IncludeVM) {
            continue
        }

        $vms = @()
        $vmListFailed = $false

        if (-not (Get-Command -Name Get-VM -ErrorAction SilentlyContinue)) {
            Write-Verbose "The Hyper-V module is not available, so VMs on '$server' cannot be enumerated."
            $vmListFailed = $true
        } else {
            try {
                $vms = @(Get-VM -ComputerName $server -ErrorAction Stop)
            } catch {
                Write-Verbose "Failed to retrieve VMs from '$server': $($_.Exception.Message)"
                $vmListFailed = $true
            }
        }

        if ($vmListFailed) {
            if (-not $AsObject) {
                Write-ColorLine -Text '  (VM list unavailable)' -Color Red
            }

            continue
        }

        if ($vms.Count -eq 0) {
            if (-not $AsObject) {
                Write-ColorLine -Text '  (no VMs)' -Color DarkGray
            }

            continue
        }

        $vmNumber = 0

        foreach ($vm in $vms) {
            $vmNumber++
            $isRunning = "$($vm.State)" -eq 'Running'

            Write-Progress -Id 2 -ParentId 1 -Activity "Checking Windows update status on VMs of $server" -Status "$($vm.Name) ($vmNumber of $($vms.Count))" -PercentComplete (100 * ($vmNumber - 1) / $vms.Count)

            $vmStatus = if ($isRunning) {
                Get-WindowsUpdateStatus -ComputerName $vm.Name
            } else {
                [PSCustomObject]@{
                    LastInstalledUpdate  = $null
                    LastInstalledOn      = $null
                    AvailableUpdateCount = $null
                    Installing           = $null
                    RebootPending        = $null
                    Status               = 'not running'
                }
            }

            if ($AsObject) {
                ConvertTo-UpdateStatusObject -ComputerName $vm.Name -HyperVServer $server -State "$($vm.State)" -Status $vmStatus
                continue
            }

            $stateColor = if ($isRunning) {
                'Green'
            } elseif ("$($vm.State)" -eq 'Off') {
                'DarkGray'
            } else {
                'Yellow'
            }

            Write-ColorLine -Text ('  {0} - ' -f $vm.Name) -Color White -NoNewline
            Write-ColorLine -Text "$($vm.State)" -Color $stateColor
            Write-ColorLine -Text ('    Windows Update: {0}' -f $vmStatus.Status) -Color (Get-WindowsUpdateStatusColor -Status $vmStatus.Status)
        }

        Write-Progress -Id 2 -ParentId 1 -Activity "Checking Windows update status on VMs of $server" -Completed
    }

    Write-Progress -Id 1 -Activity 'Checking Windows update status' -Completed
}
}
