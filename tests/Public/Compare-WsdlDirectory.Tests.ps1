Describe 'Compare-WsdlDirectory' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\gcpstools\Public\Compare-WsdlDirectory.ps1"

        # Two versions of the same WSDL exercising every diff category:
        # - Field retyped (OrderId int -> long)
        # - Field removed (Total) and added (ShipDate)
        # - Message part retyped
        # - Operation gains an output
        # - SimpleType gains an enumeration value
        $script:refWsdl = @'
<wsdl:definitions xmlns:wsdl="http://schemas.xmlsoap.org/wsdl/" xmlns:xs="http://www.w3.org/2001/XMLSchema">
 <wsdl:types><xs:schema>
  <xs:element name="Order"><xs:complexType><xs:sequence>
   <xs:element name="OrderId" type="xs:int" minOccurs="1" maxOccurs="1"/>
   <xs:element name="Customer" type="xs:string"/>
   <xs:element name="Total" type="xs:decimal"/>
  </xs:sequence></xs:complexType></xs:element>
  <xs:simpleType name="Status"><xs:restriction base="xs:string">
   <xs:enumeration value="New"/><xs:enumeration value="Shipped"/>
  </xs:restriction></xs:simpleType>
 </xs:schema></wsdl:types>
 <wsdl:message name="GetOrderRequest"><wsdl:part name="id" type="xs:int"/></wsdl:message>
 <wsdl:portType name="OrderService"><wsdl:operation name="GetOrder">
  <wsdl:input message="GetOrderRequest"/></wsdl:operation></wsdl:portType>
</wsdl:definitions>
'@

        $script:difWsdl = @'
<wsdl:definitions xmlns:wsdl="http://schemas.xmlsoap.org/wsdl/" xmlns:xs="http://www.w3.org/2001/XMLSchema">
 <wsdl:types><xs:schema>
  <xs:element name="Order"><xs:complexType><xs:sequence>
   <xs:element name="OrderId" type="xs:long" minOccurs="1" maxOccurs="1"/>
   <xs:element name="Customer" type="xs:string"/>
   <xs:element name="ShipDate" type="xs:dateTime" nillable="true"/>
  </xs:sequence></xs:complexType></xs:element>
  <xs:simpleType name="Status"><xs:restriction base="xs:string">
   <xs:enumeration value="New"/><xs:enumeration value="Shipped"/><xs:enumeration value="Cancelled"/>
  </xs:restriction></xs:simpleType>
 </xs:schema></wsdl:types>
 <wsdl:message name="GetOrderRequest"><wsdl:part name="id" type="xs:long"/></wsdl:message>
 <wsdl:portType name="OrderService"><wsdl:operation name="GetOrder">
  <wsdl:input message="GetOrderRequest"/><wsdl:output message="GetOrderResponse"/></wsdl:operation></wsdl:portType>
</wsdl:definitions>
'@
    }

    It 'Throws on PowerShell 5.x' {
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            Set-ItResult -Skipped -Because 'Only relevant on PS5.x'
            return
        }
        { Compare-WsdlDirectory -ReferenceDirectory '.' -DifferenceDirectory '.' } | Should -Throw
    }

    Context 'Semantic WSDL comparison' {
        BeforeAll {
            if ($PSVersionTable.PSVersion.Major -lt 7) { return }
            $ref = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'ref')
            $dif = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'dif')
            Set-Content -Path (Join-Path $ref 'Order.wsdl') -Value $script:refWsdl
            Set-Content -Path (Join-Path $dif 'Order.wsdl') -Value $script:difWsdl
            $script:result = Compare-WsdlDirectory -ReferenceDirectory $ref -DifferenceDirectory $dif
        }

        It 'Reports a retyped field as Changed' {
            if ($PSVersionTable.PSVersion.Major -lt 7) { Set-ItResult -Skipped -Because 'Requires PowerShell 7+'; return }
            $field = $script:result | Where-Object { $_.Category -eq 'Field' -and $_.Name -eq 'Order/OrderId' }
            $field.Change | Should -Be 'Changed'
            $field.Reference | Should -Match 'xs:int'
            $field.Difference | Should -Match 'xs:long'
        }

        It 'Reports a removed field' {
            if ($PSVersionTable.PSVersion.Major -lt 7) { Set-ItResult -Skipped -Because 'Requires PowerShell 7+'; return }
            $field = $script:result | Where-Object { $_.Category -eq 'Field' -and $_.Name -eq 'Order/Total' }
            $field.Change | Should -Be 'Removed'
        }

        It 'Reports an added field' {
            if ($PSVersionTable.PSVersion.Major -lt 7) { Set-ItResult -Skipped -Because 'Requires PowerShell 7+'; return }
            $field = $script:result | Where-Object { $_.Category -eq 'Field' -and $_.Name -eq 'Order/ShipDate' }
            $field.Change | Should -Be 'Added'
        }

        It 'Reports a changed message part' {
            if ($PSVersionTable.PSVersion.Major -lt 7) { Set-ItResult -Skipped -Because 'Requires PowerShell 7+'; return }
            $msg = $script:result | Where-Object { $_.Category -eq 'Message' -and $_.Name -eq 'GetOrderRequest' }
            $msg.Change | Should -Be 'Changed'
        }

        It 'Reports an operation gaining an output message' {
            if ($PSVersionTable.PSVersion.Major -lt 7) { Set-ItResult -Skipped -Because 'Requires PowerShell 7+'; return }
            $op = $script:result | Where-Object { $_.Category -eq 'Operation' -and $_.Name -eq 'GetOrder' }
            $op.Change | Should -Be 'Changed'
            $op.Difference | Should -Match 'output=GetOrderResponse'
        }

        It 'Reports a simpleType gaining an enumeration value' {
            if ($PSVersionTable.PSVersion.Major -lt 7) { Set-ItResult -Skipped -Because 'Requires PowerShell 7+'; return }
            $st = $script:result | Where-Object { $_.Category -eq 'SimpleType' -and $_.Name -eq 'Status' }
            $st.Change | Should -Be 'Changed'
            $st.Difference | Should -Match 'Cancelled'
        }

        It 'Omits unchanged components by default' {
            if ($PSVersionTable.PSVersion.Major -lt 7) { Set-ItResult -Skipped -Because 'Requires PowerShell 7+'; return }
            ($script:result | Where-Object Change -eq 'Unchanged') | Should -BeNullOrEmpty
        }
    }

    It 'Reports a file present only in the reference directory as Removed' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { Set-ItResult -Skipped -Because 'Requires PowerShell 7+'; return }
        $ref = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'ronly-ref')
        $dif = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'ronly-dif')
        Set-Content -Path (Join-Path $ref 'Only.wsdl') -Value $script:refWsdl

        $result = Compare-WsdlDirectory -ReferenceDirectory $ref -DifferenceDirectory $dif
        $file = $result | Where-Object { $_.Category -eq 'File' -and $_.Name -eq 'Only.wsdl' }
        $file.Change | Should -Be 'Removed'
    }

    It 'Returns no differences for identical directories' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { Set-ItResult -Skipped -Because 'Requires PowerShell 7+'; return }
        $ref = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'same-ref')
        $dif = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'same-dif')
        Set-Content -Path (Join-Path $ref 'Order.wsdl') -Value $script:refWsdl
        Set-Content -Path (Join-Path $dif 'Order.wsdl') -Value $script:refWsdl

        $result = Compare-WsdlDirectory -ReferenceDirectory $ref -DifferenceDirectory $dif
        $result | Should -BeNullOrEmpty
    }

    It 'Ignores non-WSDL files unless -IncludeAllFiles is specified' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { Set-ItResult -Skipped -Because 'Requires PowerShell 7+'; return }
        $ref = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'cs-ref')
        $dif = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'cs-dif')
        Set-Content -Path (Join-Path $ref 'Reference.cs') -Value 'class A {}'
        Set-Content -Path (Join-Path $dif 'Reference.cs') -Value 'class B {}'

        (Compare-WsdlDirectory -ReferenceDirectory $ref -DifferenceDirectory $dif) |
            Should -BeNullOrEmpty

        $withAll = Compare-WsdlDirectory -ReferenceDirectory $ref -DifferenceDirectory $dif -IncludeAllFiles
        ($withAll | Where-Object { $_.Name -eq 'Reference.cs' }).Change | Should -Be 'Changed'
    }
}
