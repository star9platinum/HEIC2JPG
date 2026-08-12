#!/bin/bash

set -u

test_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)
repo_root=$(cd "$test_dir/../.." 2>/dev/null && pwd -P)
cleaner="$repo_root/src/macos/清理HEIC2JPG临时文件.command"
mockbin="$test_dir/mockbin"
real_path=$PATH
workspace=$(mktemp -d "${TMPDIR:-/tmp}/HEIC2JPG-cleaner-tests.XXXXXX") || exit 1
failures=0

cleanup() {
  rm -rf "$workspace"
}
trap cleanup EXIT

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_exists() {
  if [ -e "$1" ]; then pass "$2"; else fail "$2"; fi
}

assert_missing() {
  if [ ! -e "$1" ]; then pass "$2"; else fail "$2"; fi
}

case_root="$workspace/thorough cleanup"
photo_root="$case_root/photos"
system_temp="$case_root/system-temp"
mkdir -p \
  "$photo_root/sub/.HEIC2JPG.ABC123" \
  "$photo_root/.HEIC2JPG.convert.DEF456" \
  "$photo_root/.HEIC2JPG.validate.GHI789" \
  "$photo_root/.HEIC2JPG.keep" \
  "$photo_root/.HEIC2JPG.convert.TOOLONG7" \
  "$system_temp/HEIC2JPG.JKL012" \
  "$system_temp/HEIC2JPG.state.MNO345" \
  "$system_temp/HEIC2JPG.keep"
printf 'temporary\n' > "$photo_root/sub/.HEIC2JPG.ABC123/output.jpg"
printf 'temporary\n' > "$photo_root/.HEIC2JPG.convert.DEF456/output.jpg"
printf 'temporary\n' > "$photo_root/.HEIC2JPG.validate.GHI789/validation.jpg"
printf 'photo\n' > "$photo_root/keep.HEIC"
printf 'photo\n' > "$photo_root/keep.jpg"

printf 'Y\n' | env \
  PATH="$mockbin:$real_path" \
  TMPDIR="$system_temp/" \
  HEIC2JPG_TEST_MODE=1 \
  bash "$cleaner" "$photo_root" > "$case_root/output.log" 2>&1
status=$?
if [ "$status" -eq 0 ]; then pass 'thorough cleaner succeeds'; else fail "thorough cleaner succeeds (status $status)"; fi
assert_missing "$photo_root/sub/.HEIC2JPG.ABC123" 'legacy photo temp directory is deleted'
assert_missing "$photo_root/.HEIC2JPG.convert.DEF456" 'new conversion temp directory is deleted'
assert_missing "$photo_root/.HEIC2JPG.validate.GHI789" 'validation temp directory is deleted'
assert_missing "$system_temp/HEIC2JPG.JKL012" 'legacy system state directory is deleted'
assert_missing "$system_temp/HEIC2JPG.state.MNO345" 'new system state directory is deleted'
assert_exists "$photo_root/.HEIC2JPG.keep" 'similar photo directory is preserved'
assert_exists "$photo_root/.HEIC2JPG.convert.TOOLONG7" 'temp-like name with wrong suffix length is preserved'
assert_exists "$system_temp/HEIC2JPG.keep" 'similar system directory is preserved'
assert_exists "$photo_root/keep.HEIC" 'HEIC photo is never deleted by cleaner'
assert_exists "$photo_root/keep.jpg" 'JPG photo is never deleted by cleaner'
found_cleaner=0
for cleaner_workspace in "$system_temp"/HEIC2JPG-cleaner.??????; do
  if [ -d "$cleaner_workspace" ]; then
    found_cleaner=1
    break
  fi
done
if [ "$found_cleaner" -eq 1 ]; then
  fail 'cleaner removes its own workspace'
else
  pass 'cleaner removes its own workspace'
fi

cancel_root="$workspace/cancel cleanup"
cancel_temp="$cancel_root/system-temp"
mkdir -p "$cancel_root/photos/.HEIC2JPG.convert.PQR678" "$cancel_temp"
printf 'N\n' | env \
  PATH="$mockbin:$real_path" \
  TMPDIR="$cancel_temp/" \
  HEIC2JPG_TEST_MODE=1 \
  bash "$cleaner" "$cancel_root/photos" > "$cancel_root/output.log" 2>&1
status=$?
if [ "$status" -eq 0 ]; then pass 'cancel is a safe success'; else fail "cancel is a safe success (status $status)"; fi
assert_exists "$cancel_root/photos/.HEIC2JPG.convert.PQR678" 'cancel preserves every candidate'

printf '\n'
if [ "$failures" -gt 0 ]; then
  printf '%d cleaner test(s) failed.\n' "$failures" >&2
  exit 1
fi
printf 'All macOS cleaner tests passed.\n'
exit 0
