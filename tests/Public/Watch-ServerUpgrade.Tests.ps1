Describe 'Watch-ServerUpgrade' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\gcpstools\Private\Test-ServerUpgradePort.ps1"
        . "$PSScriptRoot\..\..\src\gcpstools\Public\Watch-ServerUpgrade.ps1"
    }

    BeforeEach {
        $script:clock = [datetime]'2026-01-01'
        $script:portChecks = 0
        $script:queries = 0
        Mock Get-Date { $script:clock }
        Mock Start-Sleep { $script:clock = $script:clock.AddSeconds($Seconds) }
        Mock Test-ServerUpgradePort {
            $script:portChecks++
            $script:portChecks -gt 3
        }
        Mock Get-CimInstance {
            [PSCustomObject]@{ BuildNumber = '30000'; Caption = 'Windows target release' }
        }
        Mock New-CimSession { [Microsoft.Management.Infrastructure.CimSession]::Create('APP01') }
        Mock Remove-CimSession { }
        Mock Write-Warning { }
    }

    It 'Loads its private helper when only the public script is dot-sourced' {
        $shell = [powershell]::Create()
        try {
            $scriptBlock = {
                param($PublicScript)
                . $PublicScript
                $script:clock = [datetime]'2026-01-01'
                $script:dateCalls = 0
                function Get-Date {
                    $script:dateCalls++
                    if ($script:dateCalls -gt 2) {
                        $script:clock = $script:clock.AddSeconds(2)
                    }
                    $script:clock
                }
                $result = Watch-ServerUpgrade -ComputerName '127.0.0.1' -TimeoutSeconds 1 -WarningAction SilentlyContinue
                $result.Status
            }
            $publicScript = "$PSScriptRoot\..\..\src\gcpstools\Public\Watch-ServerUpgrade.ps1"
            [void]$shell.AddScript($scriptBlock.ToString()).AddArgument($publicScript)
            $result = $shell.Invoke()
            $shell.Streams.Error.Count | Should -Be 0
            $result | Should -Be 'TimedOut'
        } finally {
            $shell.Dispose()
        }
    }

    It 'Confirms any supplied target build after an offline transition' {
        $result = Watch-ServerUpgrade -ComputerName 'APP01' -ExpectedBuild 30000 -PollIntervalSeconds 1
        $result.Status | Should -Be 'Succeeded'
        $result.BuildNumber | Should -Be 30000
        $result.OSCaption | Should -Be 'Windows target release'
        Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter {
            $ComputerName -eq 'APP01' -and $ClassName -eq 'Win32_OperatingSystem' -and -not $Verbose
        }
    }

    It 'Reports recovery without claiming upgrade success when no target build is supplied' {
        $result = Watch-ServerUpgrade -ComputerName 'APP01' -PollIntervalSeconds 1
        $result.Status | Should -Be 'Recovered'
        $result.ExpectedBuild | Should -BeNullOrEmpty
        $result.BuildNumber | Should -Be 30000
        $result.OSCaption | Should -Be 'Windows target release'
        Should -Invoke Get-CimInstance -Times 1 -Exactly
        Should -Invoke Write-Warning -Times 0 -Exactly
    }

    It 'Retries CIM failures without a target build until OS details are available' {
        Mock Get-CimInstance {
            $script:queries++
            if ($script:queries -eq 1) { throw 'CIM is starting' }
            [PSCustomObject]@{ BuildNumber = '17763'; Caption = 'Windows Server 2019' }
        }
        $result = Watch-ServerUpgrade -ComputerName 'APP01' -PollIntervalSeconds 1
        $result.Status | Should -Be 'Recovered'
        $result.BuildNumber | Should -Be 17763
        $result.LastQueryError | Should -BeNullOrEmpty
        Should -Invoke Get-CimInstance -Times 2 -Exactly
    }

    It 'Still reports query failure at timeout without a target build' {
        Mock Get-CimInstance { throw 'Access denied' }
        $result = Watch-ServerUpgrade -ComputerName 'APP01' -PollIntervalSeconds 1 -TimeoutSeconds 2
        $result.Status | Should -Be 'QueryFailed'
        $result.ExpectedBuild | Should -BeNullOrEmpty
        $result.BuildNumber | Should -BeNullOrEmpty
    }

    It 'Waits for the initial disconnect before querying CIM' {
        Mock Test-ServerUpgradePort {
            $script:portChecks++
            $script:portChecks -le 3 -or $script:portChecks -gt 6
        }
        $result = Watch-ServerUpgrade -ComputerName 'APP01' -ExpectedBuild 29000 -PollIntervalSeconds 1
        $result.Status | Should -Be 'Succeeded'
        $result.ElapsedSeconds | Should -Be 2
        Should -Invoke Get-CimInstance -Times 1 -Exactly
    }

    It 'Does not treat the host as offline while only RDP remains open' {
        Mock Test-ServerUpgradePort { $Port -eq 3389 }
        $output = @(Watch-ServerUpgrade -ComputerName 'APP01' -PollIntervalSeconds 1 -TimeoutSeconds 3 -Verbose 4>&1)
        $result = $output | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] }
        $result.Status | Should -Be 'TimedOut'
        Should -Invoke Get-CimInstance -Times 0 -Exactly
        Should -Invoke Test-ServerUpgradePort -Times 3 -Exactly -ParameterFilter { $Port -eq 3389 }
        $messages = @($output | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object Message)
        @($messages | Where-Object { $_ -like '*still online*SMB=False; WinRM=False; RDP=True*' }).Count | Should -Be 3
    }

    It 'Queries the OS when only RDP recovers after all ports disconnect' {
        Mock Test-ServerUpgradePort {
            $Port -eq 3389 -and $script:clock -gt [datetime]'2026-01-01'
        }
        $result = Watch-ServerUpgrade -ComputerName 'APP01' -PollIntervalSeconds 1 -TimeoutSeconds 3
        $result.Status | Should -Be 'Recovered'
        $result.ElapsedSeconds | Should -Be 1
        Should -Invoke Get-CimInstance -Times 1 -Exactly
        Should -Invoke Test-ServerUpgradePort -Times 2 -Exactly -ParameterFilter { $Port -eq 3389 }
    }

    It 'Keeps monitoring an older build through another reboot and a CIM failure' {
        Mock Test-ServerUpgradePort {
            $script:portChecks++
            $script:portChecks -gt 3 -and ($script:portChecks -le 6 -or $script:portChecks -gt 9)
        }
        Mock Get-CimInstance {
            $script:queries++
            if ($script:queries -eq 2) { throw 'CIM is starting' }
            $build = if ($script:queries -eq 1) { '20000' } else { '30000' }
            [PSCustomObject]@{ BuildNumber = $build; Caption = 'Windows' }
        }
        $result = Watch-ServerUpgrade -ComputerName 'APP01' -ExpectedBuild 30000 -PollIntervalSeconds 1
        $result.Status | Should -Be 'Succeeded'
        $result.LastQueryError | Should -BeNullOrEmpty
        Should -Invoke Get-CimInstance -Times 3 -Exactly
    }

    It 'Uses and removes a credentialed CIM session even when querying fails' {
        $credential = [pscredential]::new('user', (ConvertTo-SecureString 'test' -AsPlainText -Force))
        Mock Get-CimInstance { throw 'Access denied' }
        $result = Watch-ServerUpgrade -ComputerName 'APP01' -ExpectedBuild 30000 -Credential $credential -PollIntervalSeconds 1 -TimeoutSeconds 3
        $result.Status | Should -Be 'QueryFailed'
        $result.BuildNumber | Should -BeNullOrEmpty
        $result.LastQueryError | Should -Be 'Access denied'
        Should -Invoke New-CimSession -Times 2 -Exactly -ParameterFilter { $Credential.UserName -eq 'user' }
        Should -Invoke Get-CimInstance -Times 2 -Exactly -ParameterFilter { $null -ne $CimSession }
        Should -Invoke Remove-CimSession -Times 2 -Exactly
    }

    It 'Does not claim a rollback when CIM returns no OS details' {
        Mock Get-CimInstance { $null }
        $result = Watch-ServerUpgrade -ComputerName 'APP01' -ExpectedBuild 30000 -PollIntervalSeconds 1 -TimeoutSeconds 2
        $result.Status | Should -Be 'QueryFailed'
        $result.BuildNumber | Should -BeNullOrEmpty
    }

    It 'Reports an older build only after the monitoring timeout' {
        Mock Get-CimInstance { [PSCustomObject]@{ BuildNumber = '20000'; Caption = 'Windows' } }
        $result = Watch-ServerUpgrade -ComputerName 'APP01' -ExpectedBuild 30000 -PollIntervalSeconds 1 -TimeoutSeconds 3
        $result.Status | Should -Be 'TargetBuildNotReached'
        $result.BuildNumber | Should -Be 20000
        $result.ElapsedSeconds | Should -Be 3
    }

    It 'Bounds the initial reboot wait' {
        Mock Test-ServerUpgradePort { $true }
        $result = Watch-ServerUpgrade -ComputerName 'APP01' -ExpectedBuild 30000 -TimeoutSeconds 3
        $result.Status | Should -Be 'TimedOut'
        $result.ElapsedSeconds | Should -Be 3
        Should -Invoke Get-CimInstance -Times 0 -Exactly
    }

    It 'Bounds the offline recovery wait' {
        Mock Test-ServerUpgradePort { $false }
        $result = Watch-ServerUpgrade -ComputerName 'APP01' -ExpectedBuild 30000 -TimeoutSeconds 3
        $result.Status | Should -Be 'TimedOut'
        Should -Invoke Get-CimInstance -Times 0 -Exactly
    }

    It 'Shows recurring verbose feedback while <Phase>' -TestCases @(
        @{ Phase = 'online'; PortOpen = $true; WaitingMessage = 'still online; waiting for the first disconnect' }
        @{ Phase = 'offline'; PortOpen = $false; WaitingMessage = 'still offline; waiting for management ports to recover' }
    ) {
        param($Phase, $PortOpen, $WaitingMessage)
        Mock Test-ServerUpgradePort { $PortOpen }
        $output = @(Watch-ServerUpgrade -ComputerName 'APP01' -PollIntervalSeconds 1 -TimeoutSeconds 3 -Verbose 4>&1)
        $messages = @($output | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object Message)
        $feedback = @($messages | Where-Object { $_ -like "*$WaitingMessage*elapsed*next check*" })
        $feedback.Count | Should -Be 3
        $feedback[0] | Should -Match "\[2026-01-01 00:00:00\] 'APP01':"
        $feedback[1] | Should -Match 'elapsed 1s; next check in 1s'
        $feedback[2] | Should -Match 'elapsed 2s; next check in 1s'
        $feedback[0] | Should -Match "SMB=$PortOpen; WinRM=$PortOpen; RDP=$PortOpen"
    }

    It 'Shows waiting feedback when the reported build is below the target' {
        Mock Get-CimInstance { [PSCustomObject]@{ BuildNumber = '20000'; Caption = 'Windows' } }
        $output = @(Watch-ServerUpgrade -ComputerName 'APP01' -ExpectedBuild 30000 -PollIntervalSeconds 1 -TimeoutSeconds 3 -Verbose 4>&1)
        $messages = @($output | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object Message)
        @($messages | Where-Object { $_ -like "*'APP01': management ports online; waiting for target build 30000*" }).Count | Should -Be 2
    }

    It 'Keeps waiting feedback off the output streams when verbose is disabled' {
        Mock Test-ServerUpgradePort { $true }
        $output = @(Watch-ServerUpgrade -ComputerName 'APP01' -PollIntervalSeconds 1 -TimeoutSeconds 3 -Verbose:$false 4>&1)
        $output.Count | Should -Be 1
        $output[0].Status | Should -Be 'TimedOut'
    }

    It 'Rejects invalid build and polling values' {
        { Watch-ServerUpgrade -ComputerName 'APP01' -ExpectedBuild 0 } | Should -Throw
        { Watch-ServerUpgrade -ComputerName 'APP01' -ExpectedBuild 30000 -PollIntervalSeconds 0 } | Should -Throw
        { Watch-ServerUpgrade -ComputerName 'APP01' -ExpectedBuild 30000 -TimeoutSeconds 0 } | Should -Throw
    }
}