Describe 'Invoke-ServerCommand' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\gcpstools\Public\Invoke-ServerCommand.ps1"
    }

    BeforeEach {
        function New-TestPSSession {
            param([string]$ComputerName)

            $connection = [System.Management.Automation.Runspaces.WSManConnectionInfo]::new("http://$ComputerName`:5985/wsman")
            $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($connection)
            $constructor = [System.Management.Automation.Runspaces.PSSession].GetConstructors(
                [System.Reflection.BindingFlags]'Instance,NonPublic,Public')
            $constructor.Invoke(@($runspace))
        }

        Mock -CommandName New-PSSession -MockWith {
            New-TestPSSession -ComputerName $ComputerName[0]
        }

        Mock -CommandName Invoke-Command -MockWith {
            [PSCustomObject]@{
                ComputerName = $Session.ComputerName
                Result       = 'completed'
            }
        }

        Mock -CommandName Remove-PSSession -MockWith { }
    }

    It 'Executes the script block on every piped computer and closes each session' {
        $result = @(
            'APP01', 'SQL01' | Invoke-ServerCommand -ScriptBlock { Get-Service -Name 'wuauserv' }
        )

        $result.ComputerName | Should -Be @('APP01', 'SQL01')
        Should -Invoke New-PSSession -Times 2 -Exactly
        Should -Invoke Invoke-Command -Times 2 -Exactly
        Should -Invoke Remove-PSSession -Times 2 -Exactly
    }

    It 'Passes the script block arguments to the remote command' {
        $scriptBlock = { param($Path) Get-Item -LiteralPath $Path }

        Invoke-ServerCommand -ComputerName 'APP01' -ScriptBlock $scriptBlock -ArgumentList 'C:\Windows'

        $scriptText = $scriptBlock.ToString()
        Should -Invoke Invoke-Command -ParameterFilter {
            $ScriptBlock.ToString() -eq $scriptText -and
            $ArgumentList.Count -eq 1 -and
            $ArgumentList[0] -eq 'C:\Windows'
        } -Times 1 -Exactly
    }

    It 'Continues to the next computer and closes the failed session' {
        Mock -CommandName Invoke-Command -MockWith {
            if ($Session.ComputerName -eq 'APP01') {
                throw 'WinRM cannot complete the operation'
            }

            [PSCustomObject]@{ ComputerName = $Session.ComputerName }
        }

        $errors = @()
        $result = @(
            'APP01', 'SQL01' |
                Invoke-ServerCommand -ScriptBlock { Get-Service } -ErrorVariable errors -ErrorAction SilentlyContinue
        )

        $result.ComputerName | Should -Be 'SQL01'
        ($errors | ForEach-Object ToString) -join "`n" | Should -Match 'APP01'
        Should -Invoke Remove-PSSession -Times 2 -Exactly
    }

    It 'Does nothing with -WhatIf' {
        $result = @(Invoke-ServerCommand -ComputerName 'APP01' -ScriptBlock { Get-Service } -WhatIf)

        $result.Count | Should -Be 0
        Should -Invoke New-PSSession -Times 0 -Exactly
        Should -Invoke Invoke-Command -Times 0 -Exactly
    }
}