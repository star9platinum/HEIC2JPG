#!/bin/bash

# Copyright (c) 2026 Owen Pu. Licensed under the MIT License.
# Recursively convert HEIC images to JPG using macOS's built-in `sips`.
# JPG files are created beside their source files. A source HEIC is deleted only
# after its JPG has been created successfully.

set -u

overwrite=0
quality=90

usage() {
  cat <<'EOF'
Usage: heic_to_jpg.sh [-f] [-q quality] [directory]

Options:
  -f          Overwrite existing JPG files (default: skip them)
  -q quality  JPEG quality from 1 to 100 (default: 90)
  -h          Show this help

If directory is omitted, the current directory is used.
Successfully converted HEIC files are deleted.
EOF
}

while getopts ":fq:h" option; do
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

root=${1:-.}

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

if [ ! -d "$root" ]; then
  printf 'Error: directory does not exist: %s\n' "$root" >&2
  exit 2
fi

if ! command -v sips >/dev/null 2>&1; then
  printf 'Error: sips was not found. This script must be run on macOS.\n' >&2
  exit 1
fi

converted=0
deleted=0
skipped=0
failed=0
found=0

while IFS= read -r -d '' input; do
  found=$((found + 1))
  output=${input%.*}.jpg

  if [ -e "$output" ] && [ "$overwrite" -eq 0 ]; then
    printf 'Skip (already exists): %s\n' "$output"
    skipped=$((skipped + 1))
    continue
  fi

  # Convert to a temporary file first so a failed conversion cannot damage an
  # existing JPG when -f is used.
  temporary="${output%.*}.heic-to-jpg-tmp-$$.jpg"
  rm -f "$temporary"

  printf 'Convert: %s -> %s\n' "$input" "$output"
  if sips -s format jpeg -s formatOptions "$quality" "$input" --out "$temporary" >/dev/null \
      && mv -f "$temporary" "$output"; then
    converted=$((converted + 1))
    if rm -f "$input"; then
      deleted=$((deleted + 1))
    else
      printf 'Converted, but could not delete original: %s\n' "$input" >&2
      failed=$((failed + 1))
    fi
  else
    printf 'Failed: %s\n' "$input" >&2
    rm -f "$temporary"
    failed=$((failed + 1))
  fi
done < <(find "$root" -type f -name '*.[Hh][Ee][Ii][Cc]' -print0)

if [ "$found" -eq 0 ]; then
  printf 'No HEIC files found under: %s\n' "$root"
else
  printf '\nDone: %d converted, %d originals deleted, %d skipped, %d errors.\n' \
    "$converted" "$deleted" "$skipped" "$failed"
fi

if [ "$failed" -gt 0 ]; then
  exit 1
fi
