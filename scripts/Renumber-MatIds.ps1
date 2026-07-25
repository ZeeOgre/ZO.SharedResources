<#
.SYNOPSIS
    Renumber colliding Starfield .mat component material IDs safely.

.DESCRIPTION
    This script scans .mat files for resource IDs like:

        res:4A078D39:000650DD:A676BE78

    Important concepts:

        ScanRoots:
            Collision universe.
            All IDs found here are reserved so generated IDs avoid them.
            Files in ScanRoots are NOT modified unless they are also under TargetRoot.

        TargetRoot:
            Edit universe.
            Only .mat files under TargetRoot may be modified.

    For each target .mat file, this script:

        1. Finds component-local owned IDs shaped like:

            "Data" : {
                "ID" : "res:XXXXXXXX:YYYYYYYY:ZZZZZZZZ"
            },
            "Index" : N,
            "Type" : "BSMaterial::SomethingID"

        2. Checks whether each owned ID appears anywhere else in the scanned universe.

        3. Renumbers only owned IDs that collide outside the current target file.

        4. Replaces only those mapped owned IDs inside the same target file.

    It does NOT directly renumber:

        "Parent" : "res:..."

    unless that exact ID is also identified as an owned component ID in the same target file.
    This protects vanilla/imported/base material references.

    Default mode is dry run. Use -Apply to modify files.

.PARAMETER TargetRoot
    Folder containing the .mat files you want to fix.

.PARAMETER ScanRoots
    Folder or folders to scan for existing IDs.

    These are used for:
      - detecting whether target-owned IDs collide
      - reserving all existing IDs so generated IDs do not collide

    If omitted, TargetRoot is scanned.

.PARAMETER Namespace
    Stable namespace used in hash generation. Keep this the same for repeatable output.

.PARAMETER Apply
    Actually write modified .mat files. Without this switch, the script only reports.

.PARAMETER NoBackup
    Do not create .bak files before writing changes.

.PARAMETER ReportPath
    Optional CSV report path.

.PARAMETER RequireInternalFilenamePrefix
    Optional internal material filename prefix gate.

    Example:
        -RequireInternalFilenamePrefix "MATERIALS\tankgirl\"

    If provided, target files whose internal "Filename" does not start with this
    prefix are skipped.

    For currently suspect copied .mat files, you may want to omit this because some
    internal Filename values may still point to vanilla paths.

.PARAMETER UpdateInternalFilename
    If set, updates the internal "Filename" value in target files to match the
    physical path relative to DataRoot.

.PARAMETER DataRoot
    Required only when -UpdateInternalFilename is used.

    Example:
        -DataRoot "G:\SteamLibrary\steamapps\common\Starfield\Data"

.EXAMPLE
    Dry run:

    .\Renumber-MatIds.ps1 `
        -TargetRoot "G:\SteamLibrary\steamapps\common\Starfield\Data\Materials\tankgirl\armor\ranger_mat" `
        -ScanRoots "G:\SteamLibrary\steamapps\common\Starfield\Data\Materials"

.EXAMPLE
    Apply with backups:

    .\Renumber-MatIds.ps1 `
        -TargetRoot "G:\SteamLibrary\steamapps\common\Starfield\Data\Materials\tankgirl\armor\ranger_mat" `
        -ScanRoots "G:\SteamLibrary\steamapps\common\Starfield\Data\Materials" `
        -Apply

.EXAMPLE
    Apply and also fix internal Filename values:

    .\Renumber-MatIds.ps1 `
        -TargetRoot "G:\SteamLibrary\steamapps\common\Starfield\Data\Materials\tankgirl\armor\ranger_mat" `
        -ScanRoots "G:\SteamLibrary\steamapps\common\Starfield\Data\Materials" `
        -UpdateInternalFilename `
        -DataRoot "G:\SteamLibrary\steamapps\common\Starfield\Data" `
        -Apply
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $TargetRoot,

    [string[]] $ScanRoots = @(),

    [string] $Namespace = "TG_Mat_ComponentId_Renumber_v4",

    [switch] $Apply,

    [switch] $NoBackup,

    [string] $ReportPath = "",

    [string] $RequireInternalFilenamePrefix = "",

    [switch] $UpdateInternalFilename,

    [string] $DataRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ResourceIdRegex = [regex]'(?i)\bres:(?<Head>[0-9a-f]{8}):(?<Mid>[0-9a-f]{8}):(?<Tail>[0-9a-f]{8})\b'

$script:OwnedComponentIdRegex = [regex]::new(
    '(?is)"Data"\s*:\s*\{\s*"ID"\s*:\s*"(?<Id>res:[0-9a-f]{8}:[0-9a-f]{8}:[0-9a-f]{8})"\s*\}\s*,\s*"Index"\s*:\s*\d+\s*,\s*"Type"\s*:\s*"BSMaterial::[^"]*ID"',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)

$script:FilenameRegex = [regex]::new(
    '(?is)"Filename"\s*:\s*"(?<Filename>[^"]*)"',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)

function Resolve-FullPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    return [System.IO.Path]::GetFullPath($Path)
}

function Normalize-MatPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    return $Path.Replace('/', '\')
}

function Get-MatFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Roots
    )

    $files = New-Object System.Collections.Generic.List[string]

    foreach ($root in $Roots) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }

        $fullRoot = Resolve-FullPath $root

        if (-not (Test-Path -LiteralPath $fullRoot)) {
            Write-Warning "Scan root does not exist: $fullRoot"
            continue
        }

        Get-ChildItem -LiteralPath $fullRoot -Recurse -File -Filter "*.mat" |
            ForEach-Object {
                $files.Add((Resolve-FullPath $_.FullName))
            }
    }

    return $files | Sort-Object -Unique
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [string] $File
    )

    $rootFull = Resolve-FullPath $Root
    $fileFull = Resolve-FullPath $File

    if (-not $rootFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $rootFull += [System.IO.Path]::DirectorySeparatorChar
    }

    $rootUri = [System.Uri]::new($rootFull)
    $fileUri = [System.Uri]::new($fileFull)

    return [System.Uri]::UnescapeDataString(
        $rootUri.MakeRelativeUri($fileUri).ToString()
    ).Replace('/', '\')
}

function Get-FileText {
    param(
        [Parameter(Mandatory = $true)]
        [string] $File
    )

    return [System.IO.File]::ReadAllText($File)
}

function Set-FileTextUtf8NoBom {
    param(
        [Parameter(Mandatory = $true)]
        [string] $File,

        [Parameter(Mandatory = $true)]
        [string] $Text
    )

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($File, $Text, $utf8NoBom)
}

function Get-ResourceIdsFromText {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Text
    )

    $ids = New-Object System.Collections.Generic.List[string]

    foreach ($match in $script:ResourceIdRegex.Matches($Text)) {
        $ids.Add($match.Value.ToUpperInvariant())
    }

    return $ids
}

function Get-OwnedComponentIdsFromMatText {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Text
    )

    $ownedIds = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($match in $script:OwnedComponentIdRegex.Matches($Text)) {
        $id = $match.Groups["Id"].Value.ToUpperInvariant()

        if ($script:ResourceIdRegex.IsMatch($id)) {
            [void] $ownedIds.Add($id)
        }
    }

    return $ownedIds
}

function Get-MatFilenameFromText {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Text
    )

    $match = $script:FilenameRegex.Match($Text)

    if (-not $match.Success) {
        return ""
    }

    return Normalize-MatPath $match.Groups["Filename"].Value
}

function Test-InternalFilenamePrefix {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Text,

        [string] $RequiredPrefix = ""
    )

    if ([string]::IsNullOrWhiteSpace($RequiredPrefix)) {
        return $true
    }

    $filename = Get-MatFilenameFromText -Text $Text

    if ([string]::IsNullOrWhiteSpace($filename)) {
        return $false
    }

    $normalizedPrefix = Normalize-MatPath $RequiredPrefix

    return $filename.StartsWith(
        $normalizedPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Get-MaterialPathFromPhysicalPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $DataRoot,

        [Parameter(Mandatory = $true)]
        [string] $File
    )

    $relativeToData = Get-RelativePath -Root $DataRoot -File $File
    return Normalize-MatPath $relativeToData
}

function Update-MatFilenameInText {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Text,

        [Parameter(Mandatory = $true)]
        [string] $NewFilename
    )

    if (-not $script:FilenameRegex.IsMatch($Text)) {
        return $Text
    }

    $escapedFilename = $NewFilename.Replace('\', '\\')

    return $script:FilenameRegex.Replace(
        $Text,
        {
            param($match)

            return '"Filename" : "' + $escapedFilename + '"'
        },
        1
    )
}

function Get-Sha256Hex {
    param(
        [Parameter(Mandatory = $true)]
        [string] $InputText
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputText)
        $hash = $sha.ComputeHash($bytes)

        $builder = [System.Text.StringBuilder]::new()

        foreach ($byte in $hash) {
            [void] $builder.Append($byte.ToString("X2"))
        }

        return $builder.ToString()
    }
    finally {
        $sha.Dispose()
    }
}

function New-ResourceIdForFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $OldId,

        [Parameter(Mandatory = $true)]
        [string] $RelativePath,

        [Parameter(Mandatory = $true)]
        [string] $Namespace,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]] $ReservedIds
    )

    $match = $script:ResourceIdRegex.Match($OldId)

    if (-not $match.Success) {
        throw "Invalid resource ID: $OldId"
    }

    $mid = $match.Groups["Mid"].Value.ToUpperInvariant()
    $tail = $match.Groups["Tail"].Value.ToUpperInvariant()

    $counter = 0

    while ($true) {
        $seed = "$Namespace|$RelativePath|$OldId|$counter"
        $hash = Get-Sha256Hex -InputText $seed

        $newHead = $hash.Substring(0, 8).ToUpperInvariant()
        $newId = "res:$newHead`:$mid`:$tail"

        if (-not $ReservedIds.Contains($newId.ToUpperInvariant())) {
            [void] $ReservedIds.Add($newId.ToUpperInvariant())
            return $newId
        }

        $counter++

        if ($counter -gt 100000) {
            throw "Could not generate a non-colliding ID for $OldId in $RelativePath"
        }
    }
}

function Backup-File {
    param(
        [Parameter(Mandatory = $true)]
        [string] $File
    )

    $backup = "$File.bak"

    if (-not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $File -Destination $backup
        return $backup
    }

    $counter = 1

    while ($true) {
        $candidate = "$File.bak.$counter"

        if (-not (Test-Path -LiteralPath $candidate)) {
            Copy-Item -LiteralPath $File -Destination $candidate
            return $candidate
        }

        $counter++
    }
}

function Replace-MappedResourceIds {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Text,

        [Parameter(Mandatory = $true)]
        [hashtable] $IdMap
    )

    if ($IdMap.Count -eq 0) {
        return $Text
    }

    return $script:ResourceIdRegex.Replace(
        $Text,
        {
            param($match)

            $oldId = $match.Value.ToUpperInvariant()

            if ($IdMap.ContainsKey($oldId)) {
                return $IdMap[$oldId]
            }

            return $match.Value
        }
    )
}

function Test-IdAppearsOutsideThisFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Id,

        [Parameter(Mandatory = $true)]
        [string] $ThisFile,

        [Parameter(Mandatory = $true)]
        [hashtable] $IdToFiles
    )

    $normalizedId = $Id.ToUpperInvariant()
    $thisFull = Resolve-FullPath $ThisFile

    if (-not $IdToFiles.ContainsKey($normalizedId)) {
        return $false
    }

    foreach ($fileWithId in $IdToFiles[$normalizedId]) {
        $otherFull = Resolve-FullPath $fileWithId

        if (-not [string]::Equals(
            $otherFull,
            $thisFull,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            return $true
        }
    }

    return $false
}

$TargetRoot = Resolve-FullPath $TargetRoot

if (-not (Test-Path -LiteralPath $TargetRoot)) {
    throw "TargetRoot does not exist: $TargetRoot"
}

if ($UpdateInternalFilename) {
    if ([string]::IsNullOrWhiteSpace($DataRoot)) {
        throw "-DataRoot is required when -UpdateInternalFilename is used."
    }

    $DataRoot = Resolve-FullPath $DataRoot

    if (-not (Test-Path -LiteralPath $DataRoot)) {
        throw "DataRoot does not exist: $DataRoot"
    }
}

if ($ScanRoots.Count -eq 0) {
    $ScanRoots = @($TargetRoot)
}

$allScanRoots = @($ScanRoots + $TargetRoot) |
    ForEach-Object { Resolve-FullPath $_ } |
    Sort-Object -Unique

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $ReportPath = Join-Path $TargetRoot "Renumber-MatIds_Report_$timestamp.csv"
}

Write-Host ""
Write-Host "Target root:"
Write-Host "  $TargetRoot"
Write-Host ""
Write-Host "Scan roots:"
foreach ($root in $allScanRoots) {
    Write-Host "  $root"
}
Write-Host ""
Write-Host "Mode: $(if ($Apply) { 'APPLY' } else { 'DRY RUN' })"
Write-Host "Namespace: $Namespace"

if (-not [string]::IsNullOrWhiteSpace($RequireInternalFilenamePrefix)) {
    Write-Host "Required internal Filename prefix:"
    Write-Host "  $RequireInternalFilenamePrefix"
}

if ($UpdateInternalFilename) {
    Write-Host "Update internal Filename: True"
    Write-Host "Data root:"
    Write-Host "  $DataRoot"
}

Write-Host ""

$targetFiles = Get-MatFiles -Roots @($TargetRoot)
$scanFiles = Get-MatFiles -Roots $allScanRoots

if ($targetFiles.Count -eq 0) {
    throw "No .mat files found under TargetRoot: $TargetRoot"
}

if ($scanFiles.Count -eq 0) {
    throw "No .mat files found under scan roots."
}

Write-Host "Target .mat files: $($targetFiles.Count)"
Write-Host "Scanned .mat files: $($scanFiles.Count)"
Write-Host ""

$targetFileSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

foreach ($targetFile in $targetFiles) {
    [void] $targetFileSet.Add((Resolve-FullPath $targetFile))
}

# Every existing resource ID found anywhere in ScanRoots.
# Used to avoid generating an ID that already exists.
$allExistingIds = [System.Collections.Generic.HashSet[string]]::new()

# Full resource ID -> all scanned files where that ID appears.
# Used to determine whether a target-owned ID collides outside its owning file.
$idToFiles = @{}

# Target file -> IDs owned by that target file.
$fileOwnedIds = @{}

Write-Host "Scanning IDs..."

foreach ($file in $scanFiles) {
    $fileFull = Resolve-FullPath $file
    $text = Get-FileText -File $fileFull

    $allIdsInThisFile = Get-ResourceIdsFromText -Text $text |
        Sort-Object -Unique

    foreach ($id in $allIdsInThisFile) {
        $normalizedId = $id.ToUpperInvariant()

        [void] $allExistingIds.Add($normalizedId)

        if (-not $idToFiles.ContainsKey($normalizedId)) {
            $idToFiles[$normalizedId] = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )
        }

        [void] $idToFiles[$normalizedId].Add($fileFull)
    }

    if ($targetFileSet.Contains($fileFull)) {
        if (-not (Test-InternalFilenamePrefix -Text $text -RequiredPrefix $RequireInternalFilenamePrefix)) {
            $fileOwnedIds[$fileFull] = [System.Collections.Generic.HashSet[string]]::new()
            continue
        }

        $ownedIds = Get-OwnedComponentIdsFromMatText -Text $text
        $fileOwnedIds[$fileFull] = $ownedIds
    }
}

Write-Host "All existing resource IDs reserved: $($allExistingIds.Count)"
Write-Host ""

$reservedIds = [System.Collections.Generic.HashSet[string]]::new()

foreach ($id in $allExistingIds) {
    [void] $reservedIds.Add($id.ToUpperInvariant())
}

$reportRows = New-Object System.Collections.Generic.List[object]

$totalFilesChanged = 0
$totalFilesSkippedByPrefix = 0
$totalFilesWithFilenameUpdated = 0
$totalOwnedIdsSeen = 0
$totalOwnedIdsColliding = 0
$totalIdsRenumbered = 0
$totalOccurrencesChanged = 0

foreach ($file in $targetFiles) {
    $fileFull = Resolve-FullPath $file
    $originalText = Get-FileText -File $fileFull
    $workingText = $originalText
    $relativePath = Get-RelativePath -Root $TargetRoot -File $fileFull

    if (-not (Test-InternalFilenamePrefix -Text $workingText -RequiredPrefix $RequireInternalFilenamePrefix)) {
        $totalFilesSkippedByPrefix++
        Write-Host "Skipping due to internal Filename prefix: $fileFull"
        continue
    }

    $internalFilenameBefore = Get-MatFilenameFromText -Text $workingText
    $internalFilenameAfter = $internalFilenameBefore

    if ($UpdateInternalFilename) {
        $newFilename = Get-MaterialPathFromPhysicalPath -DataRoot $DataRoot -File $fileFull
        $internalFilenameAfter = $newFilename

        $updatedText = Update-MatFilenameInText -Text $workingText -NewFilename $newFilename

        if ($updatedText -ne $workingText) {
            $workingText = $updatedText
            $totalFilesWithFilenameUpdated++
        }
    }

    if ($fileOwnedIds.ContainsKey($fileFull)) {
        $ownedIds = $fileOwnedIds[$fileFull]
    }
    else {
        $ownedIds = Get-OwnedComponentIdsFromMatText -Text $workingText
    }

    $totalOwnedIdsSeen += $ownedIds.Count

    $idsToChange = New-Object System.Collections.Generic.List[string]

    foreach ($ownedId in $ownedIds) {
        $ownedIdUpper = $ownedId.ToUpperInvariant()

        $collidesOutsideThisFile = Test-IdAppearsOutsideThisFile `
            -Id $ownedIdUpper `
            -ThisFile $fileFull `
            -IdToFiles $idToFiles

        if ($collidesOutsideThisFile) {
            $idsToChange.Add($ownedIdUpper)
        }
    }

    $totalOwnedIdsColliding += $idsToChange.Count

    if ($idsToChange.Count -eq 0 -and -not ($UpdateInternalFilename -and $workingText -ne $originalText)) {
        continue
    }

    $idMap = @{}

    foreach ($oldId in $idsToChange) {
        $newId = New-ResourceIdForFile `
            -OldId $oldId `
            -RelativePath $relativePath `
            -Namespace $Namespace `
            -ReservedIds $reservedIds

        $idMap[$oldId.ToUpperInvariant()] = $newId

        $occurrenceCount = ([regex]::Matches(
            $workingText,
            [regex]::Escape($oldId),
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )).Count

        $totalIdsRenumbered++
        $totalOccurrencesChanged += $occurrenceCount

        $collidingFiles = ""

        if ($idToFiles.ContainsKey($oldId.ToUpperInvariant())) {
            $collidingFiles = (($idToFiles[$oldId.ToUpperInvariant()] |
                Where-Object {
                    -not [string]::Equals(
                        (Resolve-FullPath $_),
                        $fileFull,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                }) -join ";")
        }

        $reportRows.Add([pscustomobject]@{
            File                   = $fileFull
            RelativePath           = $relativePath
            InternalFilenameBefore = $internalFilenameBefore
            InternalFilenameAfter  = $internalFilenameAfter
            OldId                  = $oldId
            NewId                  = $newId
            OccurrencesInFile      = $occurrenceCount
            CollidingFiles         = $collidingFiles
            Applied                = [bool] $Apply
            FilenameUpdated        = [bool] ($internalFilenameBefore -ne $internalFilenameAfter)
        })
    }

    if ($idMap.Count -gt 0) {
        $workingText = Replace-MappedResourceIds -Text $workingText -IdMap $idMap
    }
    elseif ($UpdateInternalFilename -and $workingText -ne $originalText) {
        $reportRows.Add([pscustomobject]@{
            File                   = $fileFull
            RelativePath           = $relativePath
            InternalFilenameBefore = $internalFilenameBefore
            InternalFilenameAfter  = $internalFilenameAfter
            OldId                  = ""
            NewId                  = ""
            OccurrencesInFile      = 0
            CollidingFiles         = ""
            Applied                = [bool] $Apply
            FilenameUpdated        = [bool] ($internalFilenameBefore -ne $internalFilenameAfter)
        })
    }

    if ($workingText -ne $originalText) {
        $totalFilesChanged++

        if ($Apply) {
            if (-not $NoBackup) {
                $backupPath = Backup-File -File $fileFull
                Write-Host "Backup: $backupPath"
            }

            Set-FileTextUtf8NoBom -File $fileFull -Text $workingText
            Write-Host "Updated: $fileFull"
        }
        else {
            Write-Host "Would update: $fileFull"
        }
    }
}

$reportRows |
    Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Report written:"
Write-Host "  $ReportPath"
Write-Host ""
Write-Host "Summary:"
Write-Host "  Files changed or would change: $totalFilesChanged"
Write-Host "  Target files skipped by internal Filename prefix: $totalFilesSkippedByPrefix"
Write-Host "  Files with internal Filename updated: $totalFilesWithFilenameUpdated"
Write-Host "  Target-owned component IDs seen: $totalOwnedIdsSeen"
Write-Host "  Target-owned component IDs colliding outside their file: $totalOwnedIdsColliding"
Write-Host "  Target-owned component IDs renumbered: $totalIdsRenumbered"
Write-Host "  ID occurrences replaced: $totalOccurrencesChanged"
Write-Host ""

if (-not $Apply) {
    Write-Host "Dry run only. Re-run with -Apply to modify files."
}