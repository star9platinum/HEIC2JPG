Windows 离线版：HEIC 批量转 JPG

适用系统：Windows 10 / 11，64 位 x64（常见的 Intel、AMD 电脑）

本说明用于由仓库构建脚本在本地组装的离线包。组装后的目录自带转换程序：
- 不需要联网
- 不需要安装 ImageMagick
- 不调用 WinGet
- 不需要管理员权限

使用方法：
1. 必须先把整个 ZIP 解压出来，不要在压缩包预览窗口里直接运行。
2. 双击 HEIC_to_JPG_Offline.cmd。
3. 在弹出的窗口中选择照片所在文件夹。
4. 程序会递归处理该文件夹和所有子文件夹。
5. 转换结束后，照片文件夹会自动打开；此时所有 HEIC 原图仍然保留。
6. 手动打开、抽查 JPG，确认方向、画质和数量都正确。
7. 返回命令窗口。只有确定无误后，输入完整确认词：DELETE ALL HEIC
8. 程序会再次校验全部 JPG，然后永久删除本次扫描到的 HEIC。

也可以直接把“照片文件夹”拖到 HEIC_to_JPG_Offline.cmd 上运行。

重要提醒：
- JPG 质量为 92。
- 转换阶段和人工检查阶段不会删除任何 HEIC。
- 只有全部 HEIC 都转换成功、你输入 DELETE ALL HEIC，并且最终复检全部通过后，程序才会删除原图。
- 输入其他内容、直接关闭窗口、任何转换失败或最终复检失败，都会取消批量删除。
- 检查时请只查看 JPG，不要改名、移动或编辑 JPG/HEIC；文件内容或 HEIC 文件列表发生变化会触发安全停止。
- 确认删除后，HEIC 会被永久删除，不经过回收站。
- 如果已有同名 JPG，只有新 JPG 转换并校验成功后才会覆盖它。
- 建议第一次先用少量照片或备份副本测试。
- 工具不能直接处理资源管理器里的“Apple iPhone”虚拟目录；请先把照片复制到 Windows 本地磁盘。
- iCloud 或 OneDrive 的仅联机占位文件要先设置为“始终保留在此设备上”，否则断网时无法读取。
- 遇到路径过长错误时，把工具和照片移到较浅的目录（例如 D:\照片）再试。

运行库：ImageMagick 7.1.2-29 portable Q16-HDRI x64
官方来源：https://imagemagick.org/download/
运行库许可和第三方声明：ImageMagick\LICENSE.txt、ImageMagick\NOTICE.txt
