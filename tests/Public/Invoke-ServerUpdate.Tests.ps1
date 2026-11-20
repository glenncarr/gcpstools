Describe 'Invoke-ServerUpdate' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\gcpstools\Public\Invoke-ServerUpdate.ps1"
    }

    BeforeEach {
        Mock -CommandName Write-Progress -MockWith { }

        Mock -CommandName Invoke-Command -MockWith {
            [PSCustomObject]@{
                TimedOut = $false
                Result   = [PSCustomObject]@{
                    Searched       = 3
                    Installed      = 3
                    RebootRequired = $true
                    ResultCode     = 2
                    Updates        = @('Update A', 'Update B', 'Update C')
                    Error          = $null
                }
            }
        }
    }

    It 'Starts the installation on every requested computer' {
        $result = @(Invoke-ServerUpdate -ComputerName 'APP01', 'SQL01' -Confirm:$false)

        $result.ComputerName | Should -Be @('APP01', 'SQL01')
        $result.Started | Should -Be @($true, $true)
        $result[0].PSTypeNames[0] | Should -Be 'gcpstools.ServerUpdateResult'
        Should -Invoke Invoke-Command -Times 2 -Exactly
    }

    It 'Reports what was installed' {
        $result = Invoke-ServerUpdate -ComputerName 'APP01' -Wait -Confirm:$false

        $result.UpdatesFound | Should -Be 3
        $result.UpdatesInstalled | Should -Be 3
        $result.RebootRequired | Should -BeTrue
        $result.Updates | Should -Be @('Update A', 'Update B', 'Update C')
        $result.Error | Should -BeNullOrEmpty
        $result.TimedOut | Should -BeFalse
    }

    It 'Does nothing with -WhatIf' {
        $result = @(Invoke-ServerUpdate -ComputerName 'APP01' -WhatIf)

        $result.Count | Should -Be 0
        Should -Invoke Invoke-Command -Times 0 -Exactly
    }

    It 'Passes the reboot, wait, and timeout options to the computer' {
        Invoke-ServerUpdate -ComputerName 'APP01' -AllowReboot -Wait -TimeoutMinutes 5 -Confirm:$false

        Should -Invoke Invoke-Command -ParameterFilter {
            $ArgumentList[0] -match 'Microsoft.Update.Session' -and
            $ArgumentList[1] -eq $true -and
            $ArgumentList[2] -eq $true -and
            $ArgumentList[3] -eq 5
        } -Times 1 -Exactly
    }

    It 'Does not allow a reboot or wait by default' {
        Invoke-ServerUpdate -ComputerName 'APP01' -Confirm:$false

        Should -Invoke Invoke-Command -ParameterFilter {
            $ArgumentList[1] -eq $false -and $ArgumentList[2] -eq $false
        } -Times 1 -Exactly
    }

    It 'Warns and reports TimedOut when the installation outlasts the timeout' {
        Mock -CommandName Invoke-Command -MockWith {
            [PSCustomObject]@{ TimedOut = $true; Result = $null }
        }
        Mock -CommandName Write-Warning -MockWith { }

        $result = Invoke-ServerUpdate -ComputerName 'APP01' -Wait -TimeoutMinutes 1 -Confirm:$false

        $result.TimedOut | Should -BeTrue
        $result.UpdatesInstalled | Should -BeNullOrEmpty
        Should -Invoke Write-Warning -Times 1 -Exactly
    }

    It 'Reports the failure and continues when a computer cannot be reached' {
        Mock -CommandName Invoke-Command -MockWith {
            param($ComputerName)

            if ($ComputerName -eq 'APP01') {
                throw 'WinRM cannot complete the operation'
            }

            [PSCustomObject]@{ TimedOut = $false; Result = $null }
        }

        $errors = @()
        $result = @(Invoke-ServerUpdate -ComputerName 'APP01', 'SQL01' -Confirm:$false -ErrorVariable errors -ErrorAction SilentlyContinue)

        $result.ComputerName | Should -Be @('APP01', 'SQL01')
        $result[0].Started | Should -BeFalse
        $result[0].PSTypeNames[0] | Should -Be 'gcpstools.ServerUpdateResult'
        $result[0].Error | Should -Be 'WinRM cannot complete the operation'
        $result[1].Started | Should -BeTrue
        ($errors | ForEach-Object ToString) -join "`n" | Should -Match 'APP01'
    }

    It 'Accepts computer names from the pipeline' {
        $result = @('APP01', 'SQL01' | Invoke-ServerUpdate -Confirm:$false)

        $result.ComputerName | Should -Be @('APP01', 'SQL01')
    }

    It 'Accepts objects with a ComputerName property from the pipeline' {
        $result = @(
            [PSCustomObject]@{ ComputerName = 'APP01' },
            [PSCustomObject]@{ ComputerName = 'SQL01' } | Invoke-ServerUpdate -Confirm:$false
        )

        $result.ComputerName | Should -Be @('APP01', 'SQL01')
    }

    Context 'Scheduled task restart handling' {
        BeforeEach {
            $script:pendingRestart = $true
            $script:systemInfoFails = $false
            $script:searchFails = $false
            $script:taskResultJson = $null

            Mock -CommandName Restart-Computer -MockWith { }
            Mock -CommandName Test-Path -MockWith { $false }
            Mock -CommandName Set-Content -MockWith {
                param($Value)
                $script:taskResultJson = $Value
            }
            Mock -CommandName New-Object -MockWith {
                param($ComObject)

                if ($ComObject -eq 'Microsoft.Update.SystemInfo') {
                    if ($script:systemInfoFails) { throw 'SystemInfo unavailable' }
                    return [PSCustomObject]@{ RebootRequired = $script:pendingRestart }
                }

                if ($ComObject -eq 'Microsoft.Update.Session') {
                    $searcher = [PSCustomObject]@{}
                    $searcher | Add-Member -MemberType ScriptMethod -Name Search -Value {
                        param($Criteria)
                        if ($script:searchFails) { throw 'Restart required before searching' }
                        [PSCustomObject]@{ Updates = @() }
                    }
                    $session = [PSCustomObject]@{ Searcher = $searcher }
                    $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateSearcher -Value {
                        $this.Searcher
                    }
                    return $session
                }

                throw "Unexpected COM object: $ComObject"
            }
            Mock -CommandName Invoke-Command -MockWith {
                param($ArgumentList)

                $taskScript = [scriptblock]::Create($ArgumentList[0])
                & $taskScript -ResultPath 'TestDrive:\update-result.json' -AllowReboot:([bool]$ArgumentList[1])
                [PSCustomObject]@{
                    TimedOut = $false
                    Result = $script:taskResultJson | ConvertFrom-Json
                }
            }
        }

        It 'Checks for updates and reboots for an existing restart with no updates' {
            $result = Invoke-ServerUpdate -ComputerName 'APP01' -Wait -AllowReboot -Confirm:$false

            $result.UpdatesFound | Should -Be 0
            $result.UpdatesInstalled | Should -Be 0
            $result.RebootRequired | Should -BeTrue
            $result.Error | Should -BeNullOrEmpty
            Should -Invoke New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' } -Times 1 -Exactly
            Should -Invoke Restart-Computer -ParameterFilter { $Force } -Times 1 -Exactly
        }

        It 'Reports an existing restart without rebooting unless allowed' {
            $result = Invoke-ServerUpdate -ComputerName 'APP01' -Wait -Confirm:$false

            $result.RebootRequired | Should -BeTrue
            Should -Invoke Restart-Computer -Times 0 -Exactly
        }

        It 'Does not reboot when no restart is required' {
            $script:pendingRestart = $false

            $result = Invoke-ServerUpdate -ComputerName 'APP01' -Wait -AllowReboot -Confirm:$false

            $result.Error | Should -BeNullOrEmpty
            $result.RebootRequired | Should -BeFalse
            Should -Invoke Restart-Computer -Times 0 -Exactly
        }

        It 'Uses the registry restart marker <Marker> when SystemInfo is unavailable' -TestCases @(
            @{ Marker = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' }
            @{ Marker = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' }
        ) {
            param($Marker)
            $script:systemInfoFails = $true
            Mock -CommandName Test-Path -MockWith { $true } -ParameterFilter { $Path -eq $Marker }

            $result = Invoke-ServerUpdate -ComputerName 'APP01' -Wait -AllowReboot -Confirm:$false

            $result.RebootRequired | Should -BeTrue
            Should -Invoke Restart-Computer -Times 1 -Exactly
        }

        It 'Records a search failure and still reboots when a restart was already pending' {
            $script:searchFails = $true

            $result = Invoke-ServerUpdate -ComputerName 'APP01' -Wait -AllowReboot -Confirm:$false

            $result.RebootRequired | Should -BeTrue
            $result.Error | Should -Match 'Restart required before searching'
            Should -Invoke Restart-Computer -Times 1 -Exactly
        }
    }
}
