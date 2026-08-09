@echo off
rem Copyright (c) 2026 Owen Pu. Licensed under the MIT License.
rem ImageMagick is a separate dependency and is not included in the source repository.
setlocal EnableExtensions DisableDelayedExpansion

set "HEIC_SCRIPT=%~f0"
set "HEIC_TOOL_ROOT=%~dp0"
set "HEIC_TARGET="
if not "%~1"=="" set "HEIC_TARGET=%~f1"

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -Command "$content = Get-Content -LiteralPath $env:HEIC_SCRIPT -Raw; $marker = '# POWERSHELL' + '-BEGIN'; $index = $content.IndexOf($marker); if ($index -lt 0) { exit 2 }; Invoke-Expression $content.Substring($index + $marker.Length)"
set "HEIC_EXIT=%ERRORLEVEL%"

echo.
echo Press any key to close this window...
pause >nul
exit /b %HEIC_EXIT%

# POWERSHELL-BEGIN

$ErrorActionPreference = 'Stop'
$quality = 92
$scriptPath = [System.IO.Path]::GetFullPath($env:HEIC_SCRIPT)
$toolRoot = [System.IO.Path]::GetFullPath($env:HEIC_TOOL_ROOT)
$toolDir = Join-Path $toolRoot 'ImageMagick'
$magick = Join-Path $toolDir 'magick.exe'

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath,

        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $previousPreference = $ErrorActionPreference
    $raw = @()
    $exitCode = -1

    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = $null
        $raw = @(& $FilePath @Arguments 2>&1)
        if ($null -ne $global:LASTEXITCODE) {
            $exitCode = [int] $global:LASTEXITCODE
        }
    }
    catch {
        $raw = @($_)
        $exitCode = -1
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    $lines = foreach ($entry in $raw) {
        if ($entry -is [System.Management.Automation.ErrorRecord]) {
            $entry.Exception.Message
        }
        else {
            [string] $entry
        }
    }

    return [pscustomobject] @{
        ExitCode = $exitCode
        Text = ($lines -join [Environment]::NewLine)
    }
}

function Get-ReadableErrorText {
    param(
        [string] $Text,
        [string] $Fallback
    )

    $value = $Text.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Fallback
    }

    if ($value.Length -gt 2000) {
        return ($value.Substring(0, 2000) + ' ...')
    }

    return $value
}

function Test-JpegStructure {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'Read')
        if ($stream.Length -lt 4) {
            return $false
        }

        if (($stream.ReadByte() -ne 0xFF) -or ($stream.ReadByte() -ne 0xD8)) {
            return $false
        }

        [void] $stream.Seek(-2, [System.IO.SeekOrigin]::End)
        return (($stream.ReadByte() -eq 0xFF) -and ($stream.ReadByte() -eq 0xD9))
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Test-ValidatedJpeg {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-JpegStructure -Path $Path)) {
        return [pscustomobject] @{
            Valid = $false
            Reason = 'The JPEG structure check failed.'
        }
    }

    $identity = Invoke-Native -FilePath $magick -Arguments @(
        'identify', '-quiet', '-format', '%m|%w|%h', $Path
    )
    if (($identity.ExitCode -ne 0) -or ($identity.Text.Trim() -notmatch '^JPEG\|[1-9][0-9]*\|[1-9][0-9]*$')) {
        return [pscustomobject] @{
            Valid = $false
            Reason = 'The JPEG format and dimension check failed.'
        }
    }

    $decode = Invoke-Native -FilePath $magick -Arguments @(
        $Path, '-regard-warnings', 'null:'
    )
    if ($decode.ExitCode -ne 0) {
        return [pscustomobject] @{
            Valid = $false
            Reason = (Get-ReadableErrorText -Text $decode.Text -Fallback 'The JPEG full decode check failed.')
        }
    }

    return [pscustomobject] @{
        Valid = $true
        Reason = ''
    }
}

function Get-StableFileSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $before = Get-Item -LiteralPath $Path -Force
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    $after = Get-Item -LiteralPath $Path -Force

    if (($before.Length -ne $after.Length) -or
        ($before.CreationTimeUtc.Ticks -ne $after.CreationTimeUtc.Ticks) -or
        ($before.LastWriteTimeUtc.Ticks -ne $after.LastWriteTimeUtc.Ticks)) {
        throw 'The file changed while its safety snapshot was being created.'
    }

    return [pscustomobject] @{
        Length = [int64] $after.Length
        CreationTimeUtc = $after.CreationTimeUtc
        CreationTimeTicks = [int64] $after.CreationTimeUtc.Ticks
        LastWriteTimeUtc = $after.LastWriteTimeUtc
        LastWriteTimeTicks = [int64] $after.LastWriteTimeUtc.Ticks
        SHA256 = $hash
    }
}

function Test-SameSourceSnapshot {
    param(
        [Parameter(Mandatory = $true)] $Expected,
        [Parameter(Mandatory = $true)] $Actual
    )

    return (($Expected.Length -eq $Actual.Length) -and
        ($Expected.CreationTimeTicks -eq $Actual.CreationTimeTicks) -and
        ($Expected.LastWriteTimeTicks -eq $Actual.LastWriteTimeTicks) -and
        [string]::Equals($Expected.SHA256, $Actual.SHA256, [System.StringComparison]::OrdinalIgnoreCase))
}

function Select-PhotoFolder {
    if (-not [string]::IsNullOrWhiteSpace($env:HEIC_TARGET)) {
        try {
            $candidate = [System.IO.Path]::GetFullPath($env:HEIC_TARGET)
        }
        catch {
            throw 'The dragged folder path is invalid.'
        }

        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
            throw 'Please drag a folder, not a file, onto this CMD.'
        }

        return (Get-Item -LiteralPath $candidate).FullName
    }

    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Choose the photo folder. All subfolders will be included.'
    $dialog.ShowNewFolderButton = $false

    try {
        $result = $dialog.ShowDialog()
        if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
            return $null
        }

        if (-not (Test-Path -LiteralPath $dialog.SelectedPath -PathType Container)) {
            throw 'The selected location is not a local file-system folder.'
        }

        return (Get-Item -LiteralPath $dialog.SelectedPath).FullName
    }
    finally {
        $dialog.Dispose()
    }
}

Write-Host ''
Write-Host 'Offline HEIC -> JPG converter for Windows'
Write-Host 'No download or installation is used.'
Write-Host ''

if (-not (Test-Path -LiteralPath $magick -PathType Leaf)) {
    Write-Host 'ERROR: The bundled ImageMagick runtime is missing.' -ForegroundColor Red
    Write-Host 'Extract the entire ZIP first, then run the CMD from the extracted folder.'
    exit 1
}

$env:MAGICK_HOME = $toolDir
$env:Path = $toolDir + ';' + $env:Path

$formatProbe = Invoke-Native -FilePath $magick -Arguments @('-list', 'format')
if ($formatProbe.ExitCode -ne 0) {
    Write-Host 'ERROR: The bundled ImageMagick runtime could not start.' -ForegroundColor Red
    Write-Host (Get-ReadableErrorText -Text $formatProbe.Text -Fallback 'No diagnostic text was returned.')
    exit 1
}

$heicMatch = [regex]::Match($formatProbe.Text, '(?mi)^\s*HEIC\*?\s+(\S+)')
if ((-not $heicMatch.Success) -or (-not $heicMatch.Groups[1].Value.StartsWith('r'))) {
    Write-Host 'ERROR: The bundled runtime does not have HEIC read support.' -ForegroundColor Red
    exit 1
}

try {
    $root = Select-PhotoFolder
}
catch {
    Write-Host ('ERROR: {0}' -f $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Tip: drag a local photo folder onto this CMD and try again.'
    exit 1
}

if ([string]::IsNullOrWhiteSpace($root)) {
    Write-Host 'Cancelled. No photos were changed.'
    exit 0
}

Write-Host ('Folder: {0}' -f $root)
Write-Host 'Subfolders are included.'
Write-Host 'All HEIC originals stay in place during conversion and manual review.'
Write-Host 'An existing same-name JPG is replaced only after conversion succeeds.'
Write-Host ''

$scanErrors = @()
$files = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable scanErrors |
    Where-Object { $_.Extension -ieq '.heic' } |
    Sort-Object FullName)

$found = $files.Count
$converted = 0
$failed = 0
$convertedRecords = New-Object System.Collections.ArrayList

foreach ($scanError in @($scanErrors)) {
    Write-Host ('Scan warning: {0}' -f $scanError.Exception.Message) -ForegroundColor Yellow
}

if (@($scanErrors).Count -gt 0) {
    Write-Host ''
    Write-Host 'SAFETY STOP: The folder scan was incomplete. No files were converted or deleted.' -ForegroundColor Red
    exit 1
}

if ($found -eq 0) {
    Write-Host 'No HEIC files were found.'
    exit 0
}

foreach ($file in $files) {
    $output = [System.IO.Path]::ChangeExtension($file.FullName, '.jpg')
    $temporary = Join-Path $file.DirectoryName ('.heicjpg-' + [Guid]::NewGuid().ToString('N') + '.jpg')
    $inputFrame = $file.FullName + '[0]'

    Write-Host ('Convert: {0}' -f $file.FullName)

    try {
        $sourceSnapshot = Get-StableFileSnapshot -Path $file.FullName

        $conversion = Invoke-Native -FilePath $magick -Arguments @(
            $inputFrame,
            '-auto-orient',
            '-quality', [string] $quality,
            $temporary
        )

        if ($conversion.ExitCode -ne 0) {
            throw (Get-ReadableErrorText -Text $conversion.Text -Fallback 'ImageMagick conversion failed.')
        }

        $validation = Test-ValidatedJpeg -Path $temporary
        if (-not $validation.Valid) {
            throw $validation.Reason
        }

        $sourceAfterConversion = Get-StableFileSnapshot -Path $file.FullName
        if (-not (Test-SameSourceSnapshot -Expected $sourceSnapshot -Actual $sourceAfterConversion)) {
            throw 'The source HEIC changed during conversion.'
        }

        Move-Item -LiteralPath $temporary -Destination $output -Force

        try {
            $outputItem = Get-Item -LiteralPath $output
            $outputItem.CreationTimeUtc = $sourceSnapshot.CreationTimeUtc
            $outputItem.LastWriteTimeUtc = $sourceSnapshot.LastWriteTimeUtc
        }
        catch {
            Write-Host ('Timestamp warning: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        }

        $outputSnapshot = Get-StableFileSnapshot -Path $output

        $converted++
        [void] $convertedRecords.Add([pscustomobject] @{
            SourcePath = $file.FullName
            OutputPath = $output
            SourceSnapshot = $sourceSnapshot
            OutputSnapshot = $outputSnapshot
        })
    }
    catch {
        Write-Host ('FAILED, original kept: {0}' -f $file.FullName) -ForegroundColor Red
        Write-Host ('  {0}' -f $_.Exception.Message) -ForegroundColor Red
        $failed++
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }

}

Write-Host ''
Write-Host ('Conversion finished: {0} found, {1} converted and validated, {2} errors.' -f $found, $converted, $failed)
Write-Host 'No HEIC originals have been deleted.' -ForegroundColor Green

if (($failed -gt 0) -or ($converted -ne $found)) {
    Write-Host ''
    Write-Host 'SAFETY STOP: Not every HEIC file converted successfully.' -ForegroundColor Red
    Write-Host 'Automatic deletion is disabled. All remaining HEIC files are kept.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'The photo folder will now open in File Explorer.'
Write-Host 'Manually inspect the JPG files before returning to this window.' -ForegroundColor Yellow

try {
    Invoke-Item -LiteralPath $root -ErrorAction Stop
}
catch {
    Write-Host ('SAFETY STOP: File Explorer could not be opened: {0}' -f $_.Exception.Message) -ForegroundColor Red
    Write-Host 'No HEIC files were deleted.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'If every JPG looks correct, type this exact phrase:' -ForegroundColor Yellow
Write-Host 'DELETE ALL HEIC' -ForegroundColor Cyan
$confirmation = Read-Host 'Confirmation'

if ($confirmation -cne 'DELETE ALL HEIC') {
    Write-Host ''
    Write-Host 'Deletion cancelled. All HEIC originals were kept.' -ForegroundColor Green
    exit 0
}

Write-Host ''
Write-Host 'Running final safety checks before deleting any HEIC files...'
$preDeleteErrors = 0

$finalScanErrors = @()
$currentHeicFiles = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable finalScanErrors |
    Where-Object { $_.Extension -ieq '.heic' })

if (@($finalScanErrors).Count -gt 0) {
    foreach ($scanError in @($finalScanErrors)) {
        Write-Host ('Final scan warning: {0}' -f $scanError.Exception.Message) -ForegroundColor Red
    }
    $preDeleteErrors++
}

$expectedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$currentPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($record in $convertedRecords) {
    [void] $expectedPaths.Add([System.IO.Path]::GetFullPath($record.SourcePath))
}
foreach ($currentFile in $currentHeicFiles) {
    [void] $currentPaths.Add([System.IO.Path]::GetFullPath($currentFile.FullName))
}

if (($expectedPaths.Count -ne $currentPaths.Count) -or (-not $expectedPaths.SetEquals($currentPaths))) {
    Write-Host 'Safety check failed: the HEIC file set changed during manual review.' -ForegroundColor Red
    $preDeleteErrors++
}

foreach ($record in $convertedRecords) {
    try {
        if (-not (Test-Path -LiteralPath $record.SourcePath -PathType Leaf)) {
            throw 'The source HEIC is missing or was moved during review.'
        }

        $currentSourceSnapshot = Get-StableFileSnapshot -Path $record.SourcePath
        if (-not (Test-SameSourceSnapshot -Expected $record.SourceSnapshot -Actual $currentSourceSnapshot)) {
            throw 'The source HEIC changed during review.'
        }

        $currentOutputSnapshot = Get-StableFileSnapshot -Path $record.OutputPath
        if (($currentOutputSnapshot.Length -ne $record.OutputSnapshot.Length) -or
            (-not [string]::Equals($currentOutputSnapshot.SHA256, $record.OutputSnapshot.SHA256, [System.StringComparison]::OrdinalIgnoreCase))) {
            throw 'The generated JPG changed during review.'
        }

        $finalValidation = Test-ValidatedJpeg -Path $record.OutputPath
        if (-not $finalValidation.Valid) {
            throw ('The reviewed JPG is no longer valid: {0}' -f $finalValidation.Reason)
        }
    }
    catch {
        Write-Host ('Safety check failed: {0}' -f $record.SourcePath) -ForegroundColor Red
        Write-Host ('  {0}' -f $_.Exception.Message) -ForegroundColor Red
        $preDeleteErrors++
    }
}

if ($preDeleteErrors -gt 0) {
    Write-Host ''
    Write-Host ('SAFETY STOP: {0} final checks failed. No HEIC files were deleted.' -f $preDeleteErrors) -ForegroundColor Red
    exit 1
}

$deleted = 0
$deleteErrors = 0

foreach ($record in $convertedRecords) {
    try {
        $sourceItem = Get-Item -LiteralPath $record.SourcePath -Force
        if (($sourceItem.Length -ne $record.SourceSnapshot.Length) -or
            ($sourceItem.CreationTimeUtc.Ticks -ne $record.SourceSnapshot.CreationTimeTicks) -or
            ($sourceItem.LastWriteTimeUtc.Ticks -ne $record.SourceSnapshot.LastWriteTimeTicks)) {
            throw 'The source HEIC changed immediately before deletion.'
        }

        Remove-Item -LiteralPath $record.SourcePath -Force
        $deleted++
    }
    catch {
        Write-Host ('Could not delete original: {0}' -f $record.SourcePath) -ForegroundColor Red
        Write-Host ('  {0}' -f $_.Exception.Message) -ForegroundColor Red
        $deleteErrors++
    }
}

Write-Host ''
Write-Host ('Done: {0} JPG files verified, {1} HEIC originals deleted, {2} deletion errors.' -f $converted, $deleted, $deleteErrors)

if ($deleteErrors -gt 0) {
    exit 1
}

exit 0
