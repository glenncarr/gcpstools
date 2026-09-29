function Invoke-ServerCommand {
<#
.SYNOPSIS
    Executes a script block on one or more servers.

.DESCRIPTION
    Opens a PowerShell remoting session for each target server, runs the
    supplied script block, and closes the session when execution completes.
    Output from the remote script block is returned to the caller.

.PARAMETER ComputerName
    One or more computer names. Computer names can also be piped to this
    command, including objects with a Name or ComputerName property.

.PARAMETER ScriptBlock
    The script block to execute on each server.

.PARAMETER ArgumentList
    Values passed to the script block's parameters on each server.

.INPUTS
    System.String[]. Computer names can be piped to this command.

.OUTPUTS
    System.Object. Objects returned by the remote script block.

.EXAMPLE
    Invoke-ServerCommand -ComputerName 'APP01' -ScriptBlock {
        Get-Service -Name 'wuauserv'
    }

    Gets a service from one server.

.EXAMPLE
    'SERVER01', 'SERVER02', 'SERVER03', 'SERVER04' |
        Invoke-ServerCommand -ScriptBlock {
            Remove-StaleDotNetRuntime -WhatIf -Verbose
        }

    Runs the same command on each server supplied through the pipeline.

.EXAMPLE
    Invoke-ServerCommand -ComputerName 'APP01' -ScriptBlock {
        param($Path)
        Get-Item -LiteralPath $Path
    } -ArgumentList 'C:\Windows'

    Passes an argument to the remote script block.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
    [ValidateNotNullOrEmpty()]
    [Alias('Name')]
    [string[]]$ComputerName,

    [Parameter(Mandatory = $true, Position = 1)]
    [ValidateNotNull()]
    [scriptblock]$ScriptBlock,

    [Parameter(Position = 2)]
    [object[]]$ArgumentList
)

process {
    foreach ($server in $ComputerName) {
        if (-not $PSCmdlet.ShouldProcess($server, 'Execute remote script block')) {
            continue
        }

        $session = $null

        try {
            Write-Verbose "Opening a PowerShell remoting session to '$server'."
            $session = New-PSSession -ComputerName $server -ErrorAction Stop

            $invokeParameters = @{
                Session    = $session
                ScriptBlock = $ScriptBlock
                ErrorAction = 'Stop'
            }

            if ($PSBoundParameters.ContainsKey('ArgumentList')) {
                $invokeParameters.ArgumentList = $ArgumentList
            }

            Write-Verbose "Executing the script block on '$server'."
            Invoke-Command @invokeParameters
        } catch {
            Write-Error "Failed to execute the script block on '$server': $($_.Exception.Message)"
        } finally {
            if ($null -ne $session) {
                Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            }
        }
    }
}
}