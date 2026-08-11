#!/bin/bash

# Copyright (c) 2026 Owen Pu. Licensed under the MIT License.
# Finder entry point for the shared macOS converter.

script_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)
converter="$script_dir/heic_to_jpg.sh"

printf '\nHEIC -> JPG 一键转换（安全确认版）\n\n'

if [ ! -f "$converter" ]; then
  printf '错误：找不到同目录下的 heic_to_jpg.sh。\n' >&2
  printf '请保持这两个文件位于同一个文件夹中。\n' >&2
  status=1
else
  /bin/bash "$converter"
  status=$?
fi

if [ "$status" -eq 0 ]; then
  printf '\n处理结束。\n'
else
  printf '\n处理未完成，请查看上面的安全提示或错误信息。\n'
fi

if [ -t 0 ]; then
  printf '按回车键关闭窗口……'
  IFS= read -r _
fi

exit "$status"
