function Compare-DirectoryContentParallel {
    <#
    .SYNOPSIS
        Compares files between two directories using multithreaded content hashing.

    .DESCRIPTION
        Scans a Source directory (or specific file list) and compares against a Destination.

        DEFAULT OUTPUT:
        Displays "FileName", "Status", "SourceLWT", and "DestLWT".

        HIDDEN OUTPUT:
        Use "| Select-Object *" or "| Format-List" to see hidden properties:
        - SourcePath
        - DestPath

    .PARAMETER Source
        The root folder of the source files.

    .PARAMETER Destination
        The root folder of the destination files.

    .PARAMETER FileList
        Optional. Array of relative paths. If provided, only these files are checked.

    .PARAMETER ShowAll
        (Alias: IncludeMatch). If specified, the output includes files that match.
        Without this, only differences/errors are returned.

    .PARAMETER ThrottleLimit
        Number of parallel threads. Default: 16.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [string[]]$FileList,

        [ValidateSet("MD5", "SHA1", "SHA256")]
        [string]$Algorithm = "MD5",

        [Alias('IncludeMatch')]
        [switch]$ShowAll,

        [int]$ThrottleLimit = 16
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Throw "This function requires PowerShell Core 7.0 or newer."
    }

    $Source = $Source.TrimEnd('\')
    $Destination = $Destination.TrimEnd('\')

    # --- Build the list of files to process ---
    if ($FileList) {
        Write-Verbose "File list provided. Processing $($FileList.Count) specific files..."
        $files = foreach ($path in $FileList) {
            $cleanPath = $path.TrimStart('\').TrimStart('/')
            $fullSourcePath = Join-Path -Path $Source -ChildPath $cleanPath

            if (Test-Path $fullSourcePath -PathType Leaf) {
                Get-Item $fullSourcePath
            }
            else {
                Write-Warning "Skipping: File not found in source ($cleanPath)"
            }
        }
    }
    else {
        Write-Verbose "Scanning entire source directory recursively..."
        $files = Get-ChildItem -Path $Source -File -Recurse
    }

    if (-not $files) {
        Write-Warning "No valid files found to process."
        return
    }

    Write-Verbose "Starting comparison of $($files.Count) files using $ThrottleLimit threads..."

    # --- Parallel Processing ---
    $files | ForEach-Object -Parallel {
        $file = $_

        # Pass variables into parallel scope
        $srcRoot = $using:Source
        $dstRoot = $using:Destination
        $algo = $using:Algorithm
        $showAll = $using:ShowAll

        $relativePath = $file.FullName.Substring($srcRoot.Length)
        $destPath = "$dstRoot$relativePath"

        # Initialize the properties dictionary
        $props = [ordered]@{
            FileName   = $relativePath
            Status     = "Unknown"
            SourcePath = $file.FullName
            DestPath   = $destPath
            SourceLWT  = $file.LastWriteTime
            DestLWT    = $null
        }

        # 1. Check if file exists in destination
        if (-not (Test-Path $destPath)) {
            $props.Status = "MissingInDest"
        }
        else {
            # Get Destination Item for Metadata
            $destFile = Get-Item $destPath
            $props.DestLWT = $destFile.LastWriteTime

            # 2. Calculate Hashes
            $srcHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm $algo).Hash
            $dstHash = (Get-FileHash -LiteralPath $destPath -Algorithm $algo).Hash

            # 3. Compare Content
            if ($srcHash -ne $dstHash) {
                $props.Status = "ContentMismatch"

                # Check for "Silent" mismatch (Same Size/Time, different content)
                if ($file.Length -eq $destFile.Length -and
                    $file.LastWriteTime.ToString() -eq $destFile.LastWriteTime.ToString()) {
                    $props.Status = "SilentCorruption"
                }
            }
            elseif ($showAll) {
                $props.Status = "Match"
            }
        }

        # --- Output Logic ---
        if ($props.Status -ne "Unknown") {

            # Create the object
            $obj = [PSCustomObject]$props

            # define DefaultDisplayPropertySet (Included LWT properties here)
            $defaultDisplayProps = @('FileName', 'Status', 'SourceLWT', 'DestLWT')
            $propSet = [System.Management.Automation.PSPropertySet]::new('DefaultDisplayPropertySet', [string[]]$defaultDisplayProps)
            $memberSet = [System.Management.Automation.PSMemberSet]::new('PSStandardMembers', [System.Management.Automation.PSMemberInfo[]]@($propSet))

            # Add the member set to the object
            $obj.PSObject.Members.Add($memberSet)

            return $obj
        }

    } -ThrottleLimit $ThrottleLimit
}
