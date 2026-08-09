[CmdletBinding()]
param(
    [string] $ArchivePath,
    [string] $OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$archiveName = 'ImageMagick-7.1.2-29-portable-Q16-HDRI-x64.7z'
$expectedArchiveHash = 'B68E312B21556AE8872704E37DF3C69CBDC0EA7100366BF823E7E3A1B69405BC'
$packageName = 'HEIC_to_JPG_Offline_Windows_x64'

if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
    $ArchivePath = Join-Path (Join-Path $repositoryRoot '.vendor-cache') $archiveName
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repositoryRoot 'dist'
}

$archiveFullPath = [System.IO.Path]::GetFullPath($ArchivePath)
$outputFullPath = [System.IO.Path]::GetFullPath($OutputDirectory)

if (-not (Test-Path -LiteralPath $archiveFullPath -PathType Leaf)) {
    throw "Official ImageMagick archive not found: $archiveFullPath"
}

Write-Host 'Verifying the local ImageMagick archive...'
$actualArchiveHash = (Get-FileHash -LiteralPath $archiveFullPath -Algorithm SHA256).Hash
if (-not [string]::Equals($actualArchiveHash, $expectedArchiveHash, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Archive SHA-256 mismatch. Expected $expectedArchiveHash but found $actualArchiveHash."
}

$tarCommand = Get-Command tar.exe -ErrorAction Stop
$temporaryBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$temporaryRoot = Join-Path $temporaryBase ('HEIC2JPG-' + [Guid]::NewGuid().ToString('N'))
$extractRoot = Join-Path $temporaryRoot 'runtime'
$packageStaging = Join-Path $temporaryRoot $packageName
$runtimeDestination = Join-Path $packageStaging 'ImageMagick'
$stagingZip = Join-Path $temporaryRoot ($packageName + '.zip')

$runtimeFiles = @(
    'magick.exe',
    'colors.xml',
    'configure.xml',
    'delegates.xml',
    'english.xml',
    'locale.xml',
    'log.xml',
    'mime.xml',
    'policy.xml',
    'thresholds.xml',
    'type-ghostscript.xml',
    'type.xml',
    'sRGB.icc',
    'LICENSE.txt',
    'NOTICE.txt'
)

try {
    [void] (New-Item -ItemType Directory -Path $extractRoot)
    [void] (New-Item -ItemType Directory -Path $runtimeDestination)

    Write-Host 'Extracting the verified local archive (no network access is used)...'
    & $tarCommand.Source -xf $archiveFullPath -C $extractRoot
    if ($LASTEXITCODE -ne 0) {
        throw "tar.exe could not extract the archive (exit code $LASTEXITCODE)."
    }

    $magickCandidates = @(Get-ChildItem -LiteralPath $extractRoot -Filter 'magick.exe' -File -Recurse)
    if ($magickCandidates.Count -ne 1) {
        throw "Expected exactly one magick.exe in the official archive; found $($magickCandidates.Count)."
    }
    $runtimeSource = $magickCandidates[0].DirectoryName

    foreach ($fileName in $runtimeFiles) {
        $sourcePath = Join-Path $runtimeSource $fileName
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Required runtime file is missing from the official archive: $fileName"
        }
        Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $runtimeDestination $fileName)
    }

    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'src\windows\HEIC_to_JPG_Offline.cmd') -Destination $packageStaging
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'packaging\windows\README-Windows.txt') -Destination $packageStaging
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'packaging\windows\RUNTIME_SOURCE_AND_LICENSE.txt') -Destination $packageStaging

    $env:MAGICK_HOME = $runtimeDestination
    $runtimeProbe = @(& (Join-Path $runtimeDestination 'magick.exe') -list format 2>&1)
    if (($LASTEXITCODE -ne 0) -or (($runtimeProbe -join [Environment]::NewLine) -notmatch '(?mi)^\s*HEIC\*?\s+r')) {
        throw 'The assembled ImageMagick runtime does not report HEIC read support.'
    }

    Write-Host 'Creating the local offline ZIP...'
    Compress-Archive -LiteralPath $packageStaging -DestinationPath $stagingZip -CompressionLevel Optimal

    [void] (New-Item -ItemType Directory -Path $outputFullPath -Force)
    $finalDirectory = Join-Path $outputFullPath $packageName
    $finalZip = Join-Path $outputFullPath ($packageName + '.zip')
    $finalChecksum = $finalZip + '.sha256'

    foreach ($destination in @($finalDirectory, $finalZip, $finalChecksum)) {
        if (Test-Path -LiteralPath $destination) {
            throw "Output already exists; move or delete it before rebuilding: $destination"
        }
    }

    Move-Item -LiteralPath $packageStaging -Destination $finalDirectory
    Move-Item -LiteralPath $stagingZip -Destination $finalZip

    $zipHash = (Get-FileHash -LiteralPath $finalZip -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText(
        $finalChecksum,
        ($zipHash + '  ' + [System.IO.Path]::GetFileName($finalZip) + [Environment]::NewLine),
        [System.Text.Encoding]::ASCII
    )

    Write-Host ''
    Write-Host 'Local offline package created:' -ForegroundColor Green
    Write-Host "  Directory: $finalDirectory"
    Write-Host "  ZIP:       $finalZip"
    Write-Host "  SHA-256:   $zipHash"
    Write-Host ''
    Write-Host 'The generated package is ignored by Git. Review third-party obligations before redistributing it.' -ForegroundColor Yellow
}
finally {
    $temporaryFullPath = [System.IO.Path]::GetFullPath($temporaryRoot)
    $safePrefix = $temporaryBase.TrimEnd('\') + '\HEIC2JPG-'
    if ((Test-Path -LiteralPath $temporaryFullPath) -and
        $temporaryFullPath.StartsWith($safePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $temporaryFullPath -Recurse -Force
    }
}
