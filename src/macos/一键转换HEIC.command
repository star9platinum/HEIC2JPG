#!/bin/bash

# Copyright (c) 2026 Owen Pu. Licensed under the MIT License.
# Double-click this file in Finder. It converts every HEIC file in this file's
# folder and all subfolders, then deletes each HEIC after a successful conversion.
# This file is standalone and uses macOS's built-in `sips`.

script_dir=$(cd "$(dirname "$0")" && pwd)
quality=90

printf '\nHEIC -> JPG 一键转换\n'
printf '处理目录：%s\n' "$script_dir"
printf '成功转换后将删除原 HEIC 文件。\n\n'

if ! command -v sips >/dev/null 2>&1; then
  printf '错误：找不到 macOS 自带的 sips 命令。\n' >&2
  status=1
else
  converted=0
  deleted=0
  failed=0
  found=0

  while IFS= read -r -d '' input; do
    found=$((found + 1))
    output=${input%.*}.jpg
    temporary="${output%.*}.heic-to-jpg-tmp-$$.jpg"
    rm -f "$temporary"

    printf '转换：%s -> %s\n' "$input" "$output"

    # Write to a temporary JPG first. An existing JPG is replaced only after
    # conversion succeeds, and the HEIC is deleted only after that replacement.
    if sips -s format jpeg -s formatOptions "$quality" "$input" \
        --out "$temporary" >/dev/null \
        && mv -f "$temporary" "$output"; then
      converted=$((converted + 1))
      if rm -f "$input"; then
        deleted=$((deleted + 1))
      else
        printf '已转换，但无法删除原文件：%s\n' "$input" >&2
        failed=$((failed + 1))
      fi
    else
      printf '转换失败，原文件已保留：%s\n' "$input" >&2
      rm -f "$temporary"
      failed=$((failed + 1))
    fi
  done < <(find "$script_dir" -type f -name '*.[Hh][Ee][Ii][Cc]' -print0)

  if [ "$found" -eq 0 ]; then
    printf '没有找到 HEIC 文件。\n'
  else
    printf '\n完成：%d 个已转换，%d 个原文件已删除，%d 个错误。\n' \
      "$converted" "$deleted" "$failed"
  fi

  if [ "$failed" -gt 0 ]; then
    status=1
  else
    status=0
  fi
fi

if [ "$status" -eq 0 ]; then
  printf '\n处理完成。'
else
  printf '\n处理过程中出现错误，请查看上面的信息。'
fi

if [ -t 0 ]; then
  printf '按任意键关闭窗口……'
  IFS= read -r -n 1 _
  printf '\n'
else
  printf '\n'
fi

exit "$status"
