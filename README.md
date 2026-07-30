# IDAH Binary Mask Dataset Import Script

A standalone Ruby script to import images and their binary masks into [IDAH](https://github.com/idah-ai/idah) as annotations.

## Requirements

- Ruby 3.0+
- `rack` gem (for MIME type detection)
- `chunky_png` gem (for mask encoding)

Install dependencies:

```bash
gem install rack chunky_png
```

Or with Bundler:

```bash
bundle install
```

## Usage

```bash
ruby main.rb \
  --api-url http://localhost:3000 \
  --api-key your-api-key \
  --project-id proj_abc123 \
  --dataset-dir ./dataset_folder \
  --mask-category category_1 \
  --dataset-name "My Dataset"
```

### Options

| Option            | Required | Description                                                                                                 |
| ----------------- | -------- | ----------------------------------------------------------------------------------------------------------- |
| `--api-url`       | No       | IDAH API base URL (default: `https://idah.localhost:8443/`)                                                 |
| `--api-key`       | Yes      | API key for authentication                                                                                  |
| `--project-id`    | Yes      | Target project ID                                                                                           |
| `--dataset-dir`   | Yes      | Root directory containing `images/` and `masks/` subdirectories                                             |
| `--mask-category` | Yes      | Mask category name (e.g. `category_1`). Subdirectory name under `masks/` and the annotation category value. |
| `--dataset-name`  | No       | Name for the created dataset (default: "Imported Dataset")                                                  |
| `--insecure`      | No       | Disable SSL certificate verification (use for self-signed certs)                                            |

## Input Directory Structure

Images can be `.png`, `.jpg`, `.jpeg`, `.tif`, or `.tiff`. Masks must be **PNG** files only.

```
dataset_folder/
├── images/
│   ├── image_001.jpg
│   ├── image_002.tif
│   └── ...
└── masks/
    ├── category_1/
    │   ├── image_001.png
    │   ├── image_002.png
    │   └── ...
    └── category_2/
        ├── image_001.png
        ├── image_002.png
        └── ...
```

### Pairing Logic

Images and masks are matched by **filename stem** (the filename without its extension), regardless of the file extension. For example:

- `images/image_001.jpg` ↔ `masks/category_1/image_001.png` ✓
- `images/image_002.tif` ↔ `masks/category_1/image_002.png` ✓

### Reporting

- Images without a matching mask are reported as warnings and skipped.
- Masks without a matching image are reported as warnings and left unused.

## Workflow

The script performs the following steps for each image/mask pair:

1. **Upload image** to the Media service with correct MIME type (`image/png`, `image/jpeg`, etc.)
2. **Create entry** in the dataset linked to the uploaded media
3. **Encode mask** — splits the binary mask into 128×128 tiles, RLE-encodes each tile, and base64-encodes the result
4. **Create annotation** with the category and mask dimensions
5. **Write tile shapes** — each tile is stored as a separate annotation shape row

## Notes

- Resource keys for uploaded media are generated as UUID-based identifiers
  (first 16 hex chars without dashes) with the file extension, matching the
  frontend upload pattern.
- The MIME type is explicitly set in the multipart upload request using
  `Rack::Mime.mime_type()`, ensuring the correct type is stored in the database
  (e.g. `image/png` instead of `application/octet-stream`).
- The annotation category is provided via `--mask-category`. Future iterations
  may support inferring the category from the mask folder name automatically.

## License

FSL-1.1-ALv2 — see [LICENSE.md](LICENSE.md).
