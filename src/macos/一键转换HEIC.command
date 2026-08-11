#!/bin/bash

# Copyright (c) 2026 Owen Pu. Licensed under the MIT License.
# Single-file Finder and command-line HEIC to JPG converter using macOS `sips`.
# HEIC originals are retained until conversion, manual review, and final
# integrity checks have completed successfully.

set -u

overwrite=0
quality=90
temp_parent=${TMPDIR:-/tmp}
temp_parent=${temp_parent%/}
if [ -z "$temp_parent" ]; then
  temp_parent=/
fi

state_dir=''
conversion_temp_dir=''
conversion_temporary=''
validation_temporary=''
snapshot_stat=''
snapshot_hash=''
record_source=''
record_output=''
record_source_stat=''
record_source_hash=''
record_output_hash=''

usage() {
  cat <<'EOF'
Usage: 一键转换HEIC.command [-f] [-q quality] [directory ...]

Options:
  -f          Replace existing regular same-name JPG files
  -q quality  JPEG quality from 1 to 100 (default: 90)
  -h          Show this help

If no directory is specified, a multi-select macOS folder picker is shown.
All subfolders are included. HEIC originals are kept during conversion and
manual review. Only originals with verified JPG files are deleted, and only
after y or Y is entered and every final safety check passes.
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

cleanup() {
  discard_conversion_temp
  if [ -n "$validation_temporary" ]; then
    rm -f "$validation_temporary" 2>/dev/null || true
  fi

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
    IFS= read -r _ < /dev/tty || true
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
    printf '%s: (the command returned no diagnostic text)\n' "$label" >&2
    return
  fi

  printf '%s:\n' "$label" >&2
  while IFS= read -r line || [ -n "$line" ]; do
    printf '  %s\n' "$line" >&2
  done < "$log_path"
}

select_photo_folders() {
  if ! command -v osascript >/dev/null 2>&1; then
    printf 'Error: osascript was not found. Specify a directory on the command line.\n' >&2
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
  local inspect_log="$state_dir/sips-inspect.log"
  local decode_log="$state_dir/sips-validation.log"
  local command_status

  if [ ! -s "$jpeg_path" ]; then
    printf 'Validation detail: generated JPG is missing or empty: %s\n' "$jpeg_path" >&2
    return 1
  fi

  : > "$inspect_log"
  sips -g format -g pixelWidth -g pixelHeight "$jpeg_path" > "$inspect_log" 2>&1
  command_status=$?
  if [ "$command_status" -ne 0 ]; then
    printf 'Validation detail: sips could not inspect the generated JPG (exit %d).\n' \
      "$command_status" >&2
    print_diagnostic_log 'sips inspection output' "$inspect_log"
    return 1
  fi
  info=$(<"$inspect_log")
  if ! printf '%s\n' "$info" | grep -Eiq 'format:[[:space:]]*(jpeg|jpg)'; then
    printf 'Validation detail: sips did not identify the output as JPEG.\n' >&2
    print_diagnostic_log 'sips inspection output' "$inspect_log"
    return 1
  fi

  width=$(printf '%s\n' "$info" | awk '/pixelWidth:/ {print $2; exit}')
  height=$(printf '%s\n' "$info" | awk '/pixelHeight:/ {print $2; exit}')
  case "$width" in
    ''|*[!0-9]*)
      printf 'Validation detail: invalid JPEG width reported by sips: %s\n' "$width" >&2
      return 1
      ;;
  esac
  case "$height" in
    ''|*[!0-9]*)
      printf 'Validation detail: invalid JPEG height reported by sips: %s\n' "$height" >&2
      return 1
      ;;
  esac
  if [ "$width" -le 0 ] || [ "$height" -le 0 ]; then
    printf 'Validation detail: JPEG dimensions must be positive, got %sx%s.\n' \
      "$width" "$height" >&2
    return 1
  fi

  validation_temporary="$state_dir/validation.jpg"
  rm -f "$validation_temporary" 2>/dev/null || true
  : > "$decode_log"
  sips -s format jpeg "$jpeg_path" --out "$validation_temporary" > "$decode_log" 2>&1
  command_status=$?
  if [ "$command_status" -ne 0 ]; then
    printf 'Validation detail: sips could not fully decode the generated JPG (exit %d).\n' \
      "$command_status" >&2
    print_diagnostic_log 'sips validation output' "$decode_log"
    rm -f "$validation_temporary" 2>/dev/null || true
    validation_temporary=''
    return 1
  fi
  if [ ! -s "$validation_temporary" ]; then
    printf 'Validation detail: full JPEG decode produced an empty file.\n' >&2
    rm -f "$validation_temporary" 2>/dev/null || true
    validation_temporary=''
    return 1
  fi

  rm -f "$validation_temporary" 2>/dev/null || true
  validation_temporary=''
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
      printf 'Error: -%s requires a value.\n' "$OPTARG" >&2
      usage >&2
      exit 2
      ;;
    \?)
      printf 'Error: unknown option -%s.\n' "$OPTARG" >&2
      usage >&2
      exit 2
      ;;
  esac
done
shift $((OPTIND - 1))

case "$quality" in
  ''|*[!0-9]*)
    printf 'Error: quality must be an integer from 1 to 100.\n' >&2
    exit 2
    ;;
esac
if [ "$quality" -lt 1 ] || [ "$quality" -gt 100 ]; then
  printf 'Error: quality must be between 1 and 100.\n' >&2
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
  printf 'Choose one or more photo folders in the macOS dialog...\n'
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
    printf 'Cancelled. No photos were changed.\n'
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
      printf 'Error: a selected root path contains a line break, which is not supported.\n' >&2
      exit 2
      ;;
  esac

  if [ ! -d "$requested_root" ]; then
    printf 'Error: directory does not exist: %s\n' "$requested_root" >&2
    exit 2
  fi
  if ! normalized_root=$(cd "$requested_root" 2>/dev/null && pwd -P); then
    printf 'Error: directory could not be opened: %s\n' "$requested_root" >&2
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

for required_command in sips shasum stat find awk grep open mktemp; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'Error: required macOS command was not found: %s\n' "$required_command" >&2
    exit 1
  fi
done

if ! state_dir=$(mktemp -d "$temp_parent/HEIC2JPG.XXXXXX"); then
  printf 'Error: could not create the private safety workspace.\n' >&2
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
  printf 'Error: could not initialize the safety workspace.\n' >&2
  exit 1
fi
if ! : > "$roots_file"; then
  printf 'Error: could not save the selected folder list.\n' >&2
  exit 1
fi
normalized_index=0
while [ "$normalized_index" -lt "$normalized_count" ]; do
  if ! printf '%s\0' "${normalized_roots[$normalized_index]}" >> "$roots_file"; then
    printf 'Error: could not save a selected folder.\n' >&2
    exit 1
  fi
  normalized_index=$((normalized_index + 1))
done

printf '\nHEIC -> JPG for macOS\n'
printf 'Selected folders (%d):\n' "$normalized_count"
normalized_index=0
while [ "$normalized_index" -lt "$normalized_count" ]; do
  printf '  %s\n' "${normalized_roots[$normalized_index]}"
  normalized_index=$((normalized_index + 1))
done
if command -v sw_vers >/dev/null 2>&1; then
  printf 'macOS: %s\n' "$(sw_vers -productVersion 2>/dev/null)"
fi
printf 'Image converter: %s\n' "$(command -v sips)"
printf 'Subfolders are included.\n'
printf 'All HEIC originals stay in place during conversion and manual review.\n\n'

if ! scan_selected_roots eligible "$initial_scan" "$initial_seen_dir"; then
  printf 'SAFETY STOP: One or more folder scans were incomplete. No files were changed.\n' >&2
  exit 1
fi
if ! scan_selected_roots hidden "$skipped_hidden_scan" "$hidden_seen_dir"; then
  printf 'SAFETY STOP: The hidden-file scan was incomplete. No files were changed.\n' >&2
  exit 1
fi

skipped_hidden=0
while IFS= read -r -d '' hidden_input; do
  skipped_hidden=$((skipped_hidden + 1))
  if [ "$skipped_hidden" -le 20 ]; then
    printf 'Skip hidden HEIC (kept unchanged): %s\n' "$hidden_input"
  fi
done < "$skipped_hidden_scan"
if [ "$skipped_hidden" -gt 20 ]; then
  printf '...and %d more hidden HEIC files.\n' "$((skipped_hidden - 20))"
fi
if [ "$skipped_hidden" -gt 0 ]; then
  printf 'Skipped %d hidden HEIC file(s); they will not be converted or deleted.\n\n' \
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
    printf 'Preflight failed: HEIC filename has no usable stem: %s\n' "$input" >&2
    preflight_errors=$((preflight_errors + 1))
    continue
  fi

  output_key=$(path_key "$output")
  if [ -z "$output_key" ]; then
    printf 'Preflight failed: could not fingerprint output path: %s\n' "$output" >&2
    preflight_errors=$((preflight_errors + 1))
    continue
  fi
  if [ -e "$planned_outputs_dir/$output_key" ]; then
    printf 'Preflight failed: multiple HEIC files map to the same JPG: %s\n' "$output" >&2
    preflight_errors=$((preflight_errors + 1))
    continue
  fi
  if ! printf '%s\0' "$output" > "$planned_outputs_dir/$output_key"; then
    printf 'Preflight failed: could not record output path: %s\n' "$output" >&2
    preflight_errors=$((preflight_errors + 1))
    continue
  fi

  if [ -e "$output" ] || [ -L "$output" ]; then
    if [ -L "$output" ] || [ ! -f "$output" ]; then
      printf 'Preflight failed: existing JPG target is not a regular file: %s\n' "$output" >&2
      preflight_errors=$((preflight_errors + 1))
    elif [ "$overwrite" -eq 0 ]; then
      printf 'Resume candidate: existing JPG will be validated: %s\n' "$output"
    fi
  fi
done < "$initial_scan"

if [ "$found" -eq 0 ]; then
  printf 'No non-hidden HEIC files were found.\n'
  exit 0
fi
if [ "$preflight_errors" -gt 0 ]; then
  printf 'SAFETY STOP: %d preflight checks failed. No files were converted or deleted.\n' \
    "$preflight_errors" >&2
  exit 1
fi

converted=0
reused=0
failed=0

while IFS= read -r -d '' input; do
  output=${input%.*}.jpg
  output_dir=${output%/*}

  if ! snapshot_file "$input"; then
    printf 'FAILED, original kept: source file was not stable: %s\n' "$input" >&2
    failed=$((failed + 1))
    continue
  fi
  source_stat=$snapshot_stat
  source_hash=$snapshot_hash

  if { [ -e "$output" ] || [ -L "$output" ]; } && [ "$overwrite" -eq 0 ]; then
    if [ -L "$output" ] || [ ! -f "$output" ]; then
      printf 'SKIPPED, original kept: existing JPG is no longer a regular file: %s\n' \
        "$output" >&2
      failed=$((failed + 1))
      continue
    fi

    source_mtime=$(stat -f '%m' "$input" 2>/dev/null)
    output_mtime=$(stat -f '%m' "$output" 2>/dev/null)
    if [ -z "$source_mtime" ] || [ "$source_mtime" != "$output_mtime" ]; then
      printf 'SKIPPED, original kept: existing JPG timestamp does not match the HEIC: %s\n' \
        "$output" >&2
      printf 'Use -f to regenerate and replace this JPG if that is intentional.\n' >&2
      failed=$((failed + 1))
      continue
    fi

    if ! snapshot_file "$output"; then
      printf 'SKIPPED, original kept: existing JPG was not stable: %s\n' "$output" >&2
      failed=$((failed + 1))
      continue
    fi
    existing_output_stat=$snapshot_stat
    existing_output_hash=$snapshot_hash

    printf 'Validate existing JPG: %s -> %s\n' "$input" "$output"
    if ! validate_jpeg "$output"; then
      printf 'SKIPPED, original kept: existing JPG validation failed: %s\n' "$output" >&2
      failed=$((failed + 1))
      continue
    fi
    if ! snapshot_file "$output" || [ "$snapshot_stat" != "$existing_output_stat" ] || \
        [ "$snapshot_hash" != "$existing_output_hash" ]; then
      printf 'SKIPPED, original kept: existing JPG changed during validation: %s\n' \
        "$output" >&2
      failed=$((failed + 1))
      continue
    fi
    if ! snapshot_file "$input" || [ "$snapshot_stat" != "$source_stat" ] || \
        [ "$snapshot_hash" != "$source_hash" ]; then
      printf 'SKIPPED, original kept: source HEIC changed while validating its JPG: %s\n' \
        "$input" >&2
      failed=$((failed + 1))
      continue
    fi
    if ! save_safety_record "$input" "$output" "$source_stat" "$source_hash" \
        "$existing_output_hash"; then
      printf 'SKIPPED, original kept: could not record the existing JPG safely: %s\n' \
        "$output" >&2
      failed=$((failed + 1))
      continue
    fi

    printf 'Resume ready: existing JPG passed validation; review it before deletion.\n'
    reused=$((reused + 1))
    continue
  fi

  if ! conversion_temp_dir=$(mktemp -d "$output_dir/.HEIC2JPG.XXXXXX"); then
    printf 'FAILED, original kept: could not create a temporary folder beside %s\n' "$input" >&2
    failed=$((failed + 1))
    continue
  fi
  conversion_temporary="$conversion_temp_dir/output.jpg"

  printf 'Convert: %s -> %s\n' "$input" "$output"
  conversion_log="$state_dir/sips-convert.log"
  : > "$conversion_log"
  sips -s format jpeg -s formatOptions "$quality" "$input" \
    --out "$conversion_temporary" > "$conversion_log" 2>&1
  conversion_status=$?
  if [ "$conversion_status" -ne 0 ]; then
    printf 'FAILED, original kept: sips could not convert %s (exit %d).\n' \
      "$input" "$conversion_status" >&2
    print_diagnostic_log 'sips conversion output' "$conversion_log"
    printf 'Check that the HEIC is fully downloaded from iCloud and opens in Preview.\n' >&2
    discard_conversion_temp
    failed=$((failed + 1))
    continue
  fi

  if ! validate_jpeg "$conversion_temporary"; then
    printf 'FAILED, original kept: generated JPG validation failed for: %s\n' \
      "$input" >&2
    discard_conversion_temp
    failed=$((failed + 1))
    continue
  fi

  if ! snapshot_file "$input" || [ "$snapshot_stat" != "$source_stat" ] || \
      [ "$snapshot_hash" != "$source_hash" ]; then
    printf 'FAILED, original kept: source HEIC changed during conversion.\n' >&2
    discard_conversion_temp
    failed=$((failed + 1))
    continue
  fi

  source_mode=$(stat -f '%Lp' "$input" 2>/dev/null)
  if [ -n "$source_mode" ]; then
    chmod "$source_mode" "$conversion_temporary" 2>/dev/null || \
      printf 'Permission warning: could not copy source file permissions.\n' >&2
  fi
  touch -r "$input" "$conversion_temporary" 2>/dev/null || \
    printf 'Timestamp warning: could not copy the source timestamp.\n' >&2

  if [ -e "$output" ] || [ -L "$output" ]; then
    if [ "$overwrite" -eq 0 ] || [ -L "$output" ] || [ ! -f "$output" ]; then
      printf 'FAILED, original kept: JPG target changed after preflight: %s\n' "$output" >&2
      discard_conversion_temp
      failed=$((failed + 1))
      continue
    fi
  fi

  if ! mv -f "$conversion_temporary" "$output"; then
    printf 'FAILED, original kept: could not install the generated JPG: %s\n' "$output" >&2
    discard_conversion_temp
    failed=$((failed + 1))
    continue
  fi
  conversion_temporary=''
  rm -rf "$conversion_temp_dir" 2>/dev/null || true
  conversion_temp_dir=''

  output_hash=$(sha256_file "$output")
  if ! save_safety_record "$input" "$output" "$source_stat" "$source_hash" \
      "$output_hash"; then
    printf 'FAILED, original kept: could not save the safety snapshot.\n' >&2
    failed=$((failed + 1))
    continue
  fi

  converted=$((converted + 1))
done < "$initial_scan"

ready=$((converted + reused))
printf '\nConversion finished: %d eligible, %d newly converted, %d existing JPG resumed, %d skipped with issues, %d hidden skipped.\n' \
  "$found" "$converted" "$reused" "$failed" "$skipped_hidden"
printf 'No HEIC originals have been deleted.\n'

if [ "$ready" -eq 0 ]; then
  printf 'No HEIC files are ready for deletion. Files with errors were kept.\n' >&2
  exit 1
fi
if [ "$failed" -gt 0 ]; then
  printf 'Continuing with %d verified file(s). %d HEIC file(s) with issues will be kept.\n' \
    "$ready" "$failed"
fi

printf '\nOpening the selected folders in Finder.\n'
printf 'Manually inspect the JPG files before returning to this window.\n'
finder_errors=0
while IFS= read -r -d '' selected_root; do
  if ! open "$selected_root"; then
    printf 'Finder could not open: %s\n' "$selected_root" >&2
    finder_errors=$((finder_errors + 1))
  fi
done < "$roots_file"
if [ "$finder_errors" -gt 0 ]; then
  printf 'SAFETY STOP: %d selected folder(s) could not be opened. No HEIC files were deleted.\n' \
    "$finder_errors" >&2
  exit 1
fi

printf '\n%d verified HEIC original(s) are ready for deletion; %d issue file(s) will be kept.\n' \
  "$ready" "$failed"
printf 'If every ready JPG looks correct, delete those verified HEIC originals? [y/N]: '
confirmation=''
if ! read_confirmation; then
  printf '\nDeletion cancelled. An interactive confirmation was not received.\n'
  printf 'All HEIC originals were kept.\n'
  exit 0
fi
case "$confirmation" in
  y|Y)
    ;;
  *)
    printf 'Deletion cancelled. All HEIC originals were kept.\n'
    exit 0
    ;;
esac

printf '\nRunning final safety checks before deleting any HEIC files...\n'
predelete_errors=0
current_count=0

if ! scan_selected_roots eligible "$final_scan" "$final_seen_dir"; then
  printf 'Safety check failed: one or more final folder scans were incomplete.\n' >&2
  predelete_errors=$((predelete_errors + 1))
else
  while IFS= read -r -d '' current_heic; do
    current_count=$((current_count + 1))
    current_key=$(path_key "$current_heic")
    if [ -z "$current_key" ] || [ ! -f "$initial_seen_dir/$current_key" ]; then
      printf 'Safety check failed: unexpected HEIC file: %s\n' "$current_heic" >&2
      predelete_errors=$((predelete_errors + 1))
    fi
  done < "$final_scan"
fi

if [ "$current_count" -ne "$found" ]; then
  printf 'Safety check failed: the HEIC file set changed during manual review.\n' >&2
  predelete_errors=$((predelete_errors + 1))
fi

for record_path in "$records_dir"/*; do
  if ! load_record "$record_path"; then
    printf 'Safety check failed: a safety record is unreadable.\n' >&2
    predelete_errors=$((predelete_errors + 1))
    continue
  fi

  if ! snapshot_file "$record_source" || [ "$snapshot_stat" != "$record_source_stat" ] || \
      [ "$snapshot_hash" != "$record_source_hash" ]; then
    printf 'Safety check failed: source HEIC changed: %s\n' "$record_source" >&2
    predelete_errors=$((predelete_errors + 1))
  fi

  current_output_hash=$(sha256_file "$record_output")
  if [ -z "$current_output_hash" ] || [ "$current_output_hash" != "$record_output_hash" ]; then
    printf 'Safety check failed: generated JPG changed: %s\n' "$record_output" >&2
    predelete_errors=$((predelete_errors + 1))
  elif ! validate_jpeg "$record_output"; then
    printf 'Safety check failed: generated JPG is no longer valid: %s\n' "$record_output" >&2
    predelete_errors=$((predelete_errors + 1))
  fi
done

if [ "$predelete_errors" -gt 0 ]; then
  printf 'SAFETY STOP: %d final checks failed. No HEIC files were deleted.\n' \
    "$predelete_errors" >&2
  exit 1
fi

deleted=0
delete_errors=0

for record_path in "$records_dir"/*; do
  if ! load_record "$record_path"; then
    printf 'Could not load a safety record immediately before deletion.\n' >&2
    delete_errors=$((delete_errors + 1))
    continue
  fi

  if ! snapshot_file "$record_source" || [ "$snapshot_stat" != "$record_source_stat" ] || \
      [ "$snapshot_hash" != "$record_source_hash" ]; then
    printf 'Could not delete original because the HEIC changed: %s\n' "$record_source" >&2
    delete_errors=$((delete_errors + 1))
    continue
  fi
  current_output_hash=$(sha256_file "$record_output")
  if [ -z "$current_output_hash" ] || [ "$current_output_hash" != "$record_output_hash" ]; then
    printf 'Could not delete original because the JPG changed: %s\n' "$record_output" >&2
    delete_errors=$((delete_errors + 1))
    continue
  fi

  if rm -f "$record_source" && [ ! -e "$record_source" ]; then
    deleted=$((deleted + 1))
  else
    printf 'Could not delete original: %s\n' "$record_source" >&2
    delete_errors=$((delete_errors + 1))
  fi
done

printf '\nDone: %d JPG files verified, %d HEIC originals deleted, %d issue originals kept, %d deletion errors.\n' \
  "$ready" "$deleted" "$failed" "$delete_errors"

if [ "$delete_errors" -gt 0 ]; then
  exit 1
fi

exit 0
