function Test-Xml {
<#
.SYNOPSIS
    Validates an XML file against an XSD schema.

.PARAMETER XmlPath
    Path to the XML file to validate (relative or absolute).

.PARAMETER XsdUrl
    URL or path of the XSD schema.

.PARAMETER TargetNamespace
    XML target namespace declared in the schema.

.EXAMPLE
    Test-Xml -XmlPath .\document.xml -XsdUrl 'http://myserver/schema.xsd' -TargetNamespace 'urn:myorg:myschema'
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true, HelpMessage="Path to the XML file (relative or absolute).")]
    [string]$XmlPath,

    [Parameter(Mandatory=$true)]
    [string]$XsdUrl,

    [Parameter(Mandatory=$true)]
    [string]$TargetNamespace
)

# Resolve the XML path to a full absolute path
$XmlPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($XmlPath)

if (-not (Test-Path $XmlPath)) {
    Write-Error "The file at '$XmlPath' could not be found."
    return
}

# Create a Schema Set and add the URL
$schemas = New-Object System.Xml.Schema.XmlSchemaSet
try {
    $schemas.Add($TargetNamespace, $XsdUrl)
    $schemas.Compile()
} catch {
    Write-Error "Failed to load or compile schema from $XsdUrl : $($_.Exception.Message)"
    return
}

# Configure Validation Settings
$settings = New-Object System.Xml.XmlReaderSettings
$settings.ValidationType = [System.Xml.ValidationType]::Schema
$settings.Schemas = $schemas

$validationErrors = New-Object System.Collections.Generic.List[string]
$settings.add_ValidationEventHandler({
    $validationEvent = $args[1]
    $script:validationErrors.Add("[$($validationEvent.Severity)] Line $($validationEvent.Exception.LineNumber): $($validationEvent.Message)")
})

# Create the Reader and execute validation
$reader = [System.Xml.XmlReader]::Create($XmlPath, $settings)
try {
    while ($reader.Read()) { }
} catch {
    $validationErrors.Add("Critical Error: $($_.Exception.Message)")
} finally {
    $reader.Close()
}

# Output Results
if ($validationErrors.Count -eq 0) {
    Write-Host "Validation Successful!" -ForegroundColor Green
    Write-Host "File: $XmlPath"
    Write-Host "Schema: $XsdUrl"
} else {
    Write-Host "Validation Failed for '$XmlPath':" -ForegroundColor Red
    $validationErrors | ForEach-Object { Write-Host $_ }
}
}