Describe 'Get-InternalsVisibleToAttribute' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\gcpstools\Public\Get-InternalsVisibleToAttribute.ps1"

        # Build a small real assembly that declares InternalsVisibleTo attributes
        # so the function can actually load and inspect it.
        $script:asmPath = Join-Path $TestDrive 'IvtSample.dll'
        $code = @'
using System.Runtime.CompilerServices;
[assembly: InternalsVisibleTo("Friend.Tests")]
[assembly: InternalsVisibleTo("Other.Assembly")]
public class IvtSample { }
'@
        Add-Type -TypeDefinition $code -OutputAssembly $script:asmPath -OutputType Library
    }

    It 'Writes a terminating error for a non-existent assembly path' {
        { Get-InternalsVisibleToAttribute -Path 'C:\nonexistent_assembly.dll' -FriendAssemblyNamePattern '*' -ErrorAction Stop } |
            Should -Throw
    }

    It 'Returns the matching InternalsVisibleTo friend assembly' {
        $result = Get-InternalsVisibleToAttribute -Path $script:asmPath -FriendAssemblyNamePattern '*Tests*'
        $result | Should -Not -BeNullOrEmpty
        $result.AssemblyName | Should -Be 'Friend.Tests'
    }

    It 'Returns nothing when the pattern matches no friend assembly' {
        $result = Get-InternalsVisibleToAttribute -Path $script:asmPath -FriendAssemblyNamePattern 'ZZZ_NO_MATCH_ZZZ'
        $result | Should -BeNullOrEmpty
    }

    It 'Returns all friend assemblies for a wildcard pattern' {
        $result = Get-InternalsVisibleToAttribute -Path $script:asmPath -FriendAssemblyNamePattern '*'
        @($result).Count | Should -Be 2
    }
}
