# HEIC2JPG

在 macOS 或 Windows 上递归地把一个文件夹及其所有子文件夹中的 HEIC 照片转换为 JPG。

本仓库只发布本项目自行编写的脚本和文档，不包含 ImageMagick、`magick.exe`、测试照片或生成的离线 ZIP。

## 功能

- 递归处理子文件夹，支持包含空格、中文及常见特殊字符的路径。
- JPG 与原 HEIC 保存在同一目录，并使用相同的基本文件名。
- Windows 版完全转换并校验后，会打开照片目录供人工检查。
- Windows 版只有在用户准确输入 `DELETE ALL HEIC` 且最终复检全部通过后，才会永久删除 HEIC。
- Windows 离线包可在联网电脑上用官方 ImageMagick 归档本地生成；生成过程本身不联网。
- macOS 版使用系统自带的 `sips`，无需安装转换软件。

> [!CAUTION]
> 删除的 HEIC 不经过回收站。请先备份重要照片，并先用少量副本测试。Windows 版有人工检查步骤；当前 macOS 脚本则会在每张照片成功转换后立即删除对应 HEIC。

## Windows 10/11 x64

Windows 脚本位于 [`src/windows/HEIC_to_JPG_Offline.cmd`](src/windows/HEIC_to_JPG_Offline.cmd)。它需要一个放在脚本旁边、目录名为 `ImageMagick` 的本地运行库：

```text
HEIC_to_JPG_Offline_Windows_x64/
├── HEIC_to_JPG_Offline.cmd
├── README-Windows.txt
├── RUNTIME_SOURCE_AND_LICENSE.txt
└── ImageMagick/
    ├── magick.exe
    ├── LICENSE.txt
    ├── NOTICE.txt
    └── ...
```

推荐在联网且可信的 Windows 电脑上完成一次本地组装：

1. 从 [ImageMagick 官方 Release](https://github.com/ImageMagick/ImageMagick/releases/download/7.1.2-29/ImageMagick-7.1.2-29-portable-Q16-HDRI-x64.7z) 下载 `ImageMagick-7.1.2-29-portable-Q16-HDRI-x64.7z`。
2. 把文件放到仓库根目录的 `.vendor-cache/`。这个目录已被 Git 忽略。
3. 在 PowerShell 中执行：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-windows-offline.ps1
   ```

4. 脚本会先核验官方归档 SHA-256，再在 `dist/` 下生成本地离线目录、ZIP 和校验文件。
5. 把生成的 ZIP 复制到离线电脑，完整解压后双击 `HEIC_to_JPG_Offline.cmd`。

构建脚本不会下载任何文件。默认使用的官方归档 SHA-256 是：

```text
b68e312b21556ae8872704e37df3c69cbdc0ea7100366bf823e7e3a1b69405bc
```

运行时也可以把照片文件夹直接拖到 CMD 上。转换完成后请手动打开 JPG 检查方向、画质和数量；只有确认无误后才输入删除确认词。

## macOS

命令行脚本：

```bash
chmod +x src/macos/heic_to_jpg.sh
./src/macos/heic_to_jpg.sh "/照片根目录"
```

支持 `-q 1..100` 设置 JPG 质量，使用 `-f` 覆盖已有的同名 JPG。

Finder 一键版位于 [`src/macos/一键转换HEIC.command`](src/macos/%E4%B8%80%E9%94%AE%E8%BD%AC%E6%8D%A2HEIC.command)。把它复制到需要处理的照片根目录，执行一次：

```bash
chmod +x "一键转换HEIC.command"
```

以后可在 Finder 中双击运行，它会处理脚本所在目录及全部子目录。该版本会在单张照片成功转换后立即删除对应 HEIC，请务必先备份。

## 公开仓库检查

提交前运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-public-tree.ps1
```

它会拒绝 Git 已跟踪文件中的 EXE、压缩包、照片、视频、缓存目录和 AppleDouble 元数据。

## 第三方依赖与许可证

本项目代码和文档采用 [MIT License](LICENSE)。该许可只覆盖本仓库自行创作的文件，不覆盖 ImageMagick 或其编解码库。

ImageMagick 版权所有 © ImageMagick Studio LLC，并受独立的 [ImageMagick License](https://imagemagick.org/license/) 约束。ImageMagick 内置组件适用其 `NOTICE.txt` 中列出的各自许可证。本项目与 ImageMagick Studio LLC 不存在隶属、赞助或背书关系。

详细信息见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。自行发布含 ImageMagick 的成品包之前，应独立确认第三方开源许可证和适用的 HEVC/H.265 专利要求。

## 数据安全说明

- 如果任何 HEIC 转换失败，Windows 版不会启动批量删除。
- 人工检查期间修改、移动或新增 JPG/HEIC，会触发 Windows 版安全停止。
- Windows 版删除前会重新核验 HEIC 文件集合、文件哈希和 JPG 可解码性。
- 已有同名 JPG 可能被成功转换的新文件覆盖；请先备份。
- iCloud/OneDrive 的仅联机文件必须先完整下载到本机。
