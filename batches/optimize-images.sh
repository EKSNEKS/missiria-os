#!/usr/bin/env bash

set -euo pipefail

DEFAULT_SIZE=1024
DEFAULT_QUALITY=82
DEFAULT_WATERMARK_OPACITY=85
DEFAULT_WATERMARK_MARGIN=24
DEFAULT_WATERMARK_LOGO_SIZE=140
DEFAULT_WATERMARK_FONT='DejaVu-Sans'
DEFAULT_WATERMARK_FONT_SIZE=24
MAX_REMOTE_LOGO_BYTES=10485760

size="$DEFAULT_SIZE"
quality="$DEFAULT_QUALITY"
source_dir=""
output_dir=""
force=0
dry_run=0
watermark_logo=""
watermark_text=""
watermark_position='bottom-right'
watermark_opacity="$DEFAULT_WATERMARK_OPACITY"
watermark_margin="$DEFAULT_WATERMARK_MARGIN"
watermark_logo_size="$DEFAULT_WATERMARK_LOGO_SIZE"
watermark_font="$DEFAULT_WATERMARK_FONT"
watermark_font_explicit=0
watermark_font_size="$DEFAULT_WATERMARK_FONT_SIZE"
watermark_enabled=0
watermark_logo_file=""
runtime_tmp=""

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
    '  --watermark-logo PATH_OR_URL' \
    '                      Local image or HTTPS logo URL' \
    '  --watermark-text TEXT' \
    '                      Text displayed beside the logo' \
    '  --watermark-position POSITION' \
    '                      bottom-right, bottom-left, top-right, top-left or center' \
    '  --watermark-opacity 1-100  Watermark opacity (default: 85)' \
    '  --watermark-margin PIXELS  Edge margin (default: 24)' \
    '  --watermark-logo-size PIXELS' \
    '                      Maximum logo width/height (default: 140)' \
    '  --watermark-font FONT' \
    '                      ImageMagick font name or font path (default: DejaVu-Sans)' \
    '  --watermark-font-size PIXELS' \
    '                      Website text size (default: 24)' \
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
    --watermark-logo)
      [ "$#" -ge 2 ] || fail '--watermark-logo requires a local path or HTTPS URL'
      watermark_logo="$2"
      shift 2
      ;;
    --watermark-text)
      [ "$#" -ge 2 ] || fail '--watermark-text requires a value'
      watermark_text="$2"
      shift 2
      ;;
    --watermark-position)
      [ "$#" -ge 2 ] || fail '--watermark-position requires a value'
      watermark_position="$2"
      shift 2
      ;;
    --watermark-opacity)
      [ "$#" -ge 2 ] || fail '--watermark-opacity requires a value'
      watermark_opacity="$2"
      shift 2
      ;;
    --watermark-margin)
      [ "$#" -ge 2 ] || fail '--watermark-margin requires a value'
      watermark_margin="$2"
      shift 2
      ;;
    --watermark-logo-size)
      [ "$#" -ge 2 ] || fail '--watermark-logo-size requires a value'
      watermark_logo_size="$2"
      shift 2
      ;;
    --watermark-font)
      [ "$#" -ge 2 ] || fail '--watermark-font requires a font name or path'
      watermark_font="$2"
      watermark_font_explicit=1
      shift 2
      ;;
    --watermark-font-size)
      [ "$#" -ge 2 ] || fail '--watermark-font-size requires a value'
      watermark_font_size="$2"
      shift 2
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

validate_integer() {
  value="$1"
  option="$2"
  minimum="$3"
  maximum="$4"

  case "$value" in
    ''|*[!0-9]*) fail "$option must be an integer from $minimum to $maximum" ;;
  esac
  [ "$value" -ge "$minimum" ] && [ "$value" -le "$maximum" ] || \
    fail "$option must be between $minimum and $maximum"
}

validate_integer "$watermark_opacity" '--watermark-opacity' 1 100
validate_integer "$watermark_margin" '--watermark-margin' 0 10000
validate_integer "$watermark_logo_size" '--watermark-logo-size' 1 10000
validate_integer "$watermark_font_size" '--watermark-font-size' 1 1000

case "$watermark_position" in
  bottom-right|bottom-left|top-right|top-left|center) ;;
  *) fail '--watermark-position must be bottom-right, bottom-left, top-right, top-left or center' ;;
esac

if [ -n "$watermark_logo" ] || [ -n "$watermark_text" ]; then
  watermark_enabled=1
fi

cleanup() {
  if [ -n "$runtime_tmp" ] && [ -d "$runtime_tmp" ]; then
    rm -rf "$runtime_tmp"
  fi
}

trap cleanup EXIT HUP INT TERM

if [ "$watermark_enabled" -eq 1 ] && [ "$dry_run" -eq 0 ]; then
  runtime_tmp="$(mktemp -d "${TMPDIR:-/tmp}/optimize-images.XXXXXX")"
  mkdir -p "$runtime_tmp/font-cache"
  export XDG_CACHE_HOME="$runtime_tmp/font-cache"
fi

validate_logo_image() {
  magick identify "$1[0]" >/dev/null 2>&1 || fail "watermark logo is not a readable image: $1"
}

if [ -n "$watermark_logo" ]; then
  case "$watermark_logo" in
    https://*)
      if [ "$dry_run" -eq 0 ]; then
        command -v curl >/dev/null 2>&1 || fail 'curl is required for an HTTPS watermark logo'
        watermark_logo_file="$runtime_tmp/remote-logo"
        curl \
          --fail \
          --silent \
          --show-error \
          --location \
          --proto '=https' \
          --proto-redir '=https' \
          --connect-timeout 10 \
          --max-time 30 \
          --max-filesize "$MAX_REMOTE_LOGO_BYTES" \
          --output "$watermark_logo_file" \
          "$watermark_logo" || fail 'unable to download the HTTPS watermark logo'

        downloaded_bytes="$(stat -f '%z' "$watermark_logo_file" 2>/dev/null || stat -c '%s' "$watermark_logo_file")"
        [ "$downloaded_bytes" -le "$MAX_REMOTE_LOGO_BYTES" ] || fail 'remote watermark logo exceeds 10 MB'
        validate_logo_image "$watermark_logo_file"
      fi
      ;;
    http://*)
      fail 'plain HTTP watermark logos are not allowed; use HTTPS'
      ;;
    *://*)
      fail 'watermark logo URLs must use HTTPS'
      ;;
    *)
      [ -f "$watermark_logo" ] || fail "watermark logo not found: $watermark_logo"
      watermark_logo_file="$watermark_logo"
      validate_logo_image "$watermark_logo_file"
      ;;
  esac
fi

font_is_available() {
  candidate="$1"
  if [ -f "$candidate" ]; then
    return 0
  fi

  magick -list font 2>/dev/null | awk -v candidate="$candidate" '
    $1 == "Font:" && $2 == candidate { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

if [ -n "$watermark_text" ] && [ "$dry_run" -eq 0 ]; then
  if [ "$watermark_font_explicit" -eq 1 ]; then
    font_is_available "$watermark_font" || fail "ImageMagick cannot find watermark font: $watermark_font"
  elif ! font_is_available "$watermark_font"; then
    for fallback_font in Helvetica Arial Liberation-Sans; do
      if font_is_available "$fallback_font"; then
        watermark_font="$fallback_font"
        break
      fi
    done
    font_is_available "$watermark_font" || fail 'no supported default watermark font was found'
  fi
fi

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
if [ "$watermark_enabled" -eq 1 ]; then
  printf 'Watermark: position %s, opacity %s%%, margin %spx\n' \
    "$watermark_position" "$watermark_opacity" "$watermark_margin"
  if [ -n "$watermark_logo" ]; then
    case "$watermark_logo" in
      https://*) printf 'Logo:     remote HTTPS image%s\n' "$([ "$dry_run" -eq 1 ] && printf ' (not downloaded in dry run)')" ;;
      *) printf 'Logo:     %s\n' "$watermark_logo_file" ;;
    esac
  fi
  [ -z "$watermark_text" ] || printf 'Text:     %s\n' "$watermark_text"
fi
printf '\n'

watermark_gravity() {
  case "$watermark_position" in
    bottom-right) printf 'southeast' ;;
    bottom-left) printf 'southwest' ;;
    top-right) printf 'northeast' ;;
    top-left) printf 'northwest' ;;
    center) printf 'center' ;;
  esac
}

render_watermarked_image() {
  source="$1"
  destination="$2"
  temporary="$3"

  if [ -z "$runtime_tmp" ]; then
    runtime_tmp="$(mktemp -d "${TMPDIR:-/tmp}/optimize-images.XXXXXX")"
  fi

  base_image="$runtime_tmp/base.miff"
  logo_image="$runtime_tmp/logo.miff"
  text_image="$runtime_tmp/text.miff"
  watermark_image="$runtime_tmp/watermark.miff"
  fitted_watermark="$runtime_tmp/watermark-fitted.miff"
  composited_image="$runtime_tmp/composited.miff"

  rm -f "$base_image" "$logo_image" "$text_image" "$watermark_image" "$fitted_watermark" "$composited_image"

  magick "$source" \
    -auto-orient \
    -colorspace sRGB \
    -resize "${size}x${size}>" \
    "$base_image" || return 1

  dimensions="$(magick identify -format '%w %h' "$base_image")"
  image_width="${dimensions%% *}"
  image_height="${dimensions##* }"

  effective_margin="$watermark_margin"
  margin_limit=$((image_width / 10))
  [ $((image_height / 10)) -lt "$margin_limit" ] && margin_limit=$((image_height / 10))
  [ "$effective_margin" -le "$margin_limit" ] || effective_margin="$margin_limit"

  max_watermark_width=$((image_width * 70 / 100))
  max_watermark_height=$((image_height * 25 / 100))
  [ "$max_watermark_width" -gt 0 ] || max_watermark_width=1
  [ "$max_watermark_height" -gt 0 ] || max_watermark_height=1

  if [ -n "$watermark_logo_file" ]; then
    magick "$watermark_logo_file[0]" \
      -auto-orient \
      -colorspace sRGB \
      -resize "${watermark_logo_size}x${watermark_logo_size}>" \
      -alpha on \
      "$logo_image" || return 1
  fi

  if [ -n "$watermark_text" ]; then
    magick \
      -background none \
      -fill white \
      -stroke 'rgba(0,0,0,0.70)' \
      -strokewidth 2 \
      -font "$watermark_font" \
      -pointsize "$watermark_font_size" \
      "label:$watermark_text" \
      "$text_image" || return 1
  fi

  if [ -n "$watermark_logo_file" ] && [ -n "$watermark_text" ]; then
    magick "$logo_image" "$text_image" -background none +smush 12 "$watermark_image" || return 1
  elif [ -n "$watermark_logo_file" ]; then
    cp "$logo_image" "$watermark_image" || return 1
  else
    cp "$text_image" "$watermark_image" || return 1
  fi

  magick "$watermark_image" \
    -resize "${max_watermark_width}x${max_watermark_height}>" \
    -alpha on \
    -channel A \
    -evaluate multiply "${watermark_opacity}%" \
    +channel \
    "$fitted_watermark" || return 1

  watermark_state="$(magick identify -format '%w %h %[fx:mean.a==0?0:1]' "$fitted_watermark" 2>/dev/null)" || return 1
  watermark_width="${watermark_state%% *}"
  watermark_remainder="${watermark_state#* }"
  watermark_height="${watermark_remainder%% *}"
  watermark_has_alpha="${watermark_state##* }"

  if [ "$watermark_width" -le 0 ] || [ "$watermark_height" -le 0 ] || [ "$watermark_has_alpha" != '1' ]; then
    printf 'Watermark overlay is empty or fully transparent.\n' >&2
    return 1
  fi

  geometry="+${effective_margin}+${effective_margin}"
  [ "$watermark_position" != 'center' ] || geometry='+0+0'

  magick "$base_image" "$fitted_watermark" \
    -gravity "$(watermark_gravity)" \
    -geometry "$geometry" \
    -compose over \
    -composite \
    "$composited_image" || return 1

  pixels_changed="$(magick "$base_image" "$composited_image" \
    -compose difference \
    -composite \
    -format '%[fx:mean==0?0:1]' \
    info: 2>/dev/null)" || return 1

  if [ "$pixels_changed" != '1' ]; then
    printf 'Watermark did not change any image pixels.\n' >&2
    return 1
  fi

  magick "$composited_image" \
    -strip \
    -quality "$quality" \
    -define webp:method=6 \
    "$temporary"
}

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

  if { [ "$watermark_enabled" -eq 1 ] && render_watermarked_image "$source" "$destination" "$temporary"; } || \
    { [ "$watermark_enabled" -eq 0 ] && magick "$source" \
      -auto-orient \
      -colorspace sRGB \
      -resize "${size}x${size}>" \
      -strip \
      -quality "$quality" \
      -define webp:method=6 \
      "$temporary"; }; then
    mv -f "$temporary" "$destination"
    generated_bytes="$(file_size "$destination")"
    output_bytes=$((output_bytes + generated_bytes))
    processed=$((processed + 1))
    if [ "$watermark_enabled" -eq 1 ]; then
      printf 'OK [watermarked] %s -> %s (%s)\n' \
        "$relative" \
        "${destination#"$output_dir"/}" \
        "$(human_size "$generated_bytes")"
    else
      printf 'OK    %s -> %s (%s)\n' \
        "$relative" \
        "${destination#"$output_dir"/}" \
        "$(human_size "$generated_bytes")"
    fi
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
