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
Usage: 一键转换HEIC.command [-f] [-q quality] [directory]

Options:
  -f          Replace existing regular same-name JPG files
  -q quality  JPEG quality from 1 to 100 (default: 90)
  -h          Show this help

If directory is omitted, a macOS folder picker is shown.
All subfolders are included. HEIC originals are kept during conversion and
manual review. They are deleted only after the exact confirmation phrase
DELETE ALL HEIC is entered and every final safety check passes.
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

select_photo_folder() {
  if ! command -v osascript >/dev/null 2>&1; then
    printf 'Error: osascript was not found. Specify a directory on the command line.\n' >&2
    return 1
  fi

  osascript <<'APPLESCRIPT'
try
  set selectedFolder to choose folder with prompt "选择包含 HEIC 照片的根文件夹"
  return POSIX path of selectedFolder
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

if [ "$#" -gt 1 ]; then
  printf 'Error: only one directory may be specified.\n' >&2
  usage >&2
  exit 2
fi

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

if [ "$#" -eq 1 ]; then
  root=$1
else
  printf 'Choose the photo folder in the macOS dialog...\n'
  if ! root=$(select_photo_folder); then
    exit 1
  fi
  if [ -z "$root" ]; then
    printf 'Cancelled. No photos were changed.\n'
    exit 0
  fi
fi

case "$root" in
  *$'\n'*|*$'\r'*)
    printf 'Error: the selected root path contains a line break, which is not supported.\n' >&2
    exit 2
    ;;
esac

if [ ! -d "$root" ]; then
  printf 'Error: directory does not exist: %s\n' "$root" >&2
  exit 2
fi
if ! root=$(cd "$root" 2>/dev/null && pwd -P); then
  printf 'Error: directory could not be opened: %s\n' "$root" >&2
  exit 2
fi

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
initial_scan="$state_dir/initial-heic-list"
final_scan="$state_dir/final-heic-list"
if ! mkdir "$records_dir" "$planned_outputs_dir"; then
  printf 'Error: could not initialize the safety workspace.\n' >&2
  exit 1
fi

printf '\nHEIC -> JPG for macOS\n'
printf 'Folder: %s\n' "$root"
if command -v sw_vers >/dev/null 2>&1; then
  printf 'macOS: %s\n' "$(sw_vers -productVersion 2>/dev/null)"
fi
printf 'Image converter: %s\n' "$(command -v sips)"
printf 'Subfolders are included.\n'
printf 'All HEIC originals stay in place during conversion and manual review.\n\n'

if ! find "$root" -type f -name '*.[Hh][Ee][Ii][Cc]' -print0 > "$initial_scan"; then
  printf 'SAFETY STOP: The folder scan was incomplete. No files were changed.\n' >&2
  exit 1
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
    if [ "$overwrite" -eq 0 ]; then
      printf 'Preflight conflict: JPG already exists: %s\n' "$output" >&2
      preflight_errors=$((preflight_errors + 1))
    elif [ -L "$output" ] || [ ! -f "$output" ]; then
      printf 'Preflight failed: existing JPG target is not a regular file: %s\n' "$output" >&2
      preflight_errors=$((preflight_errors + 1))
    fi
  fi
done < "$initial_scan"

if [ "$found" -eq 0 ]; then
  printf 'No HEIC files were found.\n'
  exit 0
fi
if [ "$preflight_errors" -gt 0 ]; then
  printf 'SAFETY STOP: %d preflight checks failed. No files were converted or deleted.\n' \
    "$preflight_errors" >&2
  if [ "$overwrite" -eq 0 ]; then
    printf 'Use -f only if you intentionally want to replace existing regular JPG files.\n' >&2
  fi
  exit 1
fi

converted=0
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
  source_key=$(path_key "$input")
  if [ -z "$output_hash" ] || [ -z "$source_key" ] || [ -e "$records_dir/$source_key" ]; then
    printf 'FAILED, original kept: could not record the safety snapshot.\n' >&2
    failed=$((failed + 1))
    continue
  fi

  if ! printf '%s\0%s\0%s\0%s\0%s\0' \
      "$input" "$output" "$source_stat" "$source_hash" "$output_hash" \
      > "$records_dir/$source_key"; then
    printf 'FAILED, original kept: could not save the safety snapshot.\n' >&2
    rm -f "$records_dir/$source_key" 2>/dev/null || true
    failed=$((failed + 1))
    continue
  fi

  converted=$((converted + 1))
done < "$initial_scan"

printf '\nConversion finished: %d found, %d converted and validated, %d errors.\n' \
  "$found" "$converted" "$failed"
printf 'No HEIC originals have been deleted.\n'

if [ "$failed" -gt 0 ] || [ "$converted" -ne "$found" ]; then
  printf 'SAFETY STOP: Not every HEIC file was converted. All HEIC originals were kept.\n' >&2
  exit 1
fi

printf '\nOpening the selected folder in Finder.\n'
printf 'Manually inspect the JPG files before returning to this window.\n'
if ! open "$root"; then
  printf 'SAFETY STOP: Finder could not be opened. No HEIC files were deleted.\n' >&2
  exit 1
fi

printf '\nIf every JPG looks correct, type this exact phrase:\n'
printf 'DELETE ALL HEIC\n'
printf 'Confirmation: '
confirmation=''
if ! read_confirmation; then
  printf '\nDeletion cancelled. An interactive confirmation was not received.\n'
  printf 'All HEIC originals were kept.\n'
  exit 0
fi
if [ "$confirmation" != 'DELETE ALL HEIC' ]; then
  printf 'Deletion cancelled. All HEIC originals were kept.\n'
  exit 0
fi

printf '\nRunning final safety checks before deleting any HEIC files...\n'
predelete_errors=0
current_count=0

if ! find "$root" -type f -name '*.[Hh][Ee][Ii][Cc]' -print0 > "$final_scan"; then
  printf 'Safety check failed: the final folder scan was incomplete.\n' >&2
  predelete_errors=$((predelete_errors + 1))
else
  while IFS= read -r -d '' current_heic; do
    current_count=$((current_count + 1))
    current_key=$(path_key "$current_heic")
    if [ -z "$current_key" ] || [ ! -f "$records_dir/$current_key" ]; then
      printf 'Safety check failed: unexpected HEIC file: %s\n' "$current_heic" >&2
      predelete_errors=$((predelete_errors + 1))
    fi
  done < "$final_scan"
fi

if [ "$current_count" -ne "$converted" ]; then
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

printf '\nDone: %d JPG files verified, %d HEIC originals deleted, %d deletion errors.\n' \
  "$converted" "$deleted" "$delete_errors"

if [ "$delete_errors" -gt 0 ]; then
  exit 1
fi

exit 0
