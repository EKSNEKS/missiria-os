# Batch Image Optimizer

`batches/optimize-images.sh` recursively converts supported images in a folder to optimized WebP files.

It is intended for website galleries, WordPress media preparation, article images and other bulk image-processing work.

## Default behavior

- Maximum width and height: `1024` pixels
- WebP quality: `82`
- Aspect ratio is preserved
- Images smaller than the configured limit are not enlarged
- EXIF orientation is applied before resizing
- Output is converted to sRGB
- Unnecessary metadata is removed
- Existing output files are skipped unless `--force` is provided
- Original images are never modified or deleted
- Nested source folders are reproduced inside the output directory
- Logo and website-text watermarks are optional and disabled by default

Supported input extensions:

- `.jpg` and `.jpeg`
- `.png`
- `.heic` and `.heif`
- `.tif` and `.tiff`
- `.webp`

## Requirements

- Bash
- ImageMagick 7 with the HEIC and WebP delegates enabled
- `curl` when `--watermark-logo` uses an HTTPS URL

Confirm the installation:

```bash
magick -version
magick identify -list format | grep -E 'HEIC|WEBP'
```

The `HEIC` and `WEBP` formats should appear as readable/writable where supported by the installed delegates.

## Installation

Make the script executable:

```bash
chmod +x batches/optimize-images.sh
```

Optionally install it system-wide:

```bash
sudo install -m 0755 batches/optimize-images.sh /usr/local/bin/optimize-images
```

## Usage

From the repository:

```bash
./batches/optimize-images.sh /path/to/gallery
```

When installed system-wide:

```bash
optimize-images /path/to/gallery
```

By default, generated files are written to:

```text
/path/to/gallery/optimized/
```

## Safe preview

Inspect what would be converted without writing anything:

```bash
./batches/optimize-images.sh /path/to/gallery --dry-run
```

## Options

```text
--size PIXELS       Maximum width and height (default: 1024)
--quality 1-100     WebP quality (default: 82)
--output DIRECTORY  Output directory (default: SOURCE_DIR/optimized)
--force             Replace existing generated WebP files
--dry-run           Show work without creating files
--watermark-logo PATH_OR_URL
                    Local JPG/PNG/WebP/SVG logo or HTTPS URL
--watermark-text TEXT
                    Text displayed beside the logo
--watermark-position POSITION
                    bottom-right, bottom-left, top-right, top-left or center
--watermark-opacity 1-100
                    Watermark opacity (default: 85)
--watermark-margin PIXELS
                    Edge margin (default: 24)
--watermark-logo-size PIXELS
                    Maximum logo width/height (default: 140)
--watermark-font FONT
                    ImageMagick font name or font-file path
--watermark-font-size PIXELS
                    Website text size (default: 24)
-h, --help          Display command help
```

Options can be combined:

```bash
./batches/optimize-images.sh /var/www/site/uploads \
  --size 1600 \
  --quality 88 \
  --output /tmp/site-webp
```

Replace previously generated output files:

```bash
./batches/optimize-images.sh /path/to/gallery --force
```

## Watermarks

Watermarking is opt-in. Supply a logo, text, or both. The watermark is applied after resizing and before WebP compression.

Use a local logo and website text:

```bash
./batches/optimize-images.sh /path/to/gallery \
  --watermark-logo ./branding/logo.png \
  --watermark-text "www.example.com"
```

Use a remote HTTPS logo:

```bash
./batches/optimize-images.sh /path/to/gallery \
  --watermark-logo "https://example.com/assets/logo.png" \
  --watermark-text "www.example.com"
```

Text-only and logo-only modes are also supported:

```bash
./batches/optimize-images.sh /path/to/gallery \
  --watermark-text "www.example.com" \
  --watermark-position bottom-left

./batches/optimize-images.sh /path/to/gallery \
  --watermark-logo ./branding/logo.jpg \
  --watermark-position center
```

Default watermark styling:

- Bottom-right placement with a 24 px margin
- 85% opacity
- Logo capped at 140 px
- Website text at 24 px, white with a dark outline
- Combined logo and text are placed side by side
- The complete watermark is automatically reduced when it would exceed 70% of image width or 25% of image height

Transparent PNG or WebP logos produce the cleanest result. JPG logos are supported, but their rectangular background remains visible.

Remote logo rules:

- Only HTTPS URLs are accepted
- Redirects are followed only while the protocol remains HTTPS
- Connection timeout is 10 seconds and total download timeout is 30 seconds
- Downloads larger than 10 MB are rejected
- ImageMagick must recognize the downloaded response as an image
- The logo is downloaded once per batch and removed automatically when the script exits
- `--dry-run` reports the remote logo configuration without downloading it

Choose another placement or style:

```bash
./batches/optimize-images.sh /path/to/gallery \
  --watermark-logo ./branding/logo.webp \
  --watermark-text "www.example.com" \
  --watermark-position top-right \
  --watermark-opacity 80 \
  --watermark-margin 32 \
  --watermark-logo-size 180 \
  --watermark-font-size 28
```

## Output and safety

Each source filename keeps its basename and receives the `.webp` extension:

```text
gallery/photo.heic        -> gallery/optimized/photo.webp
gallery/trip/car.jpg      -> gallery/optimized/trip/car.webp
```

If two source images in the same directory have the same basename but different extensions, they target the same WebP filename. The first generated file is preserved and the later collision is reported as an existing destination unless `--force` is used. Rename duplicate basenames before using `--force`.

The script writes to a temporary `.tmp.webp` file and moves it into place only after ImageMagick succeeds. Failed conversions return a non-zero exit status and do not delete source images.

When watermarking is enabled, intermediate images, font-cache data and downloaded logos live in a temporary directory that is removed on success, failure, interruption or termination.

Before reporting success, the script verifies that the prepared overlay contains visible alpha pixels and that compositing changes the resized image. An empty, fully transparent or no-op watermark fails that image instead of reporting a misleading `OK` result. Successful files are labeled `OK [watermarked]`.

## Summary report

At completion the script reports:

- Processed images
- Skipped images
- Failed images
- Total input size
- Total generated output size

Example:

```text
Summary
  Processed: 11
  Skipped:   0
  Failed:    0
  Input:     30.2 MB
  Output:    531.5 KB
```

## Troubleshooting

### `ImageMagick 7 (magick) is required`

Install ImageMagick 7 and ensure `magick` is available in `PATH`.

### HEIC images fail

The ImageMagick installation is missing HEIC support. Install the `libheif` delegate and rebuild or reinstall ImageMagick with HEIC enabled.

### Existing images are skipped

This is the default overwrite protection. Review the files, then rerun with `--force` only when replacement is intended.

### Output appears in an unexpected location

Relative paths supplied to `--output` are resolved from the current working directory. Use an absolute output path when running the script from automation.

### The watermark font is unavailable

Without `--watermark-font`, the script selects the first installed font from DejaVu Sans, Helvetica, Arial and Liberation Sans. For predictable server output, provide an installed ImageMagick font name or an absolute path to a font file.

### A remote logo is rejected

Confirm the URL uses HTTPS, returns an image rather than an HTML page, responds within 30 seconds and is no larger than 10 MB. Use `curl -I -L URL` to inspect redirects and response headers.
