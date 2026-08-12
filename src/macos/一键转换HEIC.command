#!/bin/bash

# Copyright (c) 2026 Owen Pu. Licensed under the MIT License.
# 使用 macOS 系统自带 `sips` 的单文件 HEIC 转 JPG 工具，支持 Finder 双击和命令行。
# HEIC 原图会一直保留到转换、人工检查和最终完整性检查全部完成。

set -u

overwrite=0
quality=90
trust_decodable_existing=0
temp_parent=${TMPDIR:-/tmp}
temp_parent=${temp_parent%/}
if [ -z "$temp_parent" ]; then
  temp_parent=/
fi

state_dir=''
conversion_temp_dir=''
conversion_temporary=''
validation_temp_dir=''
validation_temporary=''
snapshot_stat=''
snapshot_hash=''
record_source=''
record_output=''
record_source_stat=''
record_source_hash=''
record_output_hash=''
receipt_source_hash=''
receipt_output_hash=''
receipt_version_attribute='io.github.star9platinum.heic2jpg.receipt-version'
receipt_source_attribute='io.github.star9platinum.heic2jpg.source-sha256'
receipt_output_attribute='io.github.star9platinum.heic2jpg.output-sha256'

usage() {
  cat <<'EOF'
用法：一键转换HEIC.command [-f] [-q 质量] [文件夹 ...]

选项：
  -f          重新转换并替换已有的同名普通 JPG 文件
  -q 质量     JPEG 质量，范围 1 到 100（默认：90）
  -h          显示此帮助

如果没有指定文件夹，会显示可多选的 macOS 文件夹选择器，并包含所有子文件夹。
转换和人工检查期间会保留 HEIC 原图。只有对应 JPG 已验证、输入 y 或 Y，
并且全部最终安全检查通过后，才会删除原图。
EOF
}

discard_conversion_temp() {
  if [ -n "$conversion_temporary" ]; then
    rm -f "$conversion_temporary" 2>/dev/null || true
    conversion_temporary=''
  fi
  if [ -n "$conversion_temp_dir" ]; then
    case "${conversion_temp_dir##*/}" in
      .HEIC2JPG.*)
        rm -rf "$conversion_temp_dir" 2>/dev/null || true
        ;;
    esac
    conversion_temp_dir=''
  fi
}

discard_validation_temp() {
  if [ -n "$validation_temporary" ]; then
    rm -f "$validation_temporary" 2>/dev/null || true
    validation_temporary=''
  fi
  if [ -n "$validation_temp_dir" ]; then
    case "${validation_temp_dir##*/}" in
      .HEIC2JPG.validate.*)
        rm -rf "$validation_temp_dir" 2>/dev/null || true
        ;;
    esac
    validation_temp_dir=''
  fi
}

cleanup() {
  discard_validation_temp
  discard_conversion_temp

  if [ -n "$state_dir" ] && [ -d "$state_dir" ]; then
    case "$state_dir" in
      "$temp_parent"/HEIC2JPG.*)
        rm -rf "$state_dir" 2>/dev/null || true
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

print_diagnostic_log() {
  local label=$1
  local log_path=$2
  local line=''

  if [ ! -s "$log_path" ]; then
    printf '%s：（命令没有返回诊断信息）\n' "$label" >&2
    return
  fi

  printf '%s:\n' "$label" >&2
  while IFS= read -r line || [ -n "$line" ]; do
    printf '  %s\n' "$line" >&2
  done < "$log_path"
}

select_photo_folders() {
  if ! command -v osascript >/dev/null 2>&1; then
    printf '错误：找不到 osascript，请在命令行中指定照片文件夹。\n' >&2
    return 1
  fi

  osascript <<'APPLESCRIPT'
try
  set selectedFolders to choose folder with prompt "选择一个或多个包含 HEIC 照片的根文件夹" with multiple selections allowed
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

sha256_file() {
  if [ ! -f "$1" ]; then
    return 1
  fi
  shasum -a 256 < "$1" 2>/dev/null | awk '{print $1}'
}

read_resume_receipt() {
  local jpeg_path=$1
  local receipt_version

  receipt_source_hash=''
  receipt_output_hash=''

  receipt_version=$(xattr -p "$receipt_version_attribute" "$jpeg_path" 2>/dev/null) || return 1
  [ "$receipt_version" = '1' ] || return 1
  receipt_source_hash=$(xattr -p "$receipt_source_attribute" "$jpeg_path" 2>/dev/null) || return 1
  receipt_output_hash=$(xattr -p "$receipt_output_attribute" "$jpeg_path" 2>/dev/null) || return 1

  printf '%s\n' "$receipt_source_hash" | grep -Eq '^[0-9a-fA-F]{64}$' || return 1
  printf '%s\n' "$receipt_output_hash" | grep -Eq '^[0-9a-fA-F]{64}$' || return 1
  return 0
}

write_resume_receipt() {
  local jpeg_path=$1
  local source_hash_value=$2
  local output_hash_value=$3

  if xattr -w "$receipt_version_attribute" '1' "$jpeg_path" 2>/dev/null && \
      xattr -w "$receipt_source_attribute" "$source_hash_value" "$jpeg_path" 2>/dev/null && \
      xattr -w "$receipt_output_attribute" "$output_hash_value" "$jpeg_path" 2>/dev/null && \
      read_resume_receipt "$jpeg_path" && \
      [ "$receipt_source_hash" = "$source_hash_value" ] && \
      [ "$receipt_output_hash" = "$output_hash_value" ]; then
    return 0
  fi

  xattr -d "$receipt_version_attribute" "$jpeg_path" 2>/dev/null || true
  xattr -d "$receipt_source_attribute" "$jpeg_path" 2>/dev/null || true
  xattr -d "$receipt_output_attribute" "$jpeg_path" 2>/dev/null || true
  return 1
}

path_key() {
  printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print $1}'
}

scan_selected_roots() {
  local scan_mode=$1
  local destination=$2
  local seen_dir=$3
  local scan_buffer="$state_dir/scan-buffer"
  local scan_root
  local discovered_path
  local discovered_key

  if ! mkdir "$seen_dir" || ! : > "$destination"; then
    return 1
  fi

  while IFS= read -r -d '' scan_root; do
    case "$scan_mode" in
      eligible)
        find "$scan_root" -type f -name '*.[Hh][Ee][Ii][Cc]' ! -name '.*' \
          -print0 > "$scan_buffer" || return 1
        ;;
      hidden)
        find "$scan_root" -type f -name '*.[Hh][Ee][Ii][Cc]' -name '.*' \
          -print0 > "$scan_buffer" || return 1
        ;;
      *)
        return 1
        ;;
    esac

    while IFS= read -r -d '' discovered_path; do
      discovered_key=$(path_key "$discovered_path")
      if [ -z "$discovered_key" ]; then
        return 1
      fi
      if [ ! -e "$seen_dir/$discovered_key" ]; then
        if ! : > "$seen_dir/$discovered_key" || \
            ! printf '%s\0' "$discovered_path" >> "$destination"; then
          return 1
        fi
      fi
    done < "$scan_buffer"
  done < "$roots_file"

  rm -f "$scan_buffer" 2>/dev/null || true
  return 0
}

snapshot_file() {
  local snapshot_path=$1
  local before_stat
  local after_stat
  local calculated_hash

  snapshot_stat=''
  snapshot_hash=''

  before_stat=$(stat -f '%d:%i:%z:%m:%c' "$snapshot_path" 2>/dev/null) || return 1
  calculated_hash=$(sha256_file "$snapshot_path") || return 1
  after_stat=$(stat -f '%d:%i:%z:%m:%c' "$snapshot_path" 2>/dev/null) || return 1

  if [ "$before_stat" != "$after_stat" ] || [ -z "$calculated_hash" ]; then
    return 1
  fi

  snapshot_stat=$after_stat
  snapshot_hash=$calculated_hash
  return 0
}

validate_jpeg() {
  local jpeg_path=$1
  local info
  local width
  local height
  local jpeg_dir
  local inspect_log="$state_dir/sips-inspect.log"
  local decode_log="$state_dir/sips-validation.log"
  local command_status

  if [ ! -s "$jpeg_path" ]; then
    printf '验证详情：JPG 不存在或是空文件：%s\n' "$jpeg_path" >&2
    return 1
  fi

  : > "$inspect_log"
  sips -g format -g pixelWidth -g pixelHeight "$jpeg_path" > "$inspect_log" 2>&1
  command_status=$?
  if [ "$command_status" -ne 0 ]; then
    printf '验证详情：sips 无法检查 JPG（退出码 %d）。\n' \
      "$command_status" >&2
    print_diagnostic_log 'sips 检查输出' "$inspect_log"
    return 1
  fi
  info=$(<"$inspect_log")
  if ! printf '%s\n' "$info" | grep -Eiq 'format:[[:space:]]*(jpeg|jpg)'; then
    printf '验证详情：sips 没有把输出识别为 JPEG。\n' >&2
    print_diagnostic_log 'sips 检查输出' "$inspect_log"
    return 1
  fi

  width=$(printf '%s\n' "$info" | awk '/pixelWidth:/ {print $2; exit}')
  height=$(printf '%s\n' "$info" | awk '/pixelHeight:/ {print $2; exit}')
  case "$width" in
    ''|*[!0-9]*)
      printf '验证详情：sips 返回的 JPEG 宽度无效：%s\n' "$width" >&2
      return 1
      ;;
  esac
  case "$height" in
    ''|*[!0-9]*)
      printf '验证详情：sips 返回的 JPEG 高度无效：%s\n' "$height" >&2
      return 1
      ;;
  esac
  if [ "$width" -le 0 ] || [ "$height" -le 0 ]; then
    printf '验证详情：JPEG 尺寸必须大于 0，实际为 %sx%s。\n' \
      "$width" "$height" >&2
    return 1
  fi

  discard_validation_temp
  case "$jpeg_path" in
    */*) jpeg_dir=${jpeg_path%/*} ;;
    *) jpeg_dir=. ;;
  esac
  if ! validation_temp_dir=$(mktemp -d "$jpeg_dir/.HEIC2JPG.validate.XXXXXX"); then
    printf '验证详情：无法在 JPG 所在目录创建验证临时文件夹：%s\n' \
      "$jpeg_path" >&2
    validation_temp_dir=''
    return 1
  fi
  validation_temporary="$validation_temp_dir/validation.jpg"
  : > "$decode_log"
  sips -s format jpeg "$jpeg_path" --out "$validation_temporary" > "$decode_log" 2>&1
  command_status=$?
  if [ "$command_status" -ne 0 ]; then
    printf '验证详情：sips 无法完整解码 JPG（退出码 %d）。\n' \
      "$command_status" >&2
    print_diagnostic_log 'sips 验证输出' "$decode_log"
    discard_validation_temp
    return 1
  fi
  if [ ! -s "$validation_temporary" ]; then
    printf '验证详情：完整解码 JPEG 后生成了空文件。\n' >&2
    discard_validation_temp
    return 1
  fi

  discard_validation_temp
  return 0
}

load_record() {
  local record_path=$1

  record_source=''
  record_output=''
  record_source_stat=''
  record_source_hash=''
  record_output_hash=''

  exec 3< "$record_path" || return 1
  IFS= read -r -d '' record_source <&3 || { exec 3<&-; return 1; }
  IFS= read -r -d '' record_output <&3 || { exec 3<&-; return 1; }
  IFS= read -r -d '' record_source_stat <&3 || { exec 3<&-; return 1; }
  IFS= read -r -d '' record_source_hash <&3 || { exec 3<&-; return 1; }
  IFS= read -r -d '' record_output_hash <&3 || { exec 3<&-; return 1; }
  exec 3<&-
  return 0
}

save_safety_record() {
  local source_path=$1
  local output_path=$2
  local source_stat_value=$3
  local source_hash_value=$4
  local output_hash_value=$5
  local source_key

  source_key=$(path_key "$source_path")
  if [ -z "$output_hash_value" ] || [ -z "$source_key" ] || \
      [ -e "$records_dir/$source_key" ]; then
    return 1
  fi

  if ! printf '%s\0%s\0%s\0%s\0%s\0' \
      "$source_path" "$output_path" "$source_stat_value" \
      "$source_hash_value" "$output_hash_value" > "$records_dir/$source_key"; then
    rm -f "$records_dir/$source_key" 2>/dev/null || true
    return 1
  fi
  return 0
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

while getopts ':fq:h' option; do
  case "$option" in
    f)
      overwrite=1
      ;;
    q)
      quality=$OPTARG
      ;;
    h)
      usage
      exit 0
      ;;
    :)
      printf '错误：-%s 需要一个参数值。\n' "$OPTARG" >&2
      usage >&2
      exit 2
      ;;
    \?)
      printf '错误：未知选项 -%s。\n' "$OPTARG" >&2
      usage >&2
      exit 2
      ;;
  esac
done
shift $((OPTIND - 1))

case "$quality" in
  ''|*[!0-9]*)
    printf '错误：质量必须是 1 到 100 之间的整数。\n' >&2
    exit 2
    ;;
esac
if [ "$quality" -lt 1 ] || [ "$quality" -gt 100 ]; then
  printf '错误：质量必须在 1 到 100 之间。\n' >&2
  exit 2
fi

requested_roots=()
requested_count=0
if [ "$#" -gt 0 ]; then
  for requested_root in "$@"; do
    requested_roots[$requested_count]=$requested_root
    requested_count=$((requested_count + 1))
  done
else
  printf '请在 macOS 对话框中选择一个或多个照片文件夹……\n'
  if ! picker_output=$(select_photo_folders); then
    exit 1
  fi
  while IFS= read -r requested_root; do
    if [ -n "$requested_root" ]; then
      requested_roots[$requested_count]=$requested_root
      requested_count=$((requested_count + 1))
    fi
  done <<EOF
$picker_output
EOF
  if [ "$requested_count" -eq 0 ]; then
    printf '已取消，没有修改任何照片。\n'
    exit 0
  fi
fi

normalized_roots=()
normalized_count=0
requested_index=0
while [ "$requested_index" -lt "$requested_count" ]; do
  requested_root=${requested_roots[$requested_index]}
  case "$requested_root" in
    *$'\n'*|*$'\r'*)
      printf '错误：所选根目录路径中包含换行符，暂不支持。\n' >&2
      exit 2
      ;;
  esac

  if [ ! -d "$requested_root" ]; then
    printf '错误：文件夹不存在：%s\n' "$requested_root" >&2
    exit 2
  fi
  if ! normalized_root=$(cd "$requested_root" 2>/dev/null && pwd -P); then
    printf '错误：无法打开文件夹：%s\n' "$requested_root" >&2
    exit 2
  fi

  duplicate_root=0
  normalized_index=0
  while [ "$normalized_index" -lt "$normalized_count" ]; do
    if [ "${normalized_roots[$normalized_index]}" = "$normalized_root" ]; then
      duplicate_root=1
      break
    fi
    normalized_index=$((normalized_index + 1))
  done
  if [ "$duplicate_root" -eq 0 ]; then
    normalized_roots[$normalized_count]=$normalized_root
    normalized_count=$((normalized_count + 1))
  fi
  requested_index=$((requested_index + 1))
done

for required_command in sips shasum stat find awk grep open mktemp xattr; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf '错误：找不到必需的 macOS 命令：%s\n' "$required_command" >&2
    exit 1
  fi
done

if ! state_dir=$(mktemp -d "$temp_parent/HEIC2JPG.XXXXXX"); then
  printf '错误：无法创建私有安全工作区。\n' >&2
  exit 1
fi

records_dir="$state_dir/records"
planned_outputs_dir="$state_dir/planned-outputs"
roots_file="$state_dir/selected-roots"
initial_scan="$state_dir/initial-heic-list"
final_scan="$state_dir/final-heic-list"
skipped_hidden_scan="$state_dir/skipped-hidden-heic-list"
initial_seen_dir="$state_dir/initial-seen"
hidden_seen_dir="$state_dir/hidden-seen"
final_seen_dir="$state_dir/final-seen"
if ! mkdir "$records_dir" "$planned_outputs_dir"; then
  printf '错误：无法初始化安全工作区。\n' >&2
  exit 1
fi
if ! : > "$roots_file"; then
  printf '错误：无法保存所选文件夹列表。\n' >&2
  exit 1
fi
normalized_index=0
while [ "$normalized_index" -lt "$normalized_count" ]; do
  if ! printf '%s\0' "${normalized_roots[$normalized_index]}" >> "$roots_file"; then
    printf '错误：无法保存所选文件夹。\n' >&2
    exit 1
  fi
  normalized_index=$((normalized_index + 1))
done

printf '\nmacOS HEIC 转 JPG\n'
printf '已选文件夹（%d 个）：\n' "$normalized_count"
normalized_index=0
while [ "$normalized_index" -lt "$normalized_count" ]; do
  printf '  %s\n' "${normalized_roots[$normalized_index]}"
  normalized_index=$((normalized_index + 1))
done
if command -v sw_vers >/dev/null 2>&1; then
  printf 'macOS: %s\n' "$(sw_vers -productVersion 2>/dev/null)"
fi
printf '图片转换器：%s\n' "$(command -v sips)"
printf '将包含全部子文件夹。\n'
printf '转换和人工检查期间，所有 HEIC 原图都会保留。\n\n'

if [ "$overwrite" -eq 0 ]; then
  printf '兼容续传选项：是否把“同名且能完整解码”的已有 JPG 直接视为转换成功？[y/N]：'
  confirmation=''
  if read_confirmation; then
    case "$confirmation" in
      y|Y)
        trust_decodable_existing=1
        printf '已启用宽松续传：将跳过 JPG 与旁边 HEIC 的来源指纹核验。请务必人工确认照片内容。\n\n'
        ;;
      *)
        printf '使用默认严格续传：必须同时匹配 HEIC 和 JPG 的 SHA-256 断点指纹。\n\n'
        ;;
    esac
  else
    printf '\n未收到输入，使用默认严格续传。\n\n'
  fi
else
  printf '已使用 -f：已有同名 JPG 将重新转换并替换，不启用断点复用。\n\n'
fi

if ! scan_selected_roots eligible "$initial_scan" "$initial_seen_dir"; then
  printf '安全停止：一个或多个文件夹扫描不完整，没有修改任何文件。\n' >&2
  exit 1
fi
if ! scan_selected_roots hidden "$skipped_hidden_scan" "$hidden_seen_dir"; then
  printf '安全停止：隐藏文件扫描不完整，没有修改任何文件。\n' >&2
  exit 1
fi

skipped_hidden=0
while IFS= read -r -d '' hidden_input; do
  skipped_hidden=$((skipped_hidden + 1))
  if [ "$skipped_hidden" -le 20 ]; then
    printf '跳过隐藏 HEIC（保持不变）：%s\n' "$hidden_input"
  fi
done < "$skipped_hidden_scan"
if [ "$skipped_hidden" -gt 20 ]; then
  printf '……以及另外 %d 个隐藏 HEIC 文件。\n' "$((skipped_hidden - 20))"
fi
if [ "$skipped_hidden" -gt 0 ]; then
  printf '已跳过 %d 个隐藏 HEIC 文件；不会转换或删除它们。\n\n' \
    "$skipped_hidden"
fi

found=0
preflight_errors=0
while IFS= read -r -d '' input; do
  found=$((found + 1))
  base_name=${input##*/}
  stem=${base_name%.*}
  output=${input%.*}.jpg

  if [ -z "$stem" ]; then
    printf '预检查失败：HEIC 文件名没有可用的主体名称：%s\n' "$input" >&2
    preflight_errors=$((preflight_errors + 1))
    continue
  fi

  output_key=$(path_key "$output")
  if [ -z "$output_key" ]; then
    printf '预检查失败：无法计算输出路径指纹：%s\n' "$output" >&2
    preflight_errors=$((preflight_errors + 1))
    continue
  fi
  if [ -e "$planned_outputs_dir/$output_key" ]; then
    printf '预检查失败：多个 HEIC 会映射到同一个 JPG：%s\n' "$output" >&2
    preflight_errors=$((preflight_errors + 1))
    continue
  fi
  if ! printf '%s\0' "$output" > "$planned_outputs_dir/$output_key"; then
    printf '预检查失败：无法记录输出路径：%s\n' "$output" >&2
    preflight_errors=$((preflight_errors + 1))
    continue
  fi

  if [ -e "$output" ] || [ -L "$output" ]; then
    if [ -L "$output" ] || [ ! -f "$output" ]; then
      printf '预检查失败：已有的 JPG 目标不是普通文件：%s\n' "$output" >&2
      preflight_errors=$((preflight_errors + 1))
    elif [ "$overwrite" -eq 0 ]; then
      if [ "$trust_decodable_existing" -eq 1 ]; then
        printf '发现宽松续传候选，将只验证 JPG 能否完整解码：%s\n' "$output"
      else
        printf '发现断点续传候选，将核验来源与文件指纹：%s\n' "$output"
      fi
    fi
  fi
done < "$initial_scan"

if [ "$found" -eq 0 ]; then
  printf '没有找到非隐藏的 HEIC 文件。\n'
  exit 0
fi
if [ "$preflight_errors" -gt 0 ]; then
  printf '安全停止：%d 项预检查失败，没有转换或删除任何文件。\n' \
    "$preflight_errors" >&2
  exit 1
fi

converted=0
reused=0
failed=0
receipt_warnings=0

while IFS= read -r -d '' input; do
  output=${input%.*}.jpg
  output_dir=${output%/*}

  if ! snapshot_file "$input"; then
    printf '失败，已保留原图：源文件状态不稳定：%s\n' "$input" >&2
    failed=$((failed + 1))
    continue
  fi
  source_stat=$snapshot_stat
  source_hash=$snapshot_hash

  if { [ -e "$output" ] || [ -L "$output" ]; } && [ "$overwrite" -eq 0 ]; then
    if [ -L "$output" ] || [ ! -f "$output" ]; then
      printf '已跳过并保留原图：已有 JPG 已不再是普通文件：%s\n' \
        "$output" >&2
      failed=$((failed + 1))
      continue
    fi

    if [ "$trust_decodable_existing" -eq 0 ]; then
      if ! read_resume_receipt "$output"; then
        printf '已跳过并保留原图：已有 JPG 没有本脚本写入的断点续传指纹：%s\n' \
          "$output" >&2
        printf '可在下次运行开始时输入 y 启用宽松续传，或使用 -f 重新转换。\n' >&2
        failed=$((failed + 1))
        continue
      fi
      expected_source_hash=$receipt_source_hash
      expected_output_hash=$receipt_output_hash
      if [ "$expected_source_hash" != "$source_hash" ]; then
        printf '已跳过并保留原图：断点记录中的 HEIC 指纹与当前原图不一致：%s\n' \
          "$input" >&2
        printf '可在下次运行开始时输入 y 启用宽松续传，或使用 -f 重新转换。\n' >&2
        failed=$((failed + 1))
        continue
      fi
    fi

    if ! snapshot_file "$output"; then
      printf '已跳过并保留原图：已有 JPG 状态不稳定：%s\n' "$output" >&2
      failed=$((failed + 1))
      continue
    fi
    existing_output_stat=$snapshot_stat
    existing_output_hash=$snapshot_hash
    if [ "$trust_decodable_existing" -eq 0 ] && \
        [ "$existing_output_hash" != "$expected_output_hash" ]; then
      printf '已跳过并保留原图：已有 JPG 的内容指纹与断点记录不一致：%s\n' \
        "$output" >&2
      printf '可在下次运行开始时输入 y 启用宽松续传，或使用 -f 重新转换。\n' >&2
      failed=$((failed + 1))
      continue
    fi

    printf '验证已有 JPG：%s -> %s\n' "$input" "$output"
    if ! validate_jpeg "$output"; then
      printf '已跳过并保留原图：已有 JPG 验证失败：%s\n' "$output" >&2
      failed=$((failed + 1))
      continue
    fi
    if ! snapshot_file "$output" || [ "$snapshot_stat" != "$existing_output_stat" ] || \
        [ "$snapshot_hash" != "$existing_output_hash" ]; then
      printf '已跳过并保留原图：已有 JPG 在验证期间发生变化：%s\n' \
        "$output" >&2
      failed=$((failed + 1))
      continue
    fi
    if ! snapshot_file "$input" || [ "$snapshot_stat" != "$source_stat" ] || \
        [ "$snapshot_hash" != "$source_hash" ]; then
      printf '已跳过并保留原图：验证 JPG 时源 HEIC 发生变化：%s\n' \
        "$input" >&2
      failed=$((failed + 1))
      continue
    fi
    if [ "$trust_decodable_existing" -eq 0 ]; then
      if ! read_resume_receipt "$output" || \
          [ "$receipt_source_hash" != "$expected_source_hash" ] || \
          [ "$receipt_output_hash" != "$expected_output_hash" ]; then
        printf '已跳过并保留原图：JPG 的断点续传记录在验证期间发生变化：%s\n' \
          "$output" >&2
        failed=$((failed + 1))
        continue
      fi
    fi
    if ! save_safety_record "$input" "$output" "$source_stat" "$source_hash" \
        "$existing_output_hash"; then
      printf '已跳过并保留原图：无法安全记录已有 JPG：%s\n' \
        "$output" >&2
      failed=$((failed + 1))
      continue
    fi

    if [ "$trust_decodable_existing" -eq 1 ]; then
      printf '宽松续传成功：同名 JPG 已通过完整解码验证；未核验它是否由旁边的 HEIC 转换而来，请人工确认。\n'
    else
      printf '断点续传成功：来源和 JPG 的 SHA-256 指纹一致，且 JPG 已通过完整解码验证；删除前仍请人工检查。\n'
    fi
    reused=$((reused + 1))
    continue
  fi

  if ! conversion_temp_dir=$(mktemp -d "$output_dir/.HEIC2JPG.XXXXXX"); then
    printf '失败，已保留原图：无法在照片旁创建临时文件夹：%s\n' "$input" >&2
    failed=$((failed + 1))
    continue
  fi
  conversion_temporary="$conversion_temp_dir/output.jpg"

  printf '正在转换：%s -> %s\n' "$input" "$output"
  conversion_log="$state_dir/sips-convert.log"
  : > "$conversion_log"
  sips -s format jpeg -s formatOptions "$quality" "$input" \
    --out "$conversion_temporary" > "$conversion_log" 2>&1
  conversion_status=$?
  if [ "$conversion_status" -ne 0 ]; then
    printf '失败，已保留原图：sips 无法转换 %s（退出码 %d）。\n' \
      "$input" "$conversion_status" >&2
    print_diagnostic_log 'sips 转换输出' "$conversion_log"
    printf '请确认该 HEIC 已从 iCloud 完整下载，并能在“预览”中正常打开。\n' >&2
    discard_conversion_temp
    failed=$((failed + 1))
    continue
  fi

  if ! validate_jpeg "$conversion_temporary"; then
    printf '失败，已保留原图：生成的 JPG 验证失败：%s\n' \
      "$input" >&2
    discard_conversion_temp
    failed=$((failed + 1))
    continue
  fi

  if ! snapshot_file "$input" || [ "$snapshot_stat" != "$source_stat" ] || \
      [ "$snapshot_hash" != "$source_hash" ]; then
    printf '失败，已保留原图：源 HEIC 在转换期间发生变化。\n' >&2
    discard_conversion_temp
    failed=$((failed + 1))
    continue
  fi

  source_mode=$(stat -f '%Lp' "$input" 2>/dev/null)
  if [ -n "$source_mode" ]; then
    chmod "$source_mode" "$conversion_temporary" 2>/dev/null || \
      printf '权限警告：无法复制源文件权限。\n' >&2
  fi
  touch -r "$input" "$conversion_temporary" 2>/dev/null || \
    printf '时间戳警告：无法复制源文件时间戳。\n' >&2

  if [ -e "$output" ] || [ -L "$output" ]; then
    if [ "$overwrite" -eq 0 ] || [ -L "$output" ] || [ ! -f "$output" ]; then
      printf '失败，已保留原图：JPG 目标在预检查后发生变化：%s\n' "$output" >&2
      discard_conversion_temp
      failed=$((failed + 1))
      continue
    fi
  fi

  if ! mv -f "$conversion_temporary" "$output"; then
    printf '失败，已保留原图：无法保存生成的 JPG：%s\n' "$output" >&2
    discard_conversion_temp
    failed=$((failed + 1))
    continue
  fi
  conversion_temporary=''
  rm -rf "$conversion_temp_dir" 2>/dev/null || true
  conversion_temp_dir=''

  output_hash=$(sha256_file "$output")
  if [ -n "$output_hash" ] && \
      ! write_resume_receipt "$output" "$source_hash" "$output_hash"; then
    printf '警告：无法在 JPG 上写入断点续传指纹；本次仍可安全确认删除，但中断后需要用 -f 重新转换：%s\n' \
      "$output" >&2
    receipt_warnings=$((receipt_warnings + 1))
  fi
  if ! save_safety_record "$input" "$output" "$source_stat" "$source_hash" \
      "$output_hash"; then
    printf '失败，已保留原图：无法保存安全快照。\n' >&2
    failed=$((failed + 1))
    continue
  fi

  converted=$((converted + 1))
done < "$initial_scan"

ready=$((converted + reused))
printf '\n转换结束：共 %d 个可处理文件，新转换 %d 个，断点续传 %d 个，因问题跳过 %d 个，跳过隐藏文件 %d 个。\n' \
  "$found" "$converted" "$reused" "$failed" "$skipped_hidden"
printf '目前尚未删除任何 HEIC 原图。\n'
if [ "$receipt_warnings" -gt 0 ]; then
  printf '其中 %d 个 JPG 无法保存持久断点指纹；如果本次中断，重新运行时需要使用 -f。\n' \
    "$receipt_warnings" >&2
fi

if [ "$ready" -eq 0 ]; then
  printf '没有 HEIC 可以进入删除确认；存在问题的文件均已保留。\n' >&2
  exit 1
fi
if [ "$failed" -gt 0 ]; then
  printf '继续处理 %d 个已验证文件；%d 个存在问题的 HEIC 将被保留。\n' \
    "$ready" "$failed"
fi

printf '\n正在 Finder 中打开所选文件夹。\n'
printf '请人工检查 JPG 的内容、方向、画质和数量，然后返回此窗口。\n'
finder_errors=0
while IFS= read -r -d '' selected_root; do
  if ! open "$selected_root"; then
    printf 'Finder 无法打开：%s\n' "$selected_root" >&2
    finder_errors=$((finder_errors + 1))
  fi
done < "$roots_file"
if [ "$finder_errors" -gt 0 ]; then
  printf '安全停止：%d 个所选文件夹无法打开，没有删除任何 HEIC。\n' \
    "$finder_errors" >&2
  exit 1
fi

printf '\n%d 个已验证的 HEIC 原图可以删除；%d 个存在问题的文件将保留。\n' \
  "$ready" "$failed"
printf '如果所有已验证 JPG 均确认无误，是否删除对应的 HEIC 原图？[y/N]：'
confirmation=''
if ! read_confirmation; then
  printf '\n已取消删除：没有收到交互式确认。\n'
  printf '所有 HEIC 原图均已保留。\n'
  exit 0
fi
case "$confirmation" in
  y|Y)
    ;;
  *)
    printf '已取消删除，所有 HEIC 原图均已保留。\n'
    exit 0
    ;;
esac

printf '\n删除前正在执行最终安全检查……\n'
predelete_errors=0
current_count=0

if ! scan_selected_roots eligible "$final_scan" "$final_seen_dir"; then
  printf '安全检查失败：一个或多个文件夹的最终扫描不完整。\n' >&2
  predelete_errors=$((predelete_errors + 1))
else
  while IFS= read -r -d '' current_heic; do
    current_count=$((current_count + 1))
    current_key=$(path_key "$current_heic")
    if [ -z "$current_key" ] || [ ! -f "$initial_seen_dir/$current_key" ]; then
      printf '安全检查失败：发现非预期的 HEIC 文件：%s\n' "$current_heic" >&2
      predelete_errors=$((predelete_errors + 1))
    fi
  done < "$final_scan"
fi

if [ "$current_count" -ne "$found" ]; then
  printf '安全检查失败：人工检查期间 HEIC 文件集合发生变化。\n' >&2
  predelete_errors=$((predelete_errors + 1))
fi

for record_path in "$records_dir"/*; do
  if ! load_record "$record_path"; then
    printf '安全检查失败：有一条安全记录无法读取。\n' >&2
    predelete_errors=$((predelete_errors + 1))
    continue
  fi

  if ! snapshot_file "$record_source" || [ "$snapshot_stat" != "$record_source_stat" ] || \
      [ "$snapshot_hash" != "$record_source_hash" ]; then
    printf '安全检查失败：源 HEIC 已发生变化：%s\n' "$record_source" >&2
    predelete_errors=$((predelete_errors + 1))
  fi

  current_output_hash=$(sha256_file "$record_output")
  if [ -z "$current_output_hash" ] || [ "$current_output_hash" != "$record_output_hash" ]; then
    printf '安全检查失败：生成的 JPG 已发生变化：%s\n' "$record_output" >&2
    predelete_errors=$((predelete_errors + 1))
  elif ! validate_jpeg "$record_output"; then
    printf '安全检查失败：生成的 JPG 已无法通过验证：%s\n' "$record_output" >&2
    predelete_errors=$((predelete_errors + 1))
  fi
done

if [ "$predelete_errors" -gt 0 ]; then
  printf '安全停止：%d 项最终检查失败，没有删除任何 HEIC。\n' \
    "$predelete_errors" >&2
  exit 1
fi

deleted=0
delete_errors=0

for record_path in "$records_dir"/*; do
  if ! load_record "$record_path"; then
    printf '删除前无法读取一条安全记录。\n' >&2
    delete_errors=$((delete_errors + 1))
    continue
  fi

  if ! snapshot_file "$record_source" || [ "$snapshot_stat" != "$record_source_stat" ] || \
      [ "$snapshot_hash" != "$record_source_hash" ]; then
    printf '无法删除原图，因为 HEIC 已发生变化：%s\n' "$record_source" >&2
    delete_errors=$((delete_errors + 1))
    continue
  fi
  current_output_hash=$(sha256_file "$record_output")
  if [ -z "$current_output_hash" ] || [ "$current_output_hash" != "$record_output_hash" ]; then
    printf '无法删除原图，因为 JPG 已发生变化：%s\n' "$record_output" >&2
    delete_errors=$((delete_errors + 1))
    continue
  fi

  if rm -f "$record_source" && [ ! -e "$record_source" ]; then
    deleted=$((deleted + 1))
  else
    printf '无法删除原图：%s\n' "$record_source" >&2
    delete_errors=$((delete_errors + 1))
  fi
done

printf '\n完成：已验证 %d 个 JPG，已删除 %d 个 HEIC 原图，保留 %d 个问题原图，删除错误 %d 个。\n' \
  "$ready" "$deleted" "$failed" "$delete_errors"

if [ "$delete_errors" -gt 0 ]; then
  exit 1
fi

exit 0
