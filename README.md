# HEIC2JPG

在 macOS 或 Windows 上递归地把一个文件夹及其所有子文件夹中的 HEIC 照片转换为 JPG。

本仓库只发布本项目自行编写的脚本和文档，不包含 ImageMagick、`magick.exe`、测试照片或生成的离线 ZIP。

## 功能

- 递归处理子文件夹，支持包含空格、中文及常见特殊字符的路径。
- JPG 与原 HEIC 保存在同一目录，并使用相同的基本文件名。
- Windows 和 macOS 版都会先选择照片文件夹，并递归处理全部子文件夹。
- 完全转换并校验后，会打开照片目录供人工检查。
- 只有用户准确输入 `DELETE ALL HEIC` 且最终复检全部通过后，才会永久删除 HEIC。
- Windows 离线包可在联网电脑上用官方 ImageMagick 归档本地生成；生成过程本身不联网。
- macOS 版使用系统自带的 `sips`，无需安装转换软件。

> [!CAUTION]
> 删除的 HEIC 不经过废纸篓或回收站。请先备份重要照片，并先用少量副本测试。两个平台都会在转换后要求人工检查和精确确认，但多文件删除无法成为一个不可分割的事务；删除过程中断电或权限变化仍可能造成部分文件已删除。

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

macOS 版只有一个文件：[`src/macos/一键转换HEIC.command`](src/macos/%E4%B8%80%E9%94%AE%E8%BD%AC%E6%8D%A2HEIC.command)。下载后首次使用时执行：

```bash
chmod +x "一键转换HEIC.command"
```

以后直接在 Finder 中双击该文件，它会弹出 macOS 文件夹选择器。也可以在终端中直接指定照片根目录：

```bash
./一键转换HEIC.command "/照片根目录"
```

支持 `-q 1..100` 设置 JPG 质量。默认情况下，只要发现已有同名 JPG，整批任务会在转换前安全停止；只有明确使用 `-f` 时才会用验证成功的新 JPG 替换已有的普通 JPG 文件。

运行 `一键转换HEIC.command` 后：

1. 在弹出的窗口中选择照片根目录。
2. 脚本转换并验证全部 HEIC，但不删除原图。
3. Finder 自动打开所选目录，供你人工检查 JPG。
4. 返回终端，只有确认无误后才输入 `DELETE ALL HEIC`。
5. 脚本重新检查 HEIC 文件集合、源文件稳定快照、JPG 哈希和可解码性；全部通过后才删除原图。

一键版默认不覆盖已有 JPG；只要存在同名目标，就会在转换前停止并保留全部文件。需要覆盖时请在终端中明确使用 `-f`。符号链接、目录、重复输出映射以及没有有效主文件名的 `.HEIC` 也会在转换前触发安全停止。转换失败时会显示具体 HEIC 路径、`sips` 退出码和 macOS 返回的原始诊断信息。

## 公开仓库检查

提交前运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-public-tree.ps1
```

它会拒绝 Git 已跟踪文件中的 EXE、压缩包、照片、视频、缓存目录和 AppleDouble 元数据。

macOS 安全流程的模拟测试可执行：

```bash
bash tests/macos/run-tests.sh
```

## 第三方依赖与许可证

本项目代码和文档采用 [MIT License](LICENSE)。该许可只覆盖本仓库自行创作的文件，不覆盖 ImageMagick 或其编解码库。

ImageMagick 版权所有 © ImageMagick Studio LLC，并受独立的 [ImageMagick License](https://imagemagick.org/license/) 约束。ImageMagick 内置组件适用其 `NOTICE.txt` 中列出的各自许可证。本项目与 ImageMagick Studio LLC 不存在隶属、赞助或背书关系。

详细信息见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。自行发布含 ImageMagick 的成品包之前，应独立确认第三方开源许可证和适用的 HEVC/H.265 专利要求。

## 数据安全说明

- 任一 HEIC 转换或验证失败，整批任务都不会启动删除。
- 人工检查期间修改或移动本次生成的 JPG，或者新增、移动、修改 HEIC，会触发安全停止。
- 删除前会重新核验 HEIC 文件集合、源文件快照、文件哈希和 JPG 可解码性。
- Windows 版以及明确使用 macOS `-f` 参数时可能替换已有同名 JPG；请先备份。
- iCloud/OneDrive 的仅联机文件必须先完整下载到本机。
