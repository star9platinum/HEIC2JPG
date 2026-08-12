#!/bin/bash

set -u

test_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)
repo_root=$(cd "$test_dir/../.." 2>/dev/null && pwd -P)
converter="$repo_root/src/macos/一键转换HEIC.command"
one_click=$converter
mockbin="$test_dir/mockbin"
real_path=$PATH
workspace=$(mktemp -d "${TMPDIR:-/tmp}/HEIC2JPG-tests.XXXXXX") || exit 1
failures=0
last_status=0

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

assert_status() {
  if [ "$last_status" -eq "$1" ]; then pass "$2"; else fail "$2 (status $last_status)"; fi
}

assert_nonzero_status() {
  if [ "$last_status" -ne 0 ]; then pass "$1"; else fail "$1"; fi
}

assert_log_contains() {
  if grep -Fq "$1" "$output_log"; then pass "$2"; else fail "$2"; fi
}

assert_call_log_contains() {
  if grep -Fq "$1" "$call_log"; then pass "$2"; else fail "$2"; fi
}

assert_no_photo_temp() {
  found_temp=$(find "$1" -name '.HEIC2JPG.*' -print -quit)
  if [ -z "$found_temp" ]; then pass "$2"; else fail "$2 ($found_temp)"; fi
}

hash_file() {
  PATH="$mockbin:$real_path" shasum -a 256 < "$1" | awk '{print $1}'
}

new_case() {
  case_root="$workspace/$1"
  mkdir -p "$case_root"
  call_log="$case_root/calls.log"
  output_log="$case_root/output.log"
  xattr_store="$case_root/xattrs"
  : > "$call_log"
  mkdir -p "$xattr_store"
}

run_core() {
  confirmation=$1
  target=$2
  action=${3:-none}
  fail_match=${4:-__never_match__}
  invalid_match=${5:-__never_match__}
  mutate_match=${6:-__never_match__}
  shift 6

  printf '%s\n' "$confirmation" | env \
    PATH="$mockbin:$real_path" \
    HEIC2JPG_TEST_MODE=1 \
    HEIC2JPG_TEST_CALL_LOG="$call_log" \
    HEIC2JPG_TEST_XATTR_STORE="$xattr_store" \
    HEIC2JPG_TEST_PHOTO_ROOT="$target" \
    HEIC2JPG_TEST_OPEN_ACTION="$action" \
    HEIC2JPG_SIPS_FAIL_MATCH="$fail_match" \
    HEIC2JPG_SIPS_INVALID_MATCH="$invalid_match" \
    HEIC2JPG_SIPS_MUTATE_MATCH="$mutate_match" \
    bash "$converter" "$@" "$target" > "$output_log" 2>&1
  last_status=$?
}

new_case 'success 中文 & spaces'
mkdir -p "$case_root/photos/sub folder"
printf 'one\n' > "$case_root/photos/first.HEIC"
printf 'two\n' > "$case_root/photos/sub folder/第二张.heic"
run_core 'y' "$case_root/photos" none __never_match__ __never_match__ __never_match__ -f
assert_status 0 'lowercase y confirmation succeeds'
assert_missing "$case_root/photos/first.HEIC" 'first HEIC deleted after confirmation'
assert_missing "$case_root/photos/sub folder/第二张.heic" 'nested HEIC deleted after confirmation'
assert_exists "$case_root/photos/first.jpg" 'first JPG created'
assert_exists "$case_root/photos/sub folder/第二张.jpg" 'nested JPG created'
assert_call_log_contains 'validation-location-ok' 'validation JPGs stay on the photo volume one at a time'
if grep -q '^content-sha256:' "$call_log"; then fail 'default lightweight mode performs no photo content hashing'; else pass 'default lightweight mode performs no photo content hashing'; fi
sips_count=$(grep -c '^sips$' "$call_log")
if [ "$sips_count" -eq 6 ]; then pass 'default mode decodes each newly generated JPG only once'; else fail "default mode decodes each newly generated JPG only once (sips calls $sips_count)"; fi
assert_no_photo_temp "$case_root/photos" 'success leaves no photo temporary files'

new_case 'hidden HEIC files are skipped'
mkdir -p "$case_root/photos"
printf 'normal\n' > "$case_root/photos/normal.HEIC"
printf 'dot only\n' > "$case_root/photos/.HEIC"
printf 'appledouble\n' > "$case_root/photos/._IMG_0001.HEIC"
run_core 'Y' "$case_root/photos" none __never_match__ __never_match__ __never_match__ -f
assert_status 0 'hidden HEIC files do not fail the batch'
assert_missing "$case_root/photos/normal.HEIC" 'eligible HEIC is still deleted after confirmation'
assert_exists "$case_root/photos/normal.jpg" 'eligible HEIC is still converted'
assert_exists "$case_root/photos/.HEIC" 'dot-only HEIC is kept unchanged'
assert_exists "$case_root/photos/._IMG_0001.HEIC" 'AppleDouble-style HEIC is kept unchanged'
assert_missing "$case_root/photos/.jpg" 'dot-only HEIC produces no JPG'
assert_missing "$case_root/photos/._IMG_0001.jpg" 'AppleDouble-style HEIC produces no JPG'
assert_log_contains '已跳过 2 个隐藏 HEIC 文件' 'hidden HEIC skip count is reported'
assert_log_contains '跳过隐藏 HEIC（保持不变）' 'hidden HEIC paths are reported'

new_case 'cancel confirmation'
mkdir -p "$case_root/photos"
printf 'keep\n' > "$case_root/photos/keep.HEIC"
run_core 'yes' "$case_root/photos" none __never_match__ __never_match__ __never_match__ -f
assert_status 0 'input other than y or Y cancels safely'
assert_exists "$case_root/photos/keep.HEIC" 'cancel keeps HEIC'
assert_exists "$case_root/photos/keep.jpg" 'cancel may keep reviewed JPG'

new_case 'conversion failure'
mkdir -p "$case_root/photos"
printf 'good\n' > "$case_root/photos/good.HEIC"
printf 'bad\n' > "$case_root/photos/fail.HEIC"
run_core 'y' "$case_root/photos" none fail.HEIC __never_match__ __never_match__ -f
assert_status 0 'one corrupt HEIC does not stop the remaining batch'
assert_missing "$case_root/photos/good.HEIC" 'confirmed successful source is deleted'
assert_exists "$case_root/photos/good.jpg" 'good HEIC is converted despite another failure'
assert_exists "$case_root/photos/fail.HEIC" 'corrupt HEIC is kept'
assert_missing "$case_root/photos/fail.jpg" 'corrupt HEIC produces no published JPG'
if grep -q '^open$' "$call_log"; then pass 'partial success reaches review phase'; else fail 'partial success reaches review phase'; fi
assert_log_contains 'sips 无法转换' 'conversion failure reports a specific conversion error'
assert_log_contains '退出码 1' 'conversion failure reports sips exit status'
assert_log_contains 'mock decoder rejected the input' 'conversion failure preserves original sips diagnostic'
assert_log_contains 'fail.HEIC' 'conversion failure identifies the source file'
assert_no_photo_temp "$case_root/photos" 'conversion failure cleans photo temporary files'

new_case 'invalid generated jpeg'
mkdir -p "$case_root/photos"
printf 'bad image\n' > "$case_root/photos/invalid.HEIC"
run_core 'y' "$case_root/photos" none __never_match__ invalid.HEIC __never_match__ -f
assert_nonzero_status 'invalid generated JPG fails validation'
assert_exists "$case_root/photos/invalid.HEIC" 'invalid generated JPG keeps HEIC'
assert_missing "$case_root/photos/invalid.jpg" 'invalid generated JPG is not published'

new_case 'source changes during conversion'
mkdir -p "$case_root/photos"
printf 'old jpg\n' > "$case_root/photos/mutate.jpg"
old_jpg_hash=$(hash_file "$case_root/photos/mutate.jpg")
printf 'source\n' > "$case_root/photos/mutate.HEIC"
run_core 'y' "$case_root/photos" none __never_match__ __never_match__ mutate.HEIC -f
assert_nonzero_status 'source mutation during conversion fails the batch'
assert_exists "$case_root/photos/mutate.HEIC" 'source mutation keeps HEIC'
new_jpg_hash=$(hash_file "$case_root/photos/mutate.jpg")
if [ "$old_jpg_hash" = "$new_jpg_hash" ]; then pass 'source mutation preserves old JPG'; else fail 'source mutation preserves old JPG'; fi

new_case 'jpg changes during review'
mkdir -p "$case_root/photos"
printf 'review\n' > "$case_root/photos/review.HEIC"
run_core 'y' "$case_root/photos" corrupt_jpg __never_match__ __never_match__ __never_match__ -f -s
assert_nonzero_status 'changed JPG fails final review checks'
assert_exists "$case_root/photos/review.HEIC" 'changed JPG keeps HEIC'

new_case 'HEIC set changes during review'
mkdir -p "$case_root/photos"
printf 'review\n' > "$case_root/photos/review.HEIC"
run_core 'y' "$case_root/photos" add_heic __never_match__ __never_match__ __never_match__ -f -s
assert_nonzero_status 'new HEIC fails final set check'
assert_exists "$case_root/photos/review.HEIC" 'new HEIC keeps original source'
assert_exists "$case_root/photos/added-during-review.HEIC" 'new HEIC is never deleted'

new_case 'lightweight mode does not rescan HEIC set'
mkdir -p "$case_root/photos"
printf 'review\n' > "$case_root/photos/review.HEIC"
run_core 'y' "$case_root/photos" add_heic __never_match__ __never_match__ __never_match__ -f
assert_status 0 'new HEIC does not stop lightweight deletion'
assert_missing "$case_root/photos/review.HEIC" 'lightweight mode deletes the confirmed original'
assert_exists "$case_root/photos/added-during-review.HEIC" 'lightweight mode never deletes an unrecorded HEIC'

new_case 'unrelated review change'
mkdir -p "$case_root/photos"
printf 'review\n' > "$case_root/photos/review.HEIC"
run_core 'y' "$case_root/photos" add_non_heic __never_match__ __never_match__ __never_match__ -f -s
assert_status 0 'unrelated non-HEIC file does not cause false safety stop'
assert_missing "$case_root/photos/review.HEIC" 'control case deletes confirmed HEIC'

new_case 'resume matching existing target'
mkdir -p "$case_root/photos"
printf 'source\n' > "$case_root/photos/existing.HEIC"
run_core 'n' "$case_root/photos" none __never_match__ __never_match__ __never_match__ -f -s
assert_status 0 'cancelled deletion leaves a fingerprinted JPG for resume'
assert_exists "$case_root/photos/existing.HEIC" 'cancelled first run keeps the HEIC'
old_jpg_hash=$(hash_file "$case_root/photos/existing.jpg")
run_core 'y' "$case_root/photos" none __never_match__ __never_match__ __never_match__ -s
assert_status 0 'matching source and JPG fingerprints resume safely without -f'
assert_missing "$case_root/photos/existing.HEIC" 'resumed HEIC is deleted after review confirmation'
new_jpg_hash=$(hash_file "$case_root/photos/existing.jpg")
if [ "$old_jpg_hash" = "$new_jpg_hash" ]; then pass 'resume preserves existing JPG bytes'; else fail 'resume preserves existing JPG bytes'; fi
assert_log_contains '断点续传成功：来源和 JPG 的 SHA-256 指纹一致' 'strict resume decision is reported'

new_case 'default lightweight resume'
mkdir -p "$case_root/photos"
printf 'source that was not used for this jpeg\n' > "$case_root/photos/compat.HEIC"
printf 'MOCK_JPEG\nunrelated but decodable output\n' > "$case_root/photos/compat.jpg"
run_core 'y' "$case_root/photos" none __never_match__ __never_match__ __never_match__
assert_status 0 'decode-only lightweight resume is the default'
assert_missing "$case_root/photos/compat.HEIC" 'lightweight resume reaches deletion only after final confirmation'
assert_exists "$case_root/photos/compat.jpg" 'lightweight resume preserves the decodable JPG'
assert_log_contains '当前模式：默认轻量' 'lightweight default is reported'
assert_log_contains '未核验它是否由旁边的 HEIC 转换而来' 'lightweight resume reports skipped provenance check'
if find "$xattr_store" -type f -print -quit | grep -q .; then
  fail 'lightweight resume must not write persistent fingerprints'
else
  pass 'lightweight resume does not write persistent fingerprints'
fi
if grep -q '^content-sha256:' "$call_log"; then fail 'lightweight resume performs no photo content hashing'; else pass 'lightweight resume performs no photo content hashing'; fi

new_case 'invalid existing target is skipped'
mkdir -p "$case_root/photos"
printf 'unverified source\n' > "$case_root/photos/unverified.HEIC"
printf 'NOT_A_JPEG\n' > "$case_root/photos/unverified.jpg"
touch -r "$case_root/photos/unverified.HEIC" "$case_root/photos/unverified.jpg"
printf 'good\n' > "$case_root/photos/good.HEIC"
old_jpg_hash=$(hash_file "$case_root/photos/unverified.jpg")
run_core 'Y' "$case_root/photos" none __never_match__ __never_match__ __never_match__
assert_status 0 'invalid existing JPG does not stop other conversions'
assert_exists "$case_root/photos/unverified.HEIC" 'HEIC with invalid existing JPG is kept'
new_jpg_hash=$(hash_file "$case_root/photos/unverified.jpg")
if [ "$old_jpg_hash" = "$new_jpg_hash" ]; then pass 'invalid existing JPG is preserved'; else fail 'invalid existing JPG is preserved'; fi
assert_missing "$case_root/photos/good.HEIC" 'other successful HEIC is deleted after confirmation'
assert_exists "$case_root/photos/good.jpg" 'other HEIC converts despite invalid existing JPG'
assert_log_contains '已有 JPG 验证失败' 'invalid existing JPG reason is reported'

new_case 'existing target without receipt resumes by default'
mkdir -p "$case_root/photos"
printf 'source\n' > "$case_root/photos/mismatch.HEIC"
printf 'MOCK_JPEG\nunrelated output\n' > "$case_root/photos/mismatch.jpg"
touch -t 202001010101 "$case_root/photos/mismatch.HEIC"
touch -t 202101010101 "$case_root/photos/mismatch.jpg"
printf 'good\n' > "$case_root/photos/good.HEIC"
run_core 'y' "$case_root/photos" none __never_match__ __never_match__ __never_match__
assert_status 0 'unfingerprinted decodable JPG resumes in default mode'
assert_missing "$case_root/photos/mismatch.HEIC" 'default mode deletes confirmed HEIC with decodable same-name JPG'
assert_exists "$case_root/photos/mismatch.jpg" 'unfingerprinted JPG is preserved'
assert_missing "$case_root/photos/good.HEIC" 'verified file still completes in mismatch batch'
assert_log_contains '轻量续传成功' 'default resume decision is reported'

new_case 'same-name JPG removed before lightweight deletion'
mkdir -p "$case_root/photos"
printf 'review\n' > "$case_root/photos/review.HEIC"
run_core 'y' "$case_root/photos" remove_jpg __never_match__ __never_match__ __never_match__ -f
assert_nonzero_status 'missing JPG prevents lightweight deletion'
assert_exists "$case_root/photos/review.HEIC" 'missing same-name JPG keeps HEIC'
assert_log_contains '同名 JPG 不存在或不是非空普通文件' 'missing JPG reason is reported'

new_case 'same-name JPG emptied before lightweight deletion'
mkdir -p "$case_root/photos"
printf 'review\n' > "$case_root/photos/review.HEIC"
run_core 'y' "$case_root/photos" empty_jpg __never_match__ __never_match__ __never_match__ -f
assert_nonzero_status 'empty JPG prevents lightweight deletion'
assert_exists "$case_root/photos/review.HEIC" 'empty same-name JPG keeps HEIC'

new_case 'same-name JPG becomes directory before lightweight deletion'
mkdir -p "$case_root/photos"
printf 'review\n' > "$case_root/photos/review.HEIC"
run_core 'y' "$case_root/photos" jpg_becomes_directory __never_match__ __never_match__ __never_match__ -f
assert_nonzero_status 'JPG path becoming a directory prevents lightweight deletion'
assert_exists "$case_root/photos/review.HEIC" 'directory at JPG path keeps HEIC'

new_case 'folder picker'
mkdir -p "$case_root/photos"
printf 'picker\n' > "$case_root/photos/picker.HEIC"
printf 'KEEP\n' | env \
  PATH="$mockbin:$real_path" \
  HEIC2JPG_TEST_MODE=1 \
  HEIC2JPG_TEST_CALL_LOG="$call_log" \
  HEIC2JPG_TEST_XATTR_STORE="$xattr_store" \
  HEIC2JPG_PICKER_PATH="$case_root/photos" \
  HEIC2JPG_TEST_OPEN_ACTION=none \
  bash "$converter" -f > "$output_log" 2>&1
last_status=$?
assert_status 0 'folder picker path is accepted'
assert_exists "$case_root/photos/picker.HEIC" 'picker plus cancelled deletion keeps HEIC'
assert_exists "$case_root/photos/picker.jpg" 'picker-selected HEIC is converted'
if grep -q '^osascript$' "$call_log"; then pass 'folder picker invokes osascript'; else fail 'folder picker invokes osascript'; fi

new_case 'multiple picker folders'
mkdir -p "$case_root/first photos" "$case_root/second photos"
printf 'first\n' > "$case_root/first photos/first.HEIC"
printf 'second\n' > "$case_root/second photos/second.HEIC"
picker_paths=$(printf '%s\n%s' "$case_root/first photos" "$case_root/second photos")
printf 'Y\n' | env \
  PATH="$mockbin:$real_path" \
  HEIC2JPG_TEST_MODE=1 \
  HEIC2JPG_TEST_CALL_LOG="$call_log" \
  HEIC2JPG_TEST_XATTR_STORE="$xattr_store" \
  HEIC2JPG_PICKER_PATHS="$picker_paths" \
  HEIC2JPG_TEST_OPEN_ACTION=none \
  bash "$converter" -f > "$output_log" 2>&1
last_status=$?
assert_status 0 'folder picker accepts multiple folders'
assert_missing "$case_root/first photos/first.HEIC" 'first picker folder source is deleted after Y'
assert_missing "$case_root/second photos/second.HEIC" 'second picker folder source is deleted after Y'
assert_exists "$case_root/first photos/first.jpg" 'first picker folder is converted'
assert_exists "$case_root/second photos/second.jpg" 'second picker folder is converted'
open_count=$(grep -c '^open$' "$call_log")
if [ "$open_count" -eq 2 ]; then pass 'Finder opens every picker-selected folder'; else fail "Finder opens every picker-selected folder (opened $open_count)"; fi

new_case 'multiple command-line folders with overlap'
mkdir -p "$case_root/photos/sub folder" "$case_root/other photos"
printf 'nested\n' > "$case_root/photos/sub folder/nested.HEIC"
printf 'other\n' > "$case_root/other photos/other.HEIC"
printf 'y\n' | env \
  PATH="$mockbin:$real_path" \
  HEIC2JPG_TEST_MODE=1 \
  HEIC2JPG_TEST_CALL_LOG="$call_log" \
  HEIC2JPG_TEST_XATTR_STORE="$xattr_store" \
  HEIC2JPG_TEST_OPEN_ACTION=none \
  bash "$converter" -f "$case_root/photos" "$case_root/photos/sub folder" \
    "$case_root/other photos" > "$output_log" 2>&1
last_status=$?
assert_status 0 'command line accepts multiple and overlapping folders'
assert_missing "$case_root/photos/sub folder/nested.HEIC" 'overlapping folder source is deleted once'
assert_exists "$case_root/photos/sub folder/nested.jpg" 'overlapping folder source is converted once'
assert_missing "$case_root/other photos/other.HEIC" 'additional command-line folder source is deleted'
assert_exists "$case_root/other photos/other.jpg" 'additional command-line folder is converted'
assert_log_contains '共 2 个可处理文件，新转换 2 个' 'overlapping selections are deduplicated'

new_case 'folder picker cancel'
printf 'unused\n' | env \
  PATH="$mockbin:$real_path" \
  HEIC2JPG_TEST_MODE=1 \
  HEIC2JPG_TEST_CALL_LOG="$call_log" \
  HEIC2JPG_PICKER_CANCEL=1 \
  bash "$converter" > "$output_log" 2>&1
last_status=$?
assert_status 0 'folder picker cancellation is a safe success'
if grep -Eq '^(sips|open)$' "$call_log"; then fail 'picker cancellation performs no conversion or review'; else pass 'picker cancellation performs zero photo operations'; fi

new_case 'single-file one click'
mkdir -p "$case_root/photos"
printf 'wrapper\n' > "$case_root/photos/wrapper.HEIC"
printf 'Y\n' | env \
  PATH="$mockbin:$real_path" \
  HEIC2JPG_TEST_MODE=1 \
  HEIC2JPG_TEST_CALL_LOG="$call_log" \
  HEIC2JPG_TEST_XATTR_STORE="$xattr_store" \
  HEIC2JPG_PICKER_PATH="$case_root/photos" \
  HEIC2JPG_TEST_OPEN_ACTION=none \
  bash "$one_click" > "$output_log" 2>&1
last_status=$?
assert_status 0 'single Finder file accepts uppercase Y confirmation'
assert_missing "$case_root/photos/wrapper.HEIC" 'single Finder file deletes only after confirmation'
assert_exists "$case_root/photos/wrapper.jpg" 'single Finder file creates JPG'

new_case 'duplicate output preflight'
mkdir -p "$case_root/photos"
printf 'upper\n' > "$case_root/photos/same.HEIC"
printf 'lower\n' > "$case_root/photos/same.heic"
heic_count=$(find "$case_root/photos" -type f -name '*.[Hh][Ee][Ii][Cc]' | wc -l | tr -d ' ')
if [ "$heic_count" -eq 2 ]; then
  run_core 'y' "$case_root/photos" none __never_match__ __never_match__ __never_match__ -f
  assert_nonzero_status 'duplicate output mapping fails preflight'
  assert_missing "$case_root/photos/same.jpg" 'duplicate output mapping converts nothing'
  if grep -q '^sips$' "$call_log"; then fail 'duplicate output preflight must not call sips'; else pass 'duplicate output preflight performs zero conversions'; fi
else
  pass 'duplicate output test skipped on case-insensitive filesystem'
fi

printf '\n'
if [ "$failures" -gt 0 ]; then
  printf '%d macOS logic test(s) failed.\n' "$failures" >&2
  exit 1
fi

printf 'All macOS logic tests passed.\n'
exit 0
