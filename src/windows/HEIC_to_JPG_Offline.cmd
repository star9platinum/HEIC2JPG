@echo off
rem Copyright (c) 2026 Owen Pu. Licensed under the MIT License.
rem ImageMagick is a separate dependency and is not included in the source repository.
chcp 65001 >nul
setlocal EnableExtensions DisableDelayedExpansion

set "HEIC_SCRIPT=%~f0"
set "HEIC_TOOL_ROOT=%~dp0"
set "HEIC_ARG_COUNT=0"

:collect_arguments
if "%~1"=="" goto arguments_collected
set /a HEIC_ARG_COUNT+=1
for %%N in (%HEIC_ARG_COUNT%) do set "HEIC_ARG_%%N=%~1"
shift
goto collect_arguments

:arguments_collected
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -Command "$content = Get-Content -LiteralPath $env:HEIC_SCRIPT -Raw -Encoding UTF8; $marker = '# POWERSHELL' + '-BEGIN'; $index = $content.IndexOf($marker); if ($index -lt 0) { exit 2 }; Invoke-Expression $content.Substring($index + $marker.Length)"
set "HEIC_EXIT=%ERRORLEVEL%"

if "%HEIC2JPG_TEST_MODE%"=="1" exit /b %HEIC_EXIT%
echo.
echo 按任意键关闭窗口...
pause >nul
exit /b %HEIC_EXIT%

# POWERSHELL-BEGIN

$ErrorActionPreference = 'Stop'
$quality = 90
$overwrite = $false
$strictMode = $false
$showHelp = $false
$receiptWarnings = 0
$scriptPath = [System.IO.Path]::GetFullPath($env:HEIC_SCRIPT)
$toolRoot = [System.IO.Path]::GetFullPath($env:HEIC_TOOL_ROOT)
$toolDir = Join-Path $toolRoot 'ImageMagick'
$magick = Join-Path $toolDir 'magick.exe'
$testMode = $false
$testPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\HEIC2JPG-WindowsTests-'
if (($env:HEIC2JPG_TEST_MODE -eq '1') -and
    $toolRoot.StartsWith($testPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
    (Test-Path -LiteralPath (Join-Path $toolRoot '.HEIC2JPG-TEST-ONLY') -PathType Leaf)) {
    $testMode = $true
}

function Show-Usage {
    Write-Host '用法：'
    Write-Host '  双击 HEIC_to_JPG_Offline.cmd'
    Write-Host '  HEIC_to_JPG_Offline.cmd [选项] [目录一] [目录二] ...'
    Write-Host ''
    Write-Host '选项：'
    Write-Host '  -f          重新转换并替换已有的同名普通 JPG'
    Write-Host '  -s          严格模式：启用 SHA-256 指纹和完整删除前复检'
    Write-Host '  -q 1..100   设置 JPG 质量（默认 90）'
    Write-Host '  -h          显示帮助'
    Write-Host '  --          结束选项解析'
}

function New-NativeResult {
    param([int] $ExitCode, [string] $Text)
    return [pscustomobject] @{ ExitCode = $ExitCode; Text = $Text }
}

function Test-JpegStructure {
    param([Parameter(Mandatory = $true)][string] $Path)

    $stream = $null
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
            return $false
        }
        $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'Read')
        if ($stream.Length -lt 4) { return $false }
        if (($stream.ReadByte() -ne 0xFF) -or ($stream.ReadByte() -ne 0xD8)) { return $false }
        [void] $stream.Seek(-2, [System.IO.SeekOrigin]::End)
        return (($stream.ReadByte() -eq 0xFF) -and ($stream.ReadByte() -eq 0xD9))
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )

    $previousPreference = $ErrorActionPreference
    $raw = @()
    $exitCode = -1
    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = $null
        $raw = @(& $FilePath @Arguments 2>&1)
        if ($null -ne $global:LASTEXITCODE) { $exitCode = [int] $global:LASTEXITCODE }
    }
    catch {
        $raw = @($_)
        $exitCode = -1
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    $lines = foreach ($entry in $raw) {
        if ($entry -is [System.Management.Automation.ErrorRecord]) { $entry.Exception.Message }
        else { [string] $entry }
    }
    return (New-NativeResult -ExitCode $exitCode -Text ($lines -join [Environment]::NewLine))
}

function Get-ReadableErrorText {
    param([string] $Text, [string] $Fallback)
    $value = ([string] $Text).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return $Fallback }
    if ($value.Length -gt 2000) { return ($value.Substring(0, 2000) + ' ...') }
    return $value
}

function Test-RegularNonEmptyFile {
    param([Parameter(Mandatory = $true)][string] $Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return ((-not $item.PSIsContainer) -and
            (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) -and
            ($item.Length -gt 0))
    }
    catch { return $false }
}

function Test-ValidatedJpeg {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-JpegStructure -Path $Path)) {
        return [pscustomobject] @{ Valid = $false; Reason = 'JPG 文件头或文件尾检查失败。' }
    }

    $identity = Invoke-Native -FilePath $magick -Arguments @(
        'identify', '-quiet', '-format', '%m|%w|%h', $Path
    )
    if (($identity.ExitCode -ne 0) -or ($identity.Text.Trim() -notmatch '^JPEG\|[1-9][0-9]*\|[1-9][0-9]*$')) {
        return [pscustomobject] @{ Valid = $false; Reason = 'JPG 格式或尺寸检查失败。' }
    }

    # Windows 特意保留 ImageMagick null:：完整解码但不生成验证图片。
    $decode = Invoke-Native -FilePath $magick -Arguments @($Path, '-regard-warnings', 'null:')
    if ($decode.ExitCode -ne 0) {
        return [pscustomobject] @{
            Valid = $false
            Reason = (Get-ReadableErrorText -Text $decode.Text -Fallback 'JPG 完整解码检查失败。')
        }
    }
    return [pscustomobject] @{ Valid = $true; Reason = '' }
}

function Get-LightweightSnapshot {
    param([Parameter(Mandatory = $true)][string] $Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw '文件不是普通文件，或是符号链接/重解析点。'
    }
    return [pscustomobject] @{
        Length = [int64] $item.Length
        CreationTimeUtc = $item.CreationTimeUtc
        CreationTimeTicks = [int64] $item.CreationTimeUtc.Ticks
        LastWriteTimeUtc = $item.LastWriteTimeUtc
        LastWriteTimeTicks = [int64] $item.LastWriteTimeUtc.Ticks
    }
}

function Test-SameLightweightSnapshot {
    param([Parameter(Mandatory = $true)] $Expected, [Parameter(Mandatory = $true)] $Actual)
    return (($Expected.Length -eq $Actual.Length) -and
        ($Expected.CreationTimeTicks -eq $Actual.CreationTimeTicks) -and
        ($Expected.LastWriteTimeTicks -eq $Actual.LastWriteTimeTicks))
}

function Get-StableFileSnapshot {
    param([Parameter(Mandatory = $true)][string] $Path)
    $before = Get-LightweightSnapshot -Path $Path
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    $after = Get-LightweightSnapshot -Path $Path
    if (-not (Test-SameLightweightSnapshot -Expected $before -Actual $after)) {
        throw '创建安全快照期间文件发生了变化。'
    }
    return [pscustomobject] @{
        Length = $after.Length
        CreationTimeUtc = $after.CreationTimeUtc
        CreationTimeTicks = $after.CreationTimeTicks
        LastWriteTimeUtc = $after.LastWriteTimeUtc
        LastWriteTimeTicks = $after.LastWriteTimeTicks
        SHA256 = $hash
    }
}

function Test-SameStrictSnapshot {
    param([Parameter(Mandatory = $true)] $Expected, [Parameter(Mandatory = $true)] $Actual)
    return ((Test-SameLightweightSnapshot -Expected $Expected -Actual $Actual) -and
        [string]::Equals($Expected.SHA256, $Actual.SHA256, [System.StringComparison]::OrdinalIgnoreCase))
}

$receiptVersionStream = 'HEIC2JPG.ReceiptVersion'
$receiptSourceStream = 'HEIC2JPG.SourceSHA256'
$receiptOutputStream = 'HEIC2JPG.OutputSHA256'

function Remove-ResumeReceipt {
    param([Parameter(Mandatory = $true)][string] $Path)
    foreach ($name in @($receiptVersionStream, $receiptSourceStream, $receiptOutputStream)) {
        Remove-Item -LiteralPath $Path -Stream $name -Force -ErrorAction SilentlyContinue
    }
}

function Read-ResumeReceipt {
    param([Parameter(Mandatory = $true)][string] $Path)
    try {
        $version = ([string] (Get-Content -LiteralPath $Path -Stream $receiptVersionStream -Raw -ErrorAction Stop)).Trim()
        $sourceHash = ([string] (Get-Content -LiteralPath $Path -Stream $receiptSourceStream -Raw -ErrorAction Stop)).Trim()
        $outputHash = ([string] (Get-Content -LiteralPath $Path -Stream $receiptOutputStream -Raw -ErrorAction Stop)).Trim()
        if (($version -ne '1') -or ($sourceHash -notmatch '^[0-9A-Fa-f]{64}$') -or
            ($outputHash -notmatch '^[0-9A-Fa-f]{64}$')) { return $null }
        return [pscustomobject] @{ SourceSHA256 = $sourceHash; OutputSHA256 = $outputHash }
    }
    catch { return $null }
}

function Write-ResumeReceipt {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $SourceSHA256,
        [Parameter(Mandatory = $true)][string] $OutputSHA256
    )
    try {
        Set-Content -LiteralPath $Path -Stream $receiptVersionStream -Value '1' -NoNewline -Encoding ASCII
        Set-Content -LiteralPath $Path -Stream $receiptSourceStream -Value $SourceSHA256 -NoNewline -Encoding ASCII
        Set-Content -LiteralPath $Path -Stream $receiptOutputStream -Value $OutputSHA256 -NoNewline -Encoding ASCII
        $receipt = Read-ResumeReceipt -Path $Path
        if (($null -eq $receipt) -or
            (-not [string]::Equals($receipt.SourceSHA256, $SourceSHA256, [System.StringComparison]::OrdinalIgnoreCase)) -or
            (-not [string]::Equals($receipt.OutputSHA256, $OutputSHA256, [System.StringComparison]::OrdinalIgnoreCase))) {
            throw '回读指纹失败。'
        }
        return $true
    }
    catch {
        Remove-ResumeReceipt -Path $Path
        return $false
    }
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
            '选择包含 HEIC 照片的根文件夹（会包含所有子文件夹）'
        }
        else { '继续选择另一个照片根文件夹' }
        $dialog.ShowNewFolderButton = $false
        try {
            if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { break }
            [void] $selected.Add($dialog.SelectedPath)
        }
        finally { $dialog.Dispose() }

        $choice = [System.Windows.Forms.MessageBox]::Show(
            '是否继续添加另一个照片根文件夹？',
            'HEIC2JPG 多目录选择',
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

function Get-HeicScan {
    param([string[]] $Roots)
    $unique = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $hidden = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $errors = New-Object System.Collections.ArrayList
    foreach ($root in $Roots) {
        $localErrors = @()
        $items = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable localErrors |
            Where-Object { $_.Extension -ieq '.heic' })
        foreach ($errorRecord in @($localErrors)) { [void] $errors.Add($errorRecord) }
        foreach ($item in $items) {
            if ($item.Name.StartsWith('.', [System.StringComparison]::Ordinal)) {
                if (-not $hidden.ContainsKey($item.FullName)) { $hidden.Add($item.FullName, $item) }
            }
            elseif (-not $unique.ContainsKey($item.FullName)) { $unique.Add($item.FullName, $item) }
        }
    }
    return [pscustomobject] @{
        Files = @($unique.Values | Sort-Object FullName)
        Hidden = @($hidden.Values | Sort-Object FullName)
        Errors = @($errors)
    }
}

function New-ConversionTempDirectory {
    param([Parameter(Mandatory = $true)][string] $Parent)
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $name = '.HEIC2JPG.convert.' + [Guid]::NewGuid().ToString('N')
        $path = Join-Path $Parent $name
        if (-not (Test-Path -LiteralPath $path)) {
            [void] [System.IO.Directory]::CreateDirectory($path)
            $marker = Join-Path $path '.HEIC2JPG-TEMP-MARKER'
            @('HEIC2JPG_TEMP_V1', 'kind=convert', ('pid=' + $PID), ('created=' + [DateTime]::UtcNow.ToString('o'))) |
                Set-Content -LiteralPath $marker -Encoding UTF8
            return $path
        }
    }
    throw '无法在照片所在磁盘创建转换临时目录。'
}

function Remove-ConversionTempDirectory {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $leaf = [System.IO.Path]::GetFileName($Path)
    if ($leaf -match '^\.HEIC2JPG\.convert\.[0-9a-f]{32}$' -and (Test-Path -LiteralPath $Path -PathType Container)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Open-ReviewFolders {
    param([string[]] $Roots)
    if ($testMode) {
        switch ($env:HEIC2JPG_TEST_OPEN_ACTION) {
            'delete-first-jpg' {
                $first = Get-ChildItem -LiteralPath $Roots[0] -Filter '*.jpg' -File -Recurse | Select-Object -First 1
                if ($null -ne $first) { Remove-Item -LiteralPath $first.FullName -Force }
            }
            'corrupt-first-jpg' {
                $first = Get-ChildItem -LiteralPath $Roots[0] -Filter '*.jpg' -File -Recurse | Select-Object -First 1
                if ($null -ne $first) { [System.IO.File]::WriteAllText($first.FullName, 'corrupt') }
            }
            'add-heic' { [System.IO.File]::WriteAllText((Join-Path $Roots[0] 'added-during-review.HEIC'), 'new') }
            'mutate-first-heic' {
                $first = Get-ChildItem -LiteralPath $Roots[0] -Filter '*.heic' -File -Recurse | Select-Object -First 1
                if ($null -ne $first) { [System.IO.File]::AppendAllText($first.FullName, 'changed') }
            }
        }
        return
    }
    foreach ($root in $Roots) { Invoke-Item -LiteralPath $root -ErrorAction Stop }
}

function Read-DeletionConfirmation {
    if ($testMode) { return [string] $env:HEIC2JPG_TEST_CONFIRMATION }
    return (Read-Host '确认输入')
}

# 从 CMD 包装层读取全部参数，避免多目录和带空格路径丢失。
$rawArguments = New-Object System.Collections.ArrayList
$argumentCount = 0
[void] [int]::TryParse($env:HEIC_ARG_COUNT, [ref] $argumentCount)
for ($i = 1; $i -le $argumentCount; $i++) {
    [void] $rawArguments.Add([Environment]::GetEnvironmentVariable('HEIC_ARG_' + $i))
}

$requestedRoots = New-Object System.Collections.ArrayList
$parseOptions = $true
for ($i = 0; $i -lt $rawArguments.Count; $i++) {
    $argument = [string] $rawArguments[$i]
    if ($parseOptions -and ($argument -eq '--')) { $parseOptions = $false; continue }
    if ($parseOptions -and ($argument -eq '-f')) { $overwrite = $true; continue }
    if ($parseOptions -and ($argument -eq '-s')) { $strictMode = $true; continue }
    if ($parseOptions -and ($argument -eq '-h')) { $showHelp = $true; continue }
    if ($parseOptions -and ($argument -eq '-q')) {
        $i++
        if ($i -ge $rawArguments.Count) { Write-Host '错误：-q 后必须提供 1 到 100。' -ForegroundColor Red; exit 2 }
        $parsedQuality = 0
        if ((-not [int]::TryParse([string] $rawArguments[$i], [ref] $parsedQuality)) -or
            ($parsedQuality -lt 1) -or ($parsedQuality -gt 100)) {
            Write-Host '错误：JPG 质量必须是 1 到 100 的整数。' -ForegroundColor Red
            exit 2
        }
        $quality = $parsedQuality
        continue
    }
    if ($parseOptions -and $argument.StartsWith('-')) {
        Write-Host ('错误：未知选项 {0}' -f $argument) -ForegroundColor Red
        Show-Usage
        exit 2
    }
    [void] $requestedRoots.Add($argument)
}

if ($showHelp) { Show-Usage; exit 0 }

Write-Host ''
Write-Host 'Windows 离线版 HEIC → JPG 转换工具'
Write-Host '运行时不下载、不安装任何内容。'
Write-Host ''

if (-not (Test-Path -LiteralPath $magick -PathType Leaf)) {
    Write-Host '错误：找不到随离线包提供的 ImageMagick 运行库。' -ForegroundColor Red
    Write-Host '请先完整解压 ZIP，再从解压后的目录运行 CMD。'
    exit 1
}

$env:MAGICK_HOME = $toolDir
$env:Path = $toolDir + ';' + $env:Path
$formatProbe = Invoke-Native -FilePath $magick -Arguments @('-list', 'format')
if ($formatProbe.ExitCode -ne 0) {
    Write-Host '错误：ImageMagick 运行库无法启动。' -ForegroundColor Red
    Write-Host (Get-ReadableErrorText -Text $formatProbe.Text -Fallback '程序没有返回诊断信息。')
    exit 1
}
$heicMatch = [regex]::Match($formatProbe.Text, '(?mi)^\s*HEIC\*?\s+(\S+)')
if ((-not $heicMatch.Success) -or (-not $heicMatch.Groups[1].Value.StartsWith('r'))) {
    Write-Host '错误：当前 ImageMagick 运行库不支持读取 HEIC。' -ForegroundColor Red
    exit 1
}

try {
    if ($requestedRoots.Count -eq 0) { $requestedRoots = @(Select-PhotoFolders) }
    $roots = @(Normalize-Roots -Paths @($requestedRoots))
}
catch {
    Write-Host ('错误：{0}' -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}

if ($roots.Count -eq 0) {
    Write-Host '已取消，没有修改任何照片。'
    exit 0
}

Write-Host '已选择的根目录：'
foreach ($root in $roots) { Write-Host ('  {0}' -f $root) }
Write-Host ('JPG 质量：{0}' -f $quality)
Write-Host ('模式：{0}' -f $(if ($strictMode) { '严格模式' } else { '默认轻量模式' }))
if ($overwrite) { Write-Host '已有同名普通 JPG：重新转换并在成功后替换' }
else { Write-Host '已有同名普通 JPG：完整解码验证一次后复用' }
Write-Host '所有子文件夹都会处理；人工确认前不会删除 HEIC。'
Write-Host ''

$scan = Get-HeicScan -Roots $roots
foreach ($scanError in $scan.Errors) {
    Write-Host ('扫描警告：{0}' -f $scanError.Exception.Message) -ForegroundColor Yellow
}
if ($scan.Errors.Count -gt 0) {
    Write-Host '安全停止：目录扫描不完整，没有转换或删除任何文件。' -ForegroundColor Red
    exit 1
}

if ($scan.Hidden.Count -gt 0) {
    Write-Host ('以下 {0} 个以点开头的 HEIC 已跳过，不会转换或删除：' -f $scan.Hidden.Count) -ForegroundColor Yellow
    foreach ($hiddenFile in @($scan.Hidden | Select-Object -First 20)) { Write-Host ('  {0}' -f $hiddenFile.FullName) }
    if ($scan.Hidden.Count -gt 20) { Write-Host ('  ……另有 {0} 个' -f ($scan.Hidden.Count - 20)) }
    Write-Host ''
}

$files = @($scan.Files)
$found = $files.Count
if ($found -eq 0) {
    Write-Host '没有找到需要处理的 HEIC 文件。'
    exit 0
}

# 转换前先检查全部输入、输出映射；这里失败时尚未创建任何 JPG。
$plans = New-Object System.Collections.ArrayList
$outputPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$preflightErrors = 0
foreach ($file in $files) {
    try {
        if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'HEIC 是符号链接或重解析点。'
        }
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        if ([string]::IsNullOrEmpty($stem)) { throw '去掉扩展名后文件名为空。' }
        $output = Join-Path $file.DirectoryName ($stem + '.jpg')
        if (-not $outputPaths.Add([System.IO.Path]::GetFullPath($output))) {
            throw ('多个 HEIC 映射到同一个 JPG：{0}' -f $output)
        }

        $outputItem = Get-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue
        $outputExisted = ($null -ne $outputItem)
        if ($outputExisted -and ($outputItem.PSIsContainer -or
            (($outputItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0))) {
            throw ('同名 JPG 路径不是普通文件：{0}' -f $output)
        }
        [void] $plans.Add([pscustomobject] @{
            SourcePath = $file.FullName
            OutputPath = $output
            OutputExisted = $outputExisted
        })
    }
    catch {
        Write-Host ('转换前检查失败：{0}' -f $file.FullName) -ForegroundColor Red
        Write-Host ('  {0}' -f $_.Exception.Message) -ForegroundColor Red
        $preflightErrors++
    }
}
if ($preflightErrors -gt 0) {
    Write-Host ('安全停止：{0} 个转换前检查失败，没有转换或删除任何文件。' -f $preflightErrors) -ForegroundColor Red
    exit 1
}

$converted = 0
$reused = 0
$failed = 0
$records = New-Object System.Collections.ArrayList

foreach ($plan in $plans) {
    $source = $plan.SourcePath
    $output = $plan.OutputPath
    $tempDirectory = $null

    try {
        if ($plan.OutputExisted -and (-not $overwrite)) {
            Write-Host ('验证并复用：{0}' -f $output)
            if (-not (Test-RegularNonEmptyFile -Path $output)) {
                throw '已有同名 JPG 不是非空普通文件。'
            }

            if ($strictMode) {
                $receipt = Read-ResumeReceipt -Path $output
                if ($null -eq $receipt) {
                    throw '已有 JPG 没有本脚本写入的严格续传指纹；可改用默认模式，或使用 -f 重新转换。'
                }
                $sourceSnapshot = Get-StableFileSnapshot -Path $source
                $outputSnapshot = Get-StableFileSnapshot -Path $output
                if (-not [string]::Equals($sourceSnapshot.SHA256, $receipt.SourceSHA256, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw '严格续传指纹中的 HEIC 与当前原图不一致。'
                }
                if (-not [string]::Equals($outputSnapshot.SHA256, $receipt.OutputSHA256, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw '严格续传指纹中的 JPG 与当前文件不一致。'
                }
            }

            $validation = Test-ValidatedJpeg -Path $output
            if (-not $validation.Valid) { throw $validation.Reason }

            if ($strictMode) {
                $sourceAfter = Get-StableFileSnapshot -Path $source
                $outputAfter = Get-StableFileSnapshot -Path $output
                $receiptAfter = Read-ResumeReceipt -Path $output
                if ((-not (Test-SameStrictSnapshot -Expected $sourceSnapshot -Actual $sourceAfter)) -or
                    (-not (Test-SameStrictSnapshot -Expected $outputSnapshot -Actual $outputAfter)) -or
                    ($null -eq $receiptAfter) -or
                    (-not [string]::Equals($receiptAfter.SourceSHA256, $receipt.SourceSHA256, [System.StringComparison]::OrdinalIgnoreCase)) -or
                    (-not [string]::Equals($receiptAfter.OutputSHA256, $receipt.OutputSHA256, [System.StringComparison]::OrdinalIgnoreCase))) {
                    throw '严格续传验证期间 HEIC、JPG 或指纹发生变化。'
                }
                $sourceSnapshot = $sourceAfter
                $outputSnapshot = $outputAfter
            }
            else { $sourceSnapshot = $null; $outputSnapshot = $null }

            [void] $records.Add([pscustomobject] @{
                SourcePath = $source; OutputPath = $output
                SourceSnapshot = $sourceSnapshot; OutputSnapshot = $outputSnapshot
            })
            $reused++
            continue
        }

        Write-Host ('转换：{0}' -f $source)
        if ($strictMode) { $sourceSnapshot = Get-StableFileSnapshot -Path $source }
        else { $sourceSnapshot = Get-LightweightSnapshot -Path $source }

        $tempDirectory = New-ConversionTempDirectory -Parent ([System.IO.Path]::GetDirectoryName($source))
        $temporary = Join-Path $tempDirectory 'output.jpg'
        $conversion = Invoke-Native -FilePath $magick -Arguments @(
            ($source + '[0]'), '-auto-orient', '-quality', [string] $quality, $temporary
        )
        if ($conversion.ExitCode -ne 0) {
            throw ('ImageMagick 退出码 {0}：{1}' -f $conversion.ExitCode,
                (Get-ReadableErrorText -Text $conversion.Text -Fallback '转换失败，但程序没有返回诊断信息。'))
        }

        $validation = Test-ValidatedJpeg -Path $temporary
        if (-not $validation.Valid) { throw $validation.Reason }

        if ($strictMode) {
            $sourceAfter = Get-StableFileSnapshot -Path $source
            if (-not (Test-SameStrictSnapshot -Expected $sourceSnapshot -Actual $sourceAfter)) {
                throw '转换期间 HEIC 原图发生变化。'
            }
        }
        else {
            $sourceAfter = Get-LightweightSnapshot -Path $source
            if (-not (Test-SameLightweightSnapshot -Expected $sourceSnapshot -Actual $sourceAfter)) {
                throw '转换期间 HEIC 原图发生变化。'
            }
        }
        $sourceSnapshot = $sourceAfter

        $currentOutputItem = Get-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue
        if ($plan.OutputExisted) {
            if (($null -eq $currentOutputItem) -or $currentOutputItem.PSIsContainer -or
                (($currentOutputItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
                throw '准备替换时，同名 JPG 已消失或不再是普通文件。'
            }
        }
        elseif ($null -ne $currentOutputItem) {
            throw '转换期间出现了同名 JPG；为避免覆盖，已保留原图。'
        }

        Move-Item -LiteralPath $temporary -Destination $output -Force
        try {
            $outputItem = Get-Item -LiteralPath $output -Force
            $outputItem.CreationTimeUtc = $sourceSnapshot.CreationTimeUtc
            $outputItem.LastWriteTimeUtc = $sourceSnapshot.LastWriteTimeUtc
        }
        catch { Write-Host ('时间戳警告：{0}' -f $_.Exception.Message) -ForegroundColor Yellow }

        if ($strictMode) {
            $outputSnapshot = Get-StableFileSnapshot -Path $output
            if (-not (Write-ResumeReceipt -Path $output -SourceSHA256 $sourceSnapshot.SHA256 -OutputSHA256 $outputSnapshot.SHA256)) {
                Write-Host ('警告：无法在 JPG 的 NTFS 数据流中写入严格续传指纹；本次仍可确认删除：{0}' -f $output) -ForegroundColor Yellow
                $receiptWarnings++
            }
            # 写入或清除 NTFS 备用数据流可能更新时间戳；记录最终状态供本次严格复检使用。
            $outputSnapshot = Get-StableFileSnapshot -Path $output
        }
        else { $outputSnapshot = $null }

        [void] $records.Add([pscustomobject] @{
            SourcePath = $source; OutputPath = $output
            SourceSnapshot = $sourceSnapshot; OutputSnapshot = $outputSnapshot
        })
        $converted++
    }
    catch {
        Write-Host ('失败，已保留原图：{0}' -f $source) -ForegroundColor Red
        Write-Host ('  {0}' -f $_.Exception.Message) -ForegroundColor Red
        $failed++
    }
    finally { Remove-ConversionTempDirectory -Path $tempDirectory }
}

$ready = $converted + $reused
Write-Host ''
Write-Host ('处理完成：发现 {0}，新转换 {1}，复用 {2}，失败 {3}，点开头跳过 {4}。' -f
    $found, $converted, $reused, $failed, $scan.Hidden.Count)
Write-Host '目前尚未删除任何 HEIC 原图。' -ForegroundColor Green
if ($strictMode -and ($receiptWarnings -gt 0)) {
    Write-Host ('其中 {0} 个 JPG 无法保存持久严格续传指纹；中断后需使用 -f 重新转换。' -f $receiptWarnings) -ForegroundColor Yellow
}
if ($ready -eq 0) {
    Write-Host '没有 HEIC 可以进入删除确认；存在问题的文件均已保留。' -ForegroundColor Red
    exit 1
}
if ($failed -gt 0) {
    Write-Host ('注意：{0} 个失败项会保留；仍可检查并删除其余 {1} 个成功项。' -f $failed, $ready) -ForegroundColor Yellow
}

Write-Host ''
Write-Host '正在用资源管理器打开所选目录。请手动检查 JPG 的内容、方向、画质和对应关系。' -ForegroundColor Yellow
try { Open-ReviewFolders -Roots $roots }
catch {
    Write-Host ('安全停止：无法打开资源管理器：{0}' -f $_.Exception.Message) -ForegroundColor Red
    Write-Host '没有删除任何 HEIC。'
    exit 1
}

Write-Host ''
Write-Host ('确认无误后输入 y 或 Y，永久删除这 {0} 个成功项对应的 HEIC；其他输入取消。' -f $ready) -ForegroundColor Yellow
$confirmation = Read-DeletionConfirmation
if (($confirmation -cne 'y') -and ($confirmation -cne 'Y')) {
    Write-Host '已取消删除，所有 HEIC 原图均已保留。' -ForegroundColor Green
    exit 0
}

if ($strictMode) {
    Write-Host ''
    Write-Host '严格模式：正在执行完整删除前复检……'
    $preDeleteErrors = 0
    $finalScan = Get-HeicScan -Roots $roots
    foreach ($scanError in $finalScan.Errors) {
        Write-Host ('最终扫描错误：{0}' -f $scanError.Exception.Message) -ForegroundColor Red
        $preDeleteErrors++
    }

    $initialPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $currentPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $files) { [void] $initialPaths.Add([System.IO.Path]::GetFullPath($file.FullName)) }
    foreach ($file in $finalScan.Files) { [void] $currentPaths.Add([System.IO.Path]::GetFullPath($file.FullName)) }
    if (($initialPaths.Count -ne $currentPaths.Count) -or (-not $initialPaths.SetEquals($currentPaths))) {
        Write-Host '安全检查失败：人工检查期间 HEIC 文件集合发生了变化。' -ForegroundColor Red
        $preDeleteErrors++
    }

    foreach ($record in $records) {
        try {
            $sourceNow = Get-StableFileSnapshot -Path $record.SourcePath
            if (-not (Test-SameStrictSnapshot -Expected $record.SourceSnapshot -Actual $sourceNow)) {
                throw '人工检查期间 HEIC 内容发生了变化。'
            }
            $outputNow = Get-StableFileSnapshot -Path $record.OutputPath
            if (-not (Test-SameStrictSnapshot -Expected $record.OutputSnapshot -Actual $outputNow)) {
                throw '人工检查期间 JPG 内容发生了变化。'
            }
            $validation = Test-ValidatedJpeg -Path $record.OutputPath
            if (-not $validation.Valid) { throw ('JPG 已无法完整解码：{0}' -f $validation.Reason) }
        }
        catch {
            Write-Host ('安全检查失败：{0}' -f $record.SourcePath) -ForegroundColor Red
            Write-Host ('  {0}' -f $_.Exception.Message) -ForegroundColor Red
            $preDeleteErrors++
        }
    }
    if ($preDeleteErrors -gt 0) {
        Write-Host ('安全停止：{0} 项严格复检失败，没有删除任何 HEIC。' -f $preDeleteErrors) -ForegroundColor Red
        exit 1
    }
}
else {
    Write-Host ''
    Write-Host '默认轻量模式：删除前只逐项确认同名 JPG 仍是非空普通文件。'
}

$deleted = 0
$deleteErrors = 0
foreach ($record in $records) {
    try {
        if ($strictMode) {
            $sourceNow = Get-StableFileSnapshot -Path $record.SourcePath
            $outputNow = Get-StableFileSnapshot -Path $record.OutputPath
            if (-not (Test-SameStrictSnapshot -Expected $record.SourceSnapshot -Actual $sourceNow)) {
                throw '删除前一刻 HEIC 内容发生了变化。'
            }
            if (-not (Test-SameStrictSnapshot -Expected $record.OutputSnapshot -Actual $outputNow)) {
                throw '删除前一刻 JPG 内容发生了变化。'
            }
        }
        elseif (-not (Test-RegularNonEmptyFile -Path $record.OutputPath)) {
            throw '同名 JPG 已不存在、为空、不是普通文件或是重解析点。'
        }

        Remove-Item -LiteralPath $record.SourcePath -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $record.SourcePath) { throw '删除命令返回后原图仍然存在。' }
        $deleted++
    }
    catch {
        Write-Host ('无法删除原图：{0}' -f $record.SourcePath) -ForegroundColor Red
        Write-Host ('  {0}' -f $_.Exception.Message) -ForegroundColor Red
        $deleteErrors++
    }
}

Write-Host ''
Write-Host ('完成：{0} 个 JPG 已在处理阶段验证，删除 HEIC {1} 个，删除失败 {2} 个。' -f $ready, $deleted, $deleteErrors)
if ($failed -gt 0) { Write-Host ('另有 {0} 个转换/复用失败的 HEIC 保留未动。' -f $failed) -ForegroundColor Yellow }
if ($deleteErrors -gt 0) { exit 1 }
exit 0
