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

Supported input extensions:

- `.jpg` and `.jpeg`
- `.png`
- `.heic` and `.heif`
- `.tif` and `.tiff`
- `.webp`

## Requirements

- Bash
- ImageMagick 7 with the HEIC and WebP delegates enabled

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

## Output and safety

Each source filename keeps its basename and receives the `.webp` extension:

```text
gallery/photo.heic        -> gallery/optimized/photo.webp
gallery/trip/car.jpg      -> gallery/optimized/trip/car.webp
```

If two source images in the same directory have the same basename but different extensions, they target the same WebP filename. The first generated file is preserved and the later collision is reported as an existing destination unless `--force` is used. Rename duplicate basenames before using `--force`.

The script writes to a temporary `.tmp.webp` file and moves it into place only after ImageMagick succeeds. Failed conversions return a non-zero exit status and do not delete source images.

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
