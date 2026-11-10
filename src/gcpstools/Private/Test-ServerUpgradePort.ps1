function Test-ServerUpgradePort {
    [CmdletBinding()]
    param(
        [string]$ComputerName,
        [int]$Port
    )

    $client = New-Object System.Net.Sockets.TcpClient
    $waitHandle = $null
    try {
        $connection = $client.BeginConnect($ComputerName, $Port, $null, $null)
        $waitHandle = $connection.AsyncWaitHandle
        if (-not $waitHandle.WaitOne(2000, $false)) {
            return $false
        }
        $client.EndConnect($connection)
        return $true
    } catch {
        return $false
    } finally {
        if ($waitHandle) { $waitHandle.Close() }
        $client.Close()
    }
}