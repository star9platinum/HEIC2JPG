@echo off
rem Copyright (c) 2026 Owen Pu. Licensed under the MIT License.
chcp 65001 >nul
setlocal EnableExtensions DisableDelayedExpansion

set "HEIC_CLEANER_SCRIPT=%~f0"
set "HEIC_CLEANER_ARG_COUNT=0"

:collect_arguments
if "%~1"=="" goto arguments_collected
set /a HEIC_CLEANER_ARG_COUNT+=1
for %%N in (%HEIC_CLEANER_ARG_COUNT%) do set "HEIC_CLEANER_ARG_%%N=%~1"
shift
goto collect_arguments

:arguments_collected
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -Command "$content = Get-Content -LiteralPath $env:HEIC_CLEANER_SCRIPT -Raw -Encoding UTF8; $marker = '# POWERSHELL' + '-BEGIN'; $index = $content.IndexOf($marker); if ($index -lt 0) { exit 2 }; Invoke-Expression $content.Substring($index + $marker.Length)"
set "HEIC_CLEANER_EXIT=%ERRORLEVEL%"

if "%HEIC2JPG_TEST_MODE%"=="1" exit /b %HEIC_CLEANER_EXIT%
echo.
echo 按任意键关闭窗口...
pause >nul
exit /b %HEIC_CLEANER_EXIT%

# POWERSHELL-BEGIN

$ErrorActionPreference = 'Stop'
$toolRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetDirectoryName($env:HEIC_CLEANER_SCRIPT))
$testPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\HEIC2JPG-WindowsTests-'
$testMode = (($env:HEIC2JPG_TEST_MODE -eq '1') -and
    $toolRoot.StartsWith($testPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
    (Test-Path -LiteralPath (Join-Path $toolRoot '.HEIC2JPG-TEST-ONLY') -PathType Leaf))

function Show-Usage {
    Write-Host '用法：清理HEIC2JPG临时文件.cmd [照片文件夹一] [照片文件夹二] ...'
    Write-Host ''
    Write-Host '不指定目录时会弹出选择器，可逐次添加多个根目录。'
    Write-Host '只匹配本项目精确命名的 Windows 新旧临时项；输入 y 或 Y 后才删除。'
}

function Select-PhotoFolders {
    if ($testMode -and (-not [string]::IsNullOrWhiteSpace($env:HEIC2JPG_TEST_PICKER_PATHS))) {
        return @($env:HEIC2JPG_TEST_PICKER_PATHS -split '[\r\n;]+' | Where-Object { $_ })
    }

    Add-Type -AssemblyName System.Windows.Forms
    $selected = New-Object System.Collections.ArrayList
    while ($true) {
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = if ($selected.Count -eq 0) {
            '选择需要彻底清理 HEIC2JPG 临时项的照片根目录'
        }
        else { '继续选择另一个照片根目录' }
        $dialog.ShowNewFolderButton = $false
        try {
            if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { break }
            [void] $selected.Add($dialog.SelectedPath)
        }
        finally { $dialog.Dispose() }

        $choice = [System.Windows.Forms.MessageBox]::Show(
            '是否继续添加另一个照片根文件夹？',
            'HEIC2JPG 临时文件清理',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { break }
    }
    return @($selected)
}

function Normalize-Roots {
    param([string[]] $Paths)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $result = New-Object System.Collections.ArrayList
    foreach ($path in @($Paths)) {
        try { $candidate = [System.IO.Path]::GetFullPath($path) }
        catch { throw ('目录路径无效：{0}' -f $path) }
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
            throw ('不是有效的本地文件夹：{0}' -f $candidate)
        }
        $item = Get-Item -LiteralPath $candidate -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw ('根目录不能是符号链接或重解析点：{0}' -f $candidate)
        }
        if ($seen.Add($item.FullName)) { [void] $result.Add($item.FullName) }
    }
    return @($result)
}

function Get-CandidateSize {
    param([Parameter(Mandatory = $true)] $Item)
    if (-not $Item.PSIsContainer) { return [int64] $Item.Length }
    $errors = @()
    $sum = [int64] 0
    foreach ($file in @(Get-ChildItem -LiteralPath $Item.FullName -File -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable errors)) {
        $sum += [int64] $file.Length
    }
    if ($errors.Count -gt 0) { throw '无法完整计算目录大小。' }
    return $sum
}

function Read-Confirmation {
    if ($testMode) { return [string] $env:HEIC2JPG_TEST_CONFIRMATION }
    return (Read-Host '确认输入')
}

$rawArguments = New-Object System.Collections.ArrayList
$argumentCount = 0
[void] [int]::TryParse($env:HEIC_CLEANER_ARG_COUNT, [ref] $argumentCount)
for ($i = 1; $i -le $argumentCount; $i++) {
    [void] $rawArguments.Add([Environment]::GetEnvironmentVariable('HEIC_CLEANER_ARG_' + $i))
}

if (($rawArguments.Count -eq 1) -and ([string] $rawArguments[0] -eq '-h')) {
    Show-Usage
    exit 0
}
foreach ($argument in $rawArguments) {
    if (([string] $argument).StartsWith('-')) {
        Write-Host ('错误：未知选项 {0}' -f $argument) -ForegroundColor Red
        Show-Usage
        exit 2
    }
}

try {
    if ($rawArguments.Count -eq 0) { $rawArguments = @(Select-PhotoFolders) }
    $roots = @(Normalize-Roots -Paths @($rawArguments))
}
catch {
    Write-Host ('错误：{0}' -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'HEIC2JPG 临时文件清理工具'
Write-Host '请先确认没有任何 HEIC2JPG 转换任务正在运行。' -ForegroundColor Yellow
Write-Host '会彻底清理所选目录中的项目临时项，不会删除 HEIC 或最终同名 JPG。'
Write-Host ''

if ($roots.Count -eq 0) {
    Write-Host '没有选择目录，已取消。'
    exit 0
}

$candidates = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::OrdinalIgnoreCase)
$scanErrors = New-Object System.Collections.ArrayList
foreach ($root in $roots) {
    Write-Host ('扫描：{0}' -f $root)
    $localErrors = @()
    $items = @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable localErrors)
    foreach ($errorRecord in @($localErrors)) { [void] $scanErrors.Add($errorRecord) }
    foreach ($item in $items) {
        $isNewDirectory = $item.PSIsContainer -and ($item.Name -match '^\.HEIC2JPG\.convert\.[0-9a-f]{32}$')
        $isLegacyFile = (-not $item.PSIsContainer) -and ($item.Name -match '^\.heicjpg-[0-9a-f]{32}\.jpg$')
        $isReparsePoint = (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
        if (($isNewDirectory -or $isLegacyFile) -and (-not $isReparsePoint) -and
            (-not $candidates.ContainsKey($item.FullName))) {
            $candidates.Add($item.FullName, $item)
        }
    }
}

if ($scanErrors.Count -gt 0) {
    foreach ($scanError in $scanErrors) {
        Write-Host ('扫描错误：{0}' -f $scanError.Exception.Message) -ForegroundColor Red
    }
    Write-Host '安全停止：目录扫描不完整，没有删除任何内容。' -ForegroundColor Red
    exit 1
}

$ordered = @($candidates.Values | Sort-Object FullName)
if ($ordered.Count -eq 0) {
    Write-Host '没有发现本项目的 Windows 临时项。'
    exit 0
}

$totalBytes = [int64] 0
try {
    foreach ($candidate in $ordered) {
        $size = Get-CandidateSize -Item $candidate
        $totalBytes += $size
        Write-Host ('  {0}  ({1:N2} MB)' -f $candidate.FullName, ($size / 1MB))
    }
}
catch {
    Write-Host ('安全停止：无法完整计算候选项大小：{0}' -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host ('共找到 {0} 个候选项，约 {1:N2} MB。' -f $ordered.Count, ($totalBytes / 1MB))
Write-Host '确认当前没有转换任务后，输入 y 或 Y 彻底删除；其他输入取消。' -ForegroundColor Yellow
$confirmation = Read-Confirmation
if (($confirmation -cne 'y') -and ($confirmation -cne 'Y')) {
    Write-Host '已取消，没有删除任何内容。'
    exit 0
}

$deleted = 0
$failed = 0
foreach ($candidate in $ordered) {
    try {
        $current = Get-Item -LiteralPath $candidate.FullName -Force -ErrorAction Stop
        $validName = ($current.PSIsContainer -and ($current.Name -match '^\.HEIC2JPG\.convert\.[0-9a-f]{32}$')) -or
            ((-not $current.PSIsContainer) -and ($current.Name -match '^\.heicjpg-[0-9a-f]{32}\.jpg$'))
        if ((-not $validName) -or (($current.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw '候选项类型或名称发生变化。'
        }
        if ($current.PSIsContainer) { Remove-Item -LiteralPath $current.FullName -Recurse -Force -ErrorAction Stop }
        else { Remove-Item -LiteralPath $current.FullName -Force -ErrorAction Stop }
        $deleted++
    }
    catch {
        Write-Host ('删除失败：{0}' -f $candidate.FullName) -ForegroundColor Red
        Write-Host ('  {0}' -f $_.Exception.Message) -ForegroundColor Red
        $failed++
    }
}

Write-Host ''
Write-Host ('清理完成：删除 {0} 个，失败 {1} 个。' -f $deleted, $failed)
if ($failed -gt 0) { exit 1 }
exit 0
