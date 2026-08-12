#!/bin/bash

# Copyright (c) 2026 Owen Pu. Licensed under the MIT License.
# 清理由本项目遗留的 macOS 临时目录；不会删除 JPG 或 HEIC 照片。

set -u

temp_parent=${TMPDIR:-/tmp}
temp_parent=${temp_parent%/}
if [ -z "$temp_parent" ]; then
  temp_parent=/
fi

workspace=''
candidate_count=0
candidate_kb=0
delete_errors=0

usage() {
  cat <<'EOF'
用法：清理HEIC2JPG临时文件.command [照片文件夹 ...]

不指定文件夹时会弹出可多选的文件夹选择器。工具会递归查找照片目录中的
.HEIC2JPG 临时目录，并检查当前用户的 macOS 系统临时目录。

工具只删除本项目精确命名的临时目录，不删除 JPG 或 HEIC 照片。所有候选
会先列出；只有输入 y 或 Y 后才删除。运行清理工具前，请先确认没有任何
HEIC2JPG 转换任务正在运行；确认后会彻底删除找到的新旧版本临时目录。
EOF
}

cleanup() {
  if [ -n "$workspace" ] && [ -d "$workspace" ]; then
    case "$workspace" in
      "$temp_parent"/HEIC2JPG-cleaner.*)
        rm -rf "$workspace" 2>/dev/null || true
        ;;
    esac
  fi
}

finish() {
  local status=$?

  trap - EXIT
  cleanup
  if [ "${HEIC2JPG_TEST_MODE:-0}" != '1' ] && [ -r /dev/tty ]; then
    printf '\n按回车键关闭窗口……'
    IFS= read -r _ 2>/dev/null < /dev/tty || true
  fi
  exit "$status"
}

trap finish EXIT
trap 'exit 130' HUP INT TERM

select_photo_folders() {
  osascript <<'APPLESCRIPT'
try
  set selectedFolders to choose folder with prompt "选择一个或多个需要清理的照片根目录（取消则只检查系统临时目录）" with multiple selections allowed
  set outputLines to ""
  repeat with selectedFolder in selectedFolders
    set outputLines to outputLines & (POSIX path of selectedFolder) & linefeed
  end repeat
  return outputLines
on error number -128
  return ""
end try
APPLESCRIPT
}

read_confirmation() {
  if [ "${HEIC2JPG_TEST_MODE:-0}" = '1' ]; then
    IFS= read -r confirmation
    return $?
  fi

  if [ ! -r /dev/tty ]; then
    return 1
  fi
  IFS= read -r confirmation < /dev/tty
}

path_key() {
  printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print $1}'
}

is_photo_temp_name() {
  case "$1" in
    .HEIC2JPG.convert.??????|.HEIC2JPG.validate.??????|.HEIC2JPG.??????)
      return 0
      ;;
  esac
  return 1
}

is_system_temp_name() {
  case "$1" in
    HEIC2JPG.state.??????|HEIC2JPG.??????)
      return 0
      ;;
  esac
  return 1
}

consider_candidate() {
  local directory=$1
  local key
  local size_kb

  [ -d "$directory" ] && [ ! -L "$directory" ] || return 0

  key=$(path_key "$directory")
  if [ -z "$key" ] || [ -e "$seen_dir/$key" ]; then
    return 0
  fi
  if ! : > "$seen_dir/$key" || ! printf '%s\0' "$directory" >> "$candidates_file"; then
    printf '错误：无法记录清理候选：%s\n' "$directory" >&2
    return 1
  fi

  size_kb=$(du -sk "$directory" 2>/dev/null | awk '{print $1; exit}')
  case "$size_kb" in
    ''|*[!0-9]*) size_kb=0 ;;
  esac
  candidate_count=$((candidate_count + 1))
  candidate_kb=$((candidate_kb + size_kb))
  printf '候选 %d（约 %d KB）：%s\n' "$candidate_count" "$size_kb" "$directory"
  return 0
}

scan_photo_root() {
  local root=$1
  local directory
  local scan_buffer="$workspace/photo-scan"

  if ! find "$root" -type d \( \
      -name '.HEIC2JPG.convert.??????' -o \
      -name '.HEIC2JPG.validate.??????' -o \
      -name '.HEIC2JPG.??????' \) -prune -print0 > "$scan_buffer"; then
    printf '错误：照片目录扫描不完整：%s\n' "$root" >&2
    return 1
  fi

  while IFS= read -r -d '' directory; do
    if ! is_photo_temp_name "${directory##*/}" || ! consider_candidate "$directory"; then
      return 1
    fi
  done < "$scan_buffer"
  return 0
}

scan_system_temp() {
  local directory

  for directory in \
      "$temp_parent"/HEIC2JPG.state.?????? \
      "$temp_parent"/HEIC2JPG.??????; do
    [ -e "$directory" ] || [ -L "$directory" ] || continue
    if ! is_system_temp_name "${directory##*/}" || ! consider_candidate "$directory"; then
      return 1
    fi
  done
  return 0
}

if [ "${1:-}" = '-h' ] || [ "${1:-}" = '--help' ]; then
  usage
  exit 0
fi

for required_command in find mktemp shasum awk du rm; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf '错误：找不到必需的 macOS 命令：%s\n' "$required_command" >&2
    exit 1
  fi
done

if ! workspace=$(mktemp -d "$temp_parent/HEIC2JPG-cleaner.XXXXXX"); then
  printf '错误：无法创建清理工具工作区。\n' >&2
  exit 1
fi
candidates_file="$workspace/candidates"
seen_dir="$workspace/seen"
if ! : > "$candidates_file" || ! mkdir "$seen_dir"; then
  printf '错误：无法初始化清理工具工作区。\n' >&2
  exit 1
fi

roots=()
root_count=0
if [ "$#" -gt 0 ]; then
  for requested_root in "$@"; do
    if [ ! -d "$requested_root" ]; then
      printf '错误：照片文件夹不存在：%s\n' "$requested_root" >&2
      exit 2
    fi
    normalized_root=$(cd "$requested_root" 2>/dev/null && pwd -P) || {
      printf '错误：无法打开照片文件夹：%s\n' "$requested_root" >&2
      exit 2
    }
    roots[$root_count]=$normalized_root
    root_count=$((root_count + 1))
  done
else
  if ! command -v osascript >/dev/null 2>&1; then
    printf '错误：找不到 osascript，请在命令行中指定照片文件夹。\n' >&2
    exit 1
  fi
  picker_output=$(select_photo_folders) || exit 1
  while IFS= read -r requested_root; do
    [ -n "$requested_root" ] || continue
    normalized_root=$(cd "$requested_root" 2>/dev/null && pwd -P) || continue
    roots[$root_count]=$normalized_root
    root_count=$((root_count + 1))
  done <<EOF
$picker_output
EOF
fi

printf '\nHEIC2JPG 临时文件清理工具\n'
printf '只会查找本项目的临时目录，不会删除 JPG 或 HEIC 照片。\n'
if [ "$root_count" -eq 0 ]; then
  printf '未选择照片目录，仅检查系统临时目录：%s\n\n' "$temp_parent"
else
  printf '正在检查 %d 个照片根目录和系统临时目录：%s\n\n' \
    "$root_count" "$temp_parent"
fi

root_index=0
while [ "$root_index" -lt "$root_count" ]; do
  if ! scan_photo_root "${roots[$root_index]}"; then
    printf '安全停止：扫描不完整，没有删除任何目录。\n' >&2
    exit 1
  fi
  root_index=$((root_index + 1))
done
if ! scan_system_temp; then
  printf '安全停止：系统临时目录扫描失败，没有删除任何目录。\n' >&2
  exit 1
fi

if [ "$candidate_count" -eq 0 ]; then
  printf '\n没有找到本项目遗留的临时目录。\n'
  exit 0
fi

candidate_mb=$(awk -v kb="$candidate_kb" 'BEGIN {printf "%.1f", kb / 1024}')
printf '\n共找到 %d 个候选目录，约 %s MB。\n' "$candidate_count" "$candidate_mb"
printf '请确认目前没有 HEIC2JPG 转换任务正在运行。\n'
printf '确认删除以上临时目录吗？[y/N]：'
confirmation=''
if ! read_confirmation; then
  printf '\n未收到确认，已取消清理。\n'
  exit 0
fi
case "$confirmation" in
  y|Y) ;;
  *)
    printf '已取消清理，没有删除任何目录。\n'
    exit 0
    ;;
esac

deleted=0
while IFS= read -r -d '' directory; do
  [ -d "$directory" ] && [ ! -L "$directory" ] || continue

  if rm -rf "$directory" && [ ! -e "$directory" ]; then
    deleted=$((deleted + 1))
  else
    printf '删除失败：%s\n' "$directory" >&2
    delete_errors=$((delete_errors + 1))
  fi
done < "$candidates_file"

printf '\n清理完成：删除 %d 个临时目录，失败或跳过 %d 个。\n' \
  "$deleted" "$delete_errors"

if [ "$delete_errors" -gt 0 ]; then
  exit 1
fi
exit 0
