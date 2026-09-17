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
}
