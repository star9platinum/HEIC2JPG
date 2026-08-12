[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$sourceConverter = Join-Path $repositoryRoot 'src\windows\HEIC_to_JPG_Offline.cmd'
$sourceCleaner = Join-Path $repositoryRoot 'src\windows\清理HEIC2JPG临时文件.cmd'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('HEIC2JPG-WindowsTests-' + [Guid]::NewGuid().ToString('N'))
$toolRoot = Join-Path $testRoot 'tool'
$converter = Join-Path $toolRoot 'HEIC_to_JPG_Offline.cmd'
$cleaner = Join-Path $toolRoot '清理HEIC2JPG临时文件.cmd'
$jpegBytes = [byte[]] @(0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9)
$script:passed = 0

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function New-TestDirectory {
    param([string] $Name)
    $path = Join-Path $testRoot $Name
    [void] [System.IO.Directory]::CreateDirectory($path)
    return $path
}

function New-Heic {
    param([string] $Path, [string] $Content = 'mock-heic')
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.Encoding]::UTF8)
}

function New-Jpeg {
    param([string] $Path)
    [System.IO.File]::WriteAllBytes($Path, $jpegBytes)
}

function Invoke-CmdTool {
    param(
        [Parameter(Mandatory = $true)][string] $Tool,
        [string[]] $Arguments = @(),
        [string] $Confirmation = 'n',
        [string] $OpenAction = ''
    )
    $oldMode = $env:HEIC2JPG_TEST_MODE
    $oldConfirmation = $env:HEIC2JPG_TEST_CONFIRMATION
    $oldOpenAction = $env:HEIC2JPG_TEST_OPEN_ACTION
    try {
        $env:HEIC2JPG_TEST_MODE = '1'
        $env:HEIC2JPG_TEST_CONFIRMATION = $Confirmation
        $env:HEIC2JPG_TEST_OPEN_ACTION = $OpenAction
        $lines = @(& $Tool @Arguments 2>&1 | ForEach-Object { [string] $_ })
        $code = $LASTEXITCODE
        return [pscustomobject] @{ ExitCode = $code; Text = ($lines -join [Environment]::NewLine) }
    }
    finally {
        $env:HEIC2JPG_TEST_MODE = $oldMode
        $env:HEIC2JPG_TEST_CONFIRMATION = $oldConfirmation
        $env:HEIC2JPG_TEST_OPEN_ACTION = $oldOpenAction
    }
}

function Assert-NoConversionTemps {
    param([string] $Root)
    $leftovers = @(Get-ChildItem -LiteralPath $Root -Force -Recurse |
        Where-Object { $_.Name -match '^\.HEIC2JPG\.convert\.[0-9a-f]{32}$' })
    $leftoverPaths = @($leftovers | ForEach-Object { $_.FullName })
    Assert-True ($leftovers.Count -eq 0) ('发现未清理的转换临时目录：{0}' -f ($leftoverPaths -join ', '))
}

function Complete-Test {
    param([string] $Name)
    $script:passed++
    Write-Host ('PASS: {0}' -f $Name) -ForegroundColor Green
}

try {
    [void] [System.IO.Directory]::CreateDirectory($testRoot)
    [void] [System.IO.Directory]::CreateDirectory($toolRoot)
    $mockRuntime = Join-Path $toolRoot 'ImageMagick'
    [void] [System.IO.Directory]::CreateDirectory($mockRuntime)
    [System.IO.File]::Copy($sourceConverter, $converter)
    [System.IO.File]::Copy($sourceCleaner, $cleaner)
    [System.IO.File]::WriteAllText((Join-Path $toolRoot '.HEIC2JPG-TEST-ONLY'), 'test only')

    # 测试包使用运行时编译的临时 EXE，正式脚本中不存在可切换的伪转换实现。
    $mockSource = @'
using System;
using System.IO;

namespace HEIC2JPGWindowsTests
{
    public static class MockMagick
    {
        private static bool IsJpeg(string path)
        {
            try
            {
                byte[] data = File.ReadAllBytes(path);
                return data.Length >= 4 && data[0] == 0xFF && data[1] == 0xD8 &&
                    data[data.Length - 2] == 0xFF && data[data.Length - 1] == 0xD9;
            }
            catch { return false; }
        }

        public static int Main(string[] args)
        {
            if (args.Length == 2 && args[0] == "-list" && args[1] == "format")
            {
                Console.WriteLine(" HEIC  r--   High Efficiency Image Format");
                return 0;
            }

            if (args.Length >= 2 && args[0] == "identify")
            {
                if (IsJpeg(args[args.Length - 1]))
                {
                    Console.Write("JPEG|100|80");
                    return 0;
                }
                Console.Error.WriteLine("mock identify: invalid JPEG");
                return 1;
            }

            if (args.Length == 3 && args[2] == "null:")
            {
                if (IsJpeg(args[0]) &&
                    Path.GetFileName(args[0]).IndexOf("decode_fail", StringComparison.OrdinalIgnoreCase) < 0)
                    return 0;
                Console.Error.WriteLine("mock decode: image could not be fully decoded");
                return 1;
            }

            if (args.Length >= 2)
            {
                string input = args[0];
                if (input.EndsWith("[0]", StringComparison.Ordinal))
                    input = input.Substring(0, input.Length - 3);
                string output = args[args.Length - 1];
                string name = Path.GetFileName(input);
                if (name.IndexOf("convert_fail", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    Console.Error.WriteLine("mock conversion: damaged HEIC");
                    return 1;
                }
                if (name.IndexOf("bad_output", StringComparison.OrdinalIgnoreCase) >= 0)
                    File.WriteAllBytes(output, new byte[] { 1, 2, 3, 4 });
                else
                    File.WriteAllBytes(output, new byte[] { 0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9 });
                if (name.IndexOf("mutate_source", StringComparison.OrdinalIgnoreCase) >= 0)
                    File.AppendAllText(input, "changed");
                return 0;
            }

            Console.Error.WriteLine("mock ImageMagick: unsupported arguments");
            return 1;
        }
    }
}
'@
    Add-Type -TypeDefinition $mockSource -Language CSharp -OutputAssembly (Join-Path $mockRuntime 'magick.exe') -OutputType ConsoleApplication

    # 多目录、重叠根目录、损坏文件和点开头文件。
    $root = New-TestDirectory '01 多目录'
    $child = New-TestDirectory '01 多目录\子 目录'
    New-Heic (Join-Path $root 'good.HEIC')
    New-Heic (Join-Path $child 'convert_fail.HEIC')
    New-Heic (Join-Path $child '._AppleDouble.HEIC')
    $result = Invoke-CmdTool -Tool $converter -Arguments @($root, $child) -Confirmation 'Y'
    Assert-True ($result.ExitCode -eq 0) $result.Text
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'good.HEIC'))) '成功项 HEIC 没有删除。'
    Assert-True (Test-Path -LiteralPath (Join-Path $root 'good.jpg')) '成功项 JPG 不存在。'
    Assert-True (Test-Path -LiteralPath (Join-Path $child 'convert_fail.HEIC')) '损坏 HEIC 不应删除。'
    Assert-True (Test-Path -LiteralPath (Join-Path $child '._AppleDouble.HEIC')) '点开头 HEIC 不应处理。'
    Assert-NoConversionTemps $root
    Complete-Test '多目录去重、失败隔离、点开头跳过与临时清理'

    # 只有精确的 y/Y 才删除。
    $root = New-TestDirectory '02 确认词'
    New-Heic (Join-Path $root 'confirm.HEIC')
    $result = Invoke-CmdTool -Tool $converter -Arguments @($root) -Confirmation 'yes'
    Assert-True ($result.ExitCode -eq 0) $result.Text
    Assert-True (Test-Path -LiteralPath (Join-Path $root 'confirm.HEIC')) 'yes 不应触发删除。'
    Complete-Test '删除确认只接受 y 或 Y'

    # 默认模式复用已有、可完整解码的同名 JPG。
    $root = New-TestDirectory '03 默认续传'
    New-Heic (Join-Path $root 'resume.HEIC')
    New-Jpeg (Join-Path $root 'resume.jpg')
    $result = Invoke-CmdTool -Tool $converter -Arguments @($root) -Confirmation 'y'
    Assert-True ($result.ExitCode -eq 0) $result.Text
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'resume.HEIC'))) '默认续传成功后应可删除 HEIC。'
    Assert-True ($result.Text.Contains('验证并复用')) '没有走默认续传分支。'
    Complete-Test '默认模式复用已有可解码 JPG'

    # 无效已有 JPG 仅导致当前项失败，不覆盖也不删除原图。
    $root = New-TestDirectory '04 无效已有 JPG'
    $source = Join-Path $root 'invalid.HEIC'
    $output = Join-Path $root 'invalid.jpg'
    New-Heic $source
    [System.IO.File]::WriteAllText($output, 'invalid')
    $result = Invoke-CmdTool -Tool $converter -Arguments @($root) -Confirmation 'y'
    Assert-True ($result.ExitCode -eq 1) '全部失败时应返回非零。'
    Assert-True (Test-Path -LiteralPath $source) '无效已有 JPG 对应的 HEIC 不应删除。'
    Assert-True ([System.IO.File]::ReadAllText($output) -eq 'invalid') '无效已有 JPG 不应被默认模式覆盖。'
    Complete-Test '无效已有 JPG 隔离失败'

    # 格式/尺寸正常但完整解码失败时，null: 验证必须阻止复用。
    $root = New-TestDirectory '04B null 解码'
    $source = Join-Path $root 'decode_fail.HEIC'
    $output = Join-Path $root 'decode_fail.jpg'
    New-Heic $source
    New-Jpeg $output
    $result = Invoke-CmdTool -Tool $converter -Arguments @($root) -Confirmation 'y'
    Assert-True ($result.ExitCode -eq 1) 'null: 完整解码失败时应返回非零。'
    Assert-True (Test-Path -LiteralPath $source) 'null: 完整解码失败时 HEIC 必须保留。'
    Assert-True ($result.Text.Contains('mock decode')) '测试没有经过 ImageMagick null: 完整解码分支。'
    Complete-Test 'Windows 保留 ImageMagick null: 完整解码验证'

    # -f 转换失败时保留旧 JPG。
    $root = New-TestDirectory '05 覆盖保护'
    $source = Join-Path $root 'convert_fail.HEIC'
    $output = Join-Path $root 'convert_fail.jpg'
    New-Heic $source
    New-Jpeg $output
    $oldHash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
    $result = Invoke-CmdTool -Tool $converter -Arguments @('-f', $root) -Confirmation 'y'
    Assert-True ($result.ExitCode -eq 1) '仅失败项应返回非零。'
    Assert-True (Test-Path -LiteralPath $source) '-f 转换失败不应删除 HEIC。'
    Assert-True ((Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash -eq $oldHash) '-f 失败时旧 JPG 被改动。'
    Assert-NoConversionTemps $root
    Complete-Test '-f 仅在成功后替换已有 JPG'

    # 默认删除前检查只看同名 JPG 是否仍为非空普通文件。
    $root = New-TestDirectory '06 轻量删除检查'
    New-Heic (Join-Path $root 'light.HEIC')
    $result = Invoke-CmdTool -Tool $converter -Arguments @($root) -Confirmation 'y' -OpenAction 'corrupt-first-jpg'
    Assert-True ($result.ExitCode -eq 0) $result.Text
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'light.HEIC'))) '轻量模式不应再次解码非空 JPG。'
    Complete-Test '默认删除前不重复解码'

    # 如果 JPG 被删除，默认模式仍必须保留 HEIC。
    $root = New-TestDirectory '07 JPG 丢失'
    New-Heic (Join-Path $root 'missing.HEIC')
    $result = Invoke-CmdTool -Tool $converter -Arguments @($root) -Confirmation 'y' -OpenAction 'delete-first-jpg'
    Assert-True ($result.ExitCode -eq 1) 'JPG 丢失时删除应失败。'
    Assert-True (Test-Path -LiteralPath (Join-Path $root 'missing.HEIC')) 'JPG 丢失时 HEIC 必须保留。'
    Complete-Test '默认删除前要求同名非空普通 JPG'

    # 严格模式会发现人工检查期间 JPG 内容变化。
    $root = New-TestDirectory '08 严格复检'
    New-Heic (Join-Path $root 'strict-change.HEIC')
    $result = Invoke-CmdTool -Tool $converter -Arguments @('-s', $root) -Confirmation 'y' -OpenAction 'corrupt-first-jpg'
    Assert-True ($result.ExitCode -eq 1) '严格模式应阻止删除。'
    Assert-True (Test-Path -LiteralPath (Join-Path $root 'strict-change.HEIC')) '严格复检失败时 HEIC 必须保留。'
    Complete-Test '严格模式复核 SHA-256 和完整解码'

    # 严格模式生成指纹后可断点复用。
    $root = New-TestDirectory '09 严格续传'
    New-Heic (Join-Path $root 'strict-resume.HEIC')
    $first = Invoke-CmdTool -Tool $converter -Arguments @('-s', $root) -Confirmation 'n'
    Assert-True ($first.ExitCode -eq 0) $first.Text
    $second = Invoke-CmdTool -Tool $converter -Arguments @('-s', $root) -Confirmation 'y'
    Assert-True ($second.ExitCode -eq 0) $second.Text
    Assert-True ($second.Text.Contains('验证并复用')) '严格模式没有复用持久指纹。'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'strict-resume.HEIC'))) '严格续传确认后未删除 HEIC。'
    Complete-Test '严格模式持久指纹续传'

    # 转换期间原图变化必须丢弃结果并清理临时目录。
    $root = New-TestDirectory '10 原图变化'
    New-Heic (Join-Path $root 'mutate_source.HEIC')
    $result = Invoke-CmdTool -Tool $converter -Arguments @($root) -Confirmation 'y'
    Assert-True ($result.ExitCode -eq 1) '原图变化时应返回非零。'
    Assert-True (Test-Path -LiteralPath (Join-Path $root 'mutate_source.HEIC')) '变化的 HEIC 必须保留。'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'mutate_source.jpg'))) '原图变化时不应安装 JPG。'
    Assert-NoConversionTemps $root
    Complete-Test '转换期间原图变化保护'

    # 清理器只删除精确命名的新旧临时项。
    $root = New-TestDirectory '11 清理器'
    $newTemp = Join-Path $root '.HEIC2JPG.convert.0123456789abcdef0123456789abcdef'
    [void] [System.IO.Directory]::CreateDirectory($newTemp)
    [System.IO.File]::WriteAllText((Join-Path $newTemp 'output.jpg'), 'temporary')
    $legacyTemp = Join-Path $root '.heicjpg-fedcba9876543210fedcba9876543210.jpg'
    [System.IO.File]::WriteAllText($legacyTemp, 'temporary')
    $lookalike = Join-Path $root '.HEIC2JPG.convert.not-a-guid'
    [void] [System.IO.Directory]::CreateDirectory($lookalike)
    $photo = Join-Path $root 'keep.HEIC'
    New-Heic $photo
    $result = Invoke-CmdTool -Tool $cleaner -Arguments @($root) -Confirmation 'Y'
    Assert-True ($result.ExitCode -eq 0) $result.Text
    Assert-True (-not (Test-Path -LiteralPath $newTemp)) '新临时目录没有清理。'
    Assert-True (-not (Test-Path -LiteralPath $legacyTemp)) '旧临时 JPG 没有清理。'
    Assert-True (Test-Path -LiteralPath $lookalike) '近似名称不应删除。'
    Assert-True (Test-Path -LiteralPath $photo) '清理器不应删除 HEIC。'
    Complete-Test 'Windows 临时项彻底清理'

    Write-Host ''
    Write-Host ('Windows tests passed: {0}' -f $script:passed) -ForegroundColor Green
}
finally {
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    $safePrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\HEIC2JPG-WindowsTests-'
    if ((Test-Path -LiteralPath $resolvedTestRoot) -and
        $resolvedTestRoot.StartsWith($safePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
