Describe 'Get-ServerUpdateStatus' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\gcpstools\Public\Get-ServerUpdateStatus.ps1"
    }

    BeforeEach {
        $script:written = [System.Collections.Generic.List[object]]::new()

        Mock -CommandName Write-ColorLine -MockWith {
            param($Text, $Color)

            $script:written.Add([PSCustomObject]@{
                Text  = [string]$Text
                Color = [string]$Color
            })
        }

        Mock -CommandName Write-Progress -MockWith { }

        Mock -CommandName Get-CimInstance -MockWith {
            param($ComputerName)

            [PSCustomObject]@{ HotFixID = 'KB5000001'; InstalledOn = [datetime]'2026-08-14' }
            [PSCustomObject]@{ HotFixID = "KB-$ComputerName"; InstalledOn = [datetime]'2026-09-11' }
        }

        Mock -CommandName Invoke-Command -MockWith { 0 }
    }

    It 'Reports only the requested servers by default' {
        Mock -CommandName Get-VM -MockWith { [PSCustomObject]@{ Name = 'VM-A'; State = 'Running' } }

        Get-ServerUpdateStatus -ComputerName 'APP01', 'SQL01'

        $script:written.Text | Should -Be @(
            'APP01'
            '  Windows Update: KB-APP01 installed 2026-09-11; no updates available'
            'SQL01'
            '  Windows Update: KB-SQL01 installed 2026-09-11; no updates available'
        )
        Should -Invoke Get-VM -Times 0 -Exactly
    }

    It 'Reports VMs of a Hyper-V host with -IncludeVM' {
        Mock -CommandName Get-VM -MockWith {
            [PSCustomObject]@{ Name = 'VM-A'; State = 'Running' }
            [PSCustomObject]@{ Name = 'VM-B'; State = 'Off' }
        }
        Mock -CommandName Invoke-Command -MockWith {
            param($ComputerName)

            if ($ComputerName -eq 'HV01') { 0 } else { 3 }
        }

        Get-ServerUpdateStatus -ComputerName 'HV01' -IncludeVM

        $script:written.Text | Should -Be @(
            'HV01'
            '  Windows Update: KB-HV01 installed 2026-09-11; no updates available'
            '  VM-A - '
            'Running'
            '    Windows Update: KB-VM-A installed 2026-09-11; 3 updates available'
            '  VM-B - '
            'Off'
            '    Windows Update: not running'
        )
    }

    It 'Reports servers without Hyper-V when -IncludeVM is used' {
        Mock -CommandName Get-VM -MockWith { throw 'The operation failed because Hyper-V is not installed' }

        Get-ServerUpdateStatus -ComputerName 'APP01' -IncludeVM

        $script:written.Text | Should -Be @(
            'APP01'
            '  Windows Update: KB-APP01 installed 2026-09-11; no updates available'
            '  (VM list unavailable)'
        )
        ($script:written | Where-Object Text -eq '  (VM list unavailable)').Color | Should -Be 'Red'
    }

    It 'Reports a Hyper-V host that has no VMs' {
        Mock -CommandName Get-VM -MockWith { }

        Get-ServerUpdateStatus -ComputerName 'HV01' -IncludeVM

        $script:written.Text | Should -Contain '  (no VMs)'
    }

    It 'Colors the server, state, and update status' {
        Mock -CommandName Get-VM -MockWith {
            [PSCustomObject]@{ Name = 'VM-A'; State = 'Running' }
            [PSCustomObject]@{ Name = 'VM-B'; State = 'Off' }
            [PSCustomObject]@{ Name = 'VM-C'; State = 'Paused' }
        }
        Mock -CommandName Invoke-Command -MockWith {
            param($ComputerName)

            if ($ComputerName -eq 'HV01') { 0 } else { 3 }
        }

        Get-ServerUpdateStatus -ComputerName 'HV01' -IncludeVM

        $script:written.Color | Should -Be @(
            'White'     # server name
            'Green'     # server is up to date
            'White'     # VM-A name
            'Green'     # VM-A is running
            'Orange'    # VM-A needs updates
            'White'     # VM-B name
            'DarkGray'  # VM-B is off
            'DarkGray'  # VM-B status not collected
            'White'     # VM-C name
            'Yellow'    # VM-C is paused
            'DarkGray'  # VM-C status not collected
        )
    }

    It 'Reports a single available update in the singular' {
        Mock -CommandName Invoke-Command -MockWith { 1 }

        Get-ServerUpdateStatus -ComputerName 'APP01'

        $script:written.Text | Should -Contain '  Windows Update: KB-APP01 installed 2026-09-11; 1 update available'
    }

    It 'Reports an unknown availability without writing errors when the update search fails' {
        Mock -CommandName Invoke-Command -MockWith { throw 'WinRM cannot complete the operation' }
        Mock -CommandName Write-Error -MockWith { }

        Get-ServerUpdateStatus -ComputerName 'APP01'

        $line = $script:written | Where-Object Text -like '*available updates unknown'
        $line.Text | Should -Be '  Windows Update: KB-APP01 installed 2026-09-11; available updates unknown'
        $line.Color | Should -Be 'Red'
        Should -Invoke Write-Error -Times 0 -Exactly
    }

    It 'Reports an unavailable status without writing errors when the computer cannot be queried' {
        Mock -CommandName Get-CimInstance -MockWith { throw 'Access is denied' }
        Mock -CommandName Write-Error -MockWith { }

        Get-ServerUpdateStatus -ComputerName 'APP01'

        $line = $script:written | Where-Object Text -eq '  Windows Update: unavailable'
        $line | Should -Not -BeNullOrEmpty
        $line.Color | Should -Be 'Red'
        Should -Invoke Write-Error -Times 0 -Exactly
    }

    It 'Returns status objects with -AsObject' {
        Mock -CommandName Get-VM -MockWith {
            [PSCustomObject]@{ Name = 'VM-A'; State = 'Running' }
            [PSCustomObject]@{ Name = 'VM-B'; State = 'Off' }
        }
        Mock -CommandName Invoke-Command -MockWith { 2 }

        $result = @(Get-ServerUpdateStatus -ComputerName 'HV01' -IncludeVM -AsObject)

        $result.ComputerName | Should -Be @('HV01', 'VM-A', 'VM-B')
        $result[0].HyperVServer | Should -BeNullOrEmpty
        $result[1].HyperVServer | Should -Be 'HV01'
        $result[1].State | Should -Be 'Running'
        $result[1].LastInstalledUpdate | Should -Be 'KB-VM-A'
        $result[1].LastInstalledOn | Should -Be ([datetime]'2026-09-11')
        $result[1].AvailableUpdateCount | Should -Be 2
        $result[1].UpdateStatus | Should -Be 'KB-VM-A installed 2026-09-11; 2 updates available'
        $result[2].UpdateStatus | Should -Be 'not running'
        $result[2].AvailableUpdateCount | Should -BeNullOrEmpty
        $script:written.Count | Should -Be 0
    }

    It 'Reports progress for every computer that is queried' {
        Mock -CommandName Get-VM -MockWith {
            [PSCustomObject]@{ Name = 'VM-A'; State = 'Running' }
            [PSCustomObject]@{ Name = 'VM-B'; State = 'Running' }
        }

        Get-ServerUpdateStatus -ComputerName 'HV01' -IncludeVM

        Should -Invoke Write-Progress -ParameterFilter { $Status -like 'HV01*' } -Times 1 -Exactly
        Should -Invoke Write-Progress -ParameterFilter { $Status -like 'VM-A*' } -Times 1 -Exactly
        Should -Invoke Write-Progress -ParameterFilter { $Status -like 'VM-B*' } -Times 1 -Exactly
        Should -Invoke Write-Progress -ParameterFilter { $Completed } -Times 2 -Exactly
    }

    It 'Accepts computer names from the pipeline' {
        $result = @('APP01', 'SQL01' | Get-ServerUpdateStatus -AsObject)

        $result.ComputerName | Should -Be @('APP01', 'SQL01')
    }
}

Describe 'Write-ColorLine' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\gcpstools\Public\Get-ServerUpdateStatus.ps1"
    }

    It 'Writes orange with a 24-bit escape sequence when the host supports it' {
        if (-not $Host.UI.SupportsVirtualTerminal) {
            Set-ItResult -Skipped -Because 'the host has no virtual terminal support'
        }

        Mock -CommandName Write-Host -MockWith { }

        Write-ColorLine -Text 'needs updates' -Color Orange

        Should -Invoke Write-Host -ParameterFilter {
            $Object -eq "$([char]27)[38;2;255;140;0mneeds updates$([char]27)[0m" -and -not $ForegroundColor
        } -Times 1 -Exactly
    }

    It 'Passes other colors straight through to Write-Host' {
        Mock -CommandName Write-Host -MockWith { }

        Write-ColorLine -Text 'HV01' -Color White

        Should -Invoke Write-Host -ParameterFilter {
            $Object -eq 'HV01' -and $ForegroundColor -eq 'White'
        } -Times 1 -Exactly
    }
}
