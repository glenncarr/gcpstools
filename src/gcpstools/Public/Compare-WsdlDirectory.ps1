function Compare-WsdlDirectory {
    <#
    .SYNOPSIS
        Compares the WSDL/XSD service contracts in two directories and reports
        the specific structural differences (messages, operations, types, and
        the individual fields within them).

    .DESCRIPTION
        Walks both directories, pairs files by their relative path, and for each
        matched .wsdl / .xsd file parses the XML and extracts the named service
        components:

            - Message        (with their parts)
            - Operation      (portType input/output/fault message wiring)
            - Element        (top-level schema elements)
            - ComplexType    (with a per-field signature)
            - SimpleType     (restriction base and enumeration values)
            - Field          (every named xsd:element, emitted individually so
                              added/removed/renamed/retyped fields surface on
                              their own line)

        Each component is compared by name and by a normalized signature, so the
        output tells you exactly what changed rather than just "the file differs".

        Files that only exist on one side are reported as File Added / Removed.
        Non-WSDL files are ignored unless -IncludeAllFiles is supplied, in which
        case they are compared by content hash.

        DEFAULT OUTPUT columns: Change, Category, Name, File.
        Reference and Difference (the before/after signatures) are hidden; use
        '| Format-List *' or '| Select-Object *' to see them, or
        '| Format-Table * -Wrap' for a full width view.

    .PARAMETER ReferenceDirectory
        The baseline directory (the "before" / left side of the comparison).

    .PARAMETER DifferenceDirectory
        The directory to compare against the baseline (the "after" / right side).

    .PARAMETER Include
        File name patterns treated as WSDL contracts and compared semantically.
        Defaults to '*.wsdl' and '*.xsd'.

    .PARAMETER IncludeAllFiles
        Also report differences in non-WSDL files (e.g. generated *.cs proxies)
        using a content-hash comparison.

    .PARAMETER ShowUnchanged
        Include components that are identical on both sides in the output.

    .EXAMPLE
        Compare-WsdlDirectory `
            'C:\client1\WCFServices' `
            'C:\client2\WCFServices'

    .EXAMPLE
        Compare-WsdlDirectory $trunk $release |
            Where-Object Change -ne 'Unchanged' |
            Format-Table * -Wrap

    .EXAMPLE
        # Focus on field-level changes only
        Compare-WsdlDirectory $trunk $release |
            Where-Object Category -eq 'Field'
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [Alias('ReferencePath', 'Source')]
        [string]$ReferenceDirectory,

        [Parameter(Mandatory = $true, Position = 1)]
        [Alias('DifferencePath', 'Destination')]
        [string]$DifferenceDirectory,

        [string[]]$Include = @('*.wsdl', '*.xsd'),

        [switch]$IncludeAllFiles,

        [switch]$ShowUnchanged
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "This function requires PowerShell 7.0 or newer."
    }

    $refRoot = (Resolve-Path -LiteralPath $ReferenceDirectory -ErrorAction Stop).ProviderPath.TrimEnd('\')
    $difRoot = (Resolve-Path -LiteralPath $DifferenceDirectory -ErrorAction Stop).ProviderPath.TrimEnd('\')

    # --- Extract a name->signature map of contract components from one XML file ---
    $extract = {
        param([string]$XmlPath)

        try {
            $doc = New-Object System.Xml.XmlDocument
            $doc.Load($XmlPath)
        }
        catch {
            return $null   # not parseable as XML; caller falls back to hashing
        }

        $records = [System.Collections.Generic.List[pscustomobject]]::new()
        $emit = {
            param($cat, $name, $detail)
            if ([string]::IsNullOrWhiteSpace($name)) { return }
            $records.Add([pscustomobject]@{
                    Category = [string]$cat
                    Name     = [string]$name
                    Detail   = [string]$detail
                })
        }

        # Messages and their parts.
        foreach ($m in $doc.SelectNodes("//*[local-name()='message']")) {
            $parts = foreach ($p in $m.SelectNodes("*[local-name()='part']")) {
                $pt = $p.GetAttribute('element')
                if ([string]::IsNullOrEmpty($pt)) { $pt = $p.GetAttribute('type') }
                '{0}:{1}' -f $p.GetAttribute('name'), $pt
            }
            & $emit 'Message' $m.GetAttribute('name') ($parts -join ', ')
        }

        # Operations declared on portTypes.
        foreach ($op in $doc.SelectNodes("//*[local-name()='portType']/*[local-name()='operation']")) {
            $io = foreach ($c in $op.ChildNodes) {
                if ($c.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
                '{0}={1}' -f $c.LocalName, $c.GetAttribute('message')
            }
            & $emit 'Operation' $op.GetAttribute('name') ($io -join ', ')
        }

        # Named simple types (enumerations, restrictions).
        foreach ($st in $doc.SelectNodes("//*[local-name()='simpleType'][@name]")) {
            $restr = $st.SelectSingleNode("*[local-name()='restriction']")
            $base = if ($restr) { $restr.GetAttribute('base') } else { '' }
            $detail = "base=$base"
            if ($restr) {
                $enums = foreach ($e in $restr.SelectNodes("*[local-name()='enumeration']")) { $e.GetAttribute('value') }
                if ($enums) { $detail += "; values={" + ($enums -join '|') + "}" }
            }
            & $emit 'SimpleType' $st.GetAttribute('name') $detail
        }

        # Type containers: named complexTypes plus top-level schema elements
        # (which may carry an inline anonymous complexType).
        $containers = [System.Collections.Generic.List[pscustomobject]]::new()
        foreach ($ct in $doc.SelectNodes("//*[local-name()='complexType'][@name]")) {
            $containers.Add([pscustomobject]@{ Node = $ct; Category = 'ComplexType'; Name = $ct.GetAttribute('name') })
        }
        foreach ($el in $doc.SelectNodes("//*[local-name()='schema']/*[local-name()='element'][@name]")) {
            $containers.Add([pscustomobject]@{ Node = $el; Category = 'Element'; Name = $el.GetAttribute('name') })
        }

        foreach ($container in $containers) {
            $node = $container.Node
            $cat = $container.Category
            $name = $container.Name
            $typeAttr = $node.GetAttribute('type')

            $fieldSigs = foreach ($f in $node.SelectNodes(".//*[local-name()='element'][@name]")) {
                $fName = $f.GetAttribute('name')
                $fType = $f.GetAttribute('type')
                if ([string]::IsNullOrEmpty($fType)) {
                    if ($f.SelectSingleNode("*[local-name()='complexType'] | *[local-name()='simpleType']")) {
                        $fType = '(inline)'
                    }
                }
                $minO = $f.GetAttribute('minOccurs'); if ([string]::IsNullOrEmpty($minO)) { $minO = '1' }
                $maxO = $f.GetAttribute('maxOccurs'); if ([string]::IsNullOrEmpty($maxO)) { $maxO = '1' }
                $nil = if ($f.GetAttribute('nillable') -eq 'true') { ' nillable' } else { '' }

                & $emit 'Field' ('{0}/{1}' -f $name, $fName) ('{0} [{1}..{2}]{3}' -f $fType, $minO, $maxO, $nil)
                '{0}:{1} [{2}..{3}]{4}' -f $fName, $fType, $minO, $maxO, $nil
            }

            if ($fieldSigs) {
                & $emit $cat $name ($fieldSigs -join '; ')
            }
            elseif ($cat -eq 'Element' -and $typeAttr) {
                & $emit 'Element' $name "type=$typeAttr"
            }
            elseif ($cat -eq 'ComplexType') {
                & $emit 'ComplexType' $name '(empty)'
            }
        }

        return , $records
    }

    $toMap = {
        param($records)
        $h = [ordered]@{}
        foreach ($r in $records) { $h["$($r.Category)|$($r.Name)"] = $r }
        $h
    }

    # --- Pair files by relative path ---
    $refFiles = @{}
    foreach ($f in (Get-ChildItem -LiteralPath $refRoot -Recurse -File -ErrorAction SilentlyContinue)) {
        $refFiles[$f.FullName.Substring($refRoot.Length).TrimStart('\')] = $f
    }
    $difFiles = @{}
    foreach ($f in (Get-ChildItem -LiteralPath $difRoot -Recurse -File -ErrorAction SilentlyContinue)) {
        $difFiles[$f.FullName.Substring($difRoot.Length).TrimStart('\')] = $f
    }

    $allRel = [System.Collections.Generic.SortedSet[string]]::new(
        [string[]]($refFiles.Keys + $difFiles.Keys),
        [System.StringComparer]::OrdinalIgnoreCase)

    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    $addResult = {
        param($file, $cat, $name, $change, $ref, $dif)
        $results.Add([pscustomobject]@{
                File       = $file
                Category   = $cat
                Name       = $name
                Change     = $change
                Reference  = [string]$ref
                Difference = [string]$dif
            })
    }

    foreach ($rel in $allRel) {
        $inRef = $refFiles.ContainsKey($rel)
        $inDif = $difFiles.ContainsKey($rel)

        $isWsdl = $false
        foreach ($pat in $Include) { if ($rel -like "*$pat" -or (Split-Path $rel -Leaf) -like $pat) { $isWsdl = $true; break } }

        if (-not $isWsdl -and -not $IncludeAllFiles) { continue }

        # File present on only one side.
        if (-not ($inRef -and $inDif)) {
            $change = if ($inRef) { 'Removed' } else { 'Added' }
            & $addResult $rel 'File' $rel $change '' ''
            continue
        }

        if ($isWsdl) {
            $refRecords = & $extract $refFiles[$rel].FullName
            $difRecords = & $extract $difFiles[$rel].FullName

            # If either side isn't valid XML, fall back to a hash comparison.
            if ($null -eq $refRecords -or $null -eq $difRecords) {
                $refHash = (Get-FileHash -LiteralPath $refFiles[$rel].FullName -Algorithm SHA256).Hash
                $difHash = (Get-FileHash -LiteralPath $difFiles[$rel].FullName -Algorithm SHA256).Hash
                if ($refHash -ne $difHash) { & $addResult $rel 'File' $rel 'Changed' 'binary/unparsable' 'binary/unparsable' }
                elseif ($ShowUnchanged) { & $addResult $rel 'File' $rel 'Unchanged' '' '' }
                continue
            }

            $refMap = & $toMap $refRecords
            $difMap = & $toMap $difRecords

            $keys = [System.Collections.Generic.SortedSet[string]]::new(
                [string[]]($refMap.Keys + $difMap.Keys),
                [System.StringComparer]::OrdinalIgnoreCase)

            foreach ($key in $keys) {
                $r = $refMap[$key]
                $d = $difMap[$key]
                $cat = ($key -split '\|', 2)[0]
                $name = ($key -split '\|', 2)[1]

                if ($null -ne $r -and $null -eq $d) {
                    & $addResult $rel $cat $name 'Removed' $r.Detail ''
                }
                elseif ($null -eq $r -and $null -ne $d) {
                    & $addResult $rel $cat $name 'Added' '' $d.Detail
                }
                elseif ($r.Detail -ne $d.Detail) {
                    & $addResult $rel $cat $name 'Changed' $r.Detail $d.Detail
                }
                elseif ($ShowUnchanged) {
                    & $addResult $rel $cat $name 'Unchanged' $r.Detail $d.Detail
                }
            }
        }
        else {
            # Non-WSDL file, -IncludeAllFiles requested: compare by hash.
            $refHash = (Get-FileHash -LiteralPath $refFiles[$rel].FullName -Algorithm SHA256).Hash
            $difHash = (Get-FileHash -LiteralPath $difFiles[$rel].FullName -Algorithm SHA256).Hash
            if ($refHash -ne $difHash) { & $addResult $rel 'File' $rel 'Changed' '' '' }
            elseif ($ShowUnchanged) { & $addResult $rel 'File' $rel 'Unchanged' '' '' }
        }
    }

    # --- Emit results with a concise default table view ---
    $changeRank = @{ Added = 0; Removed = 1; Changed = 2; Unchanged = 3 }
    $sorted = $results | Sort-Object File, @{ Expression = { $changeRank[$_.Change] } }, Category, Name

    foreach ($obj in $sorted) {
        $defaultDisplayProps = @('Change', 'Category', 'Name', 'File')
        $propSet = [System.Management.Automation.PSPropertySet]::new(
            'DefaultDisplayPropertySet', [string[]]$defaultDisplayProps)
        $memberSet = [System.Management.Automation.PSMemberSet]::new(
            'PSStandardMembers', [System.Management.Automation.PSMemberInfo[]]@($propSet))
        $obj.PSObject.Members.Add($memberSet)
        $obj
    }
}
