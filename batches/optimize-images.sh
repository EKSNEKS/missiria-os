#!/usr/bin/env bash

set -euo pipefail

DEFAULT_SIZE=1024
DEFAULT_QUALITY=82

size="$DEFAULT_SIZE"
quality="$DEFAULT_QUALITY"
source_dir=""
output_dir=""
force=0
dry_run=0

usage() {
  printf '%s\n' \
    'Usage: optimize-images.sh [SOURCE_DIR] [options]' \
    '' \
    'Convert JPG, JPEG, PNG, HEIC, HEIF, TIFF and WebP images to optimized WebP.' \
    'Images keep their aspect ratio and are never enlarged.' \
    '' \
    'Options:' \
    '  --size PIXELS       Maximum width and height (default: 1024)' \
    '  --quality 1-100     WebP quality (default: 82)' \
    '  --output DIRECTORY  Output directory (default: SOURCE_DIR/optimized)' \
    '  --force             Replace existing generated WebP files' \
    '  --dry-run           Show what would be processed without writing files' \
    '  -h, --help          Show this help'
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --size)
      [ "$#" -ge 2 ] || fail '--size requires a value'
      size="$2"
      shift 2
      ;;
    --quality)
      [ "$#" -ge 2 ] || fail '--quality requires a value'
      quality="$2"
      shift 2
      ;;
    --output)
      [ "$#" -ge 2 ] || fail '--output requires a directory'
      output_dir="$2"
      shift 2
      ;;
    --force)
      force=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      fail "unknown option: $1"
      ;;
    *)
      [ -z "$source_dir" ] || fail 'only one source directory may be provided'
      source_dir="$1"
      shift
      ;;
  esac
done

case "$size" in
  ''|*[!0-9]*) fail '--size must be a positive integer' ;;
esac
[ "$size" -gt 0 ] || fail '--size must be greater than zero'

case "$quality" in
  ''|*[!0-9]*) fail '--quality must be an integer from 1 to 100' ;;
esac
[ "$quality" -ge 1 ] && [ "$quality" -le 100 ] || fail '--quality must be between 1 and 100'

command -v magick >/dev/null 2>&1 || fail 'ImageMagick 7 (`magick`) is required'

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
if [ -z "$source_dir" ]; then
  source_dir="$script_dir/GALLERY"
fi

[ -d "$source_dir" ] || fail "source directory not found: $source_dir"
source_dir="$(CDPATH= cd -- "$source_dir" && pwd -P)"

if [ -z "$output_dir" ]; then
  output_dir="$source_dir/optimized"
elif [ "${output_dir#/}" = "$output_dir" ]; then
  output_dir="$PWD/$output_dir"
fi

if [ "$output_dir" = "$source_dir" ]; then
  fail 'output directory must be different from the source directory'
fi

if [ "$dry_run" -eq 0 ]; then
  mkdir -p "$output_dir"
fi

processed=0
skipped=0
failed=0
source_bytes=0
output_bytes=0

file_size() {
  stat -f '%z' "$1" 2>/dev/null || stat -c '%s' "$1"
}

human_size() {
  awk -v bytes="$1" 'BEGIN {
    split("B KB MB GB", units, " ");
    value = bytes + 0;
    unit = 1;
    while (value >= 1024 && unit < 4) { value /= 1024; unit++; }
    if (unit == 1) printf "%d %s", value, units[unit];
    else printf "%.1f %s", value, units[unit];
  }'
}

printf 'Source:  %s\n' "$source_dir"
printf 'Output:  %s\n' "$output_dir"
printf 'Defaults: max %sx%s, WebP quality %s, no upscaling\n' "$size" "$size" "$quality"
[ "$dry_run" -eq 0 ] || printf 'Mode:    dry run (no files will be written)\n'
printf '\n'

while IFS= read -r -d '' source; do
  relative="${source#"$source_dir"/}"
  relative_dir="$(dirname -- "$relative")"
  filename="$(basename -- "$relative")"
  stem="${filename%.*}"

  if [ "$relative_dir" = '.' ]; then
    destination="$output_dir/$stem.webp"
  else
    destination="$output_dir/$relative_dir/$stem.webp"
  fi

  bytes="$(file_size "$source")"
  source_bytes=$((source_bytes + bytes))

  if [ -e "$destination" ] && [ "$force" -eq 0 ]; then
    printf 'SKIP  %s (destination exists)\n' "$relative"
    skipped=$((skipped + 1))
    continue
  fi

  if [ "$dry_run" -eq 1 ]; then
    printf 'WOULD %s -> %s\n' "$relative" "${destination#"$output_dir"/}"
    processed=$((processed + 1))
    continue
  fi

  mkdir -p "$(dirname -- "$destination")"
  temporary="$destination.tmp.webp"

  if magick "$source" \
    -auto-orient \
    -colorspace sRGB \
    -resize "${size}x${size}>" \
    -strip \
    -quality "$quality" \
    -define webp:method=6 \
    "$temporary"; then
    mv -f "$temporary" "$destination"
    generated_bytes="$(file_size "$destination")"
    output_bytes=$((output_bytes + generated_bytes))
    processed=$((processed + 1))
    printf 'OK    %s -> %s (%s)\n' \
      "$relative" \
      "${destination#"$output_dir"/}" \
      "$(human_size "$generated_bytes")"
  else
    rm -f "$temporary"
    failed=$((failed + 1))
    printf 'FAIL  %s\n' "$relative" >&2
  fi
done < <(
  find "$source_dir" \
    -path "$output_dir" -prune -o \
    -type f \( \
      -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o \
      -iname '*.heic' -o -iname '*.heif' -o -iname '*.tif' -o \
      -iname '*.tiff' -o -iname '*.webp' \
    \) -print0
)

if [ "$processed" -eq 0 ] && [ "$skipped" -eq 0 ] && [ "$failed" -eq 0 ]; then
  printf 'No supported images found.\n'
  exit 0
fi

printf '\nSummary\n'
printf '  Processed: %d\n' "$processed"
printf '  Skipped:   %d\n' "$skipped"
printf '  Failed:    %d\n' "$failed"
printf '  Input:     %s\n' "$(human_size "$source_bytes")"
if [ "$dry_run" -eq 0 ]; then
  printf '  Output:    %s\n' "$(human_size "$output_bytes")"
fi

[ "$failed" -eq 0 ] || exit 1
