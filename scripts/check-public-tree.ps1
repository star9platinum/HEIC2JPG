[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot '.git'))) {
    throw 'This check must be run from a Git working tree.'
}

$tracked = @(& git -c core.quotepath=false -C $repositoryRoot ls-files)
if ($LASTEXITCODE -ne 0) {
    throw 'git ls-files failed.'
}

$forbiddenExtensions = @(
    '.exe', '.dll', '.pdb', '.7z', '.zip',
    '.heic', '.heif', '.jpg', '.jpeg', '.png', '.mov', '.mp4',
    '.dmp', '.log'
)
$forbiddenPrefixes = @(
    'work/', 'outputs/', 'dist/', '.vendor-cache/', 'vendor/'
)

$violations = New-Object System.Collections.Generic.List[string]
foreach ($path in $tracked) {
    $normalized = $path.Trim('"').Replace('\', '/')
    $extensionMatch = [regex]::Match($normalized, '(?i)(\.[^./]+)$')
    $extension = if ($extensionMatch.Success) { $extensionMatch.Value.ToLowerInvariant() } else { '' }
    $lastSlash = $normalized.LastIndexOf('/')
    $fileName = if ($lastSlash -ge 0) { $normalized.Substring($lastSlash + 1) } else { $normalized }

    if ($forbiddenExtensions -contains $extension) {
        $violations.Add("forbidden file type: $normalized")
    }

    if ($fileName.StartsWith('._', [System.StringComparison]::Ordinal)) {
        $violations.Add("AppleDouble metadata: $normalized")
    }

    foreach ($prefix in $forbiddenPrefixes) {
        if ($normalized.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $violations.Add("forbidden generated/cache path: $normalized")
            break
        }
    }
}

if ($violations.Count -gt 0) {
    Write-Host 'Public-tree check failed:' -ForegroundColor Red
    foreach ($violation in $violations) {
        Write-Host "  - $violation" -ForegroundColor Red
    }
    exit 1
}

Write-Host ("Public-tree check passed: {0} tracked files." -f $tracked.Count) -ForegroundColor Green
