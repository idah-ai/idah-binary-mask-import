#!/usr/bin/env ruby
# frozen_string_literal: true

# IDAH Binary Mask Dataset Import Script
#
# Orchestrates the complete import workflow:
# 1. Create dataset
# 2. For each image/mask pair:
#    a. Upload image to media service (returns resource key)
#    b. Create entry using the media's resource key
#    c. Encode mask locally (tile-by-tile RLE → base64)
#    d. Create annotation with:
#       - shape_type: "idah-image:mask"
#       - shape_args: { points: [] }
#       - category: <from --mask-category>
#    e. Write each tile as a separate annotation_shape row
#
# Directory structure:
#   dataset_folder/
#   ├── images/
#   │   ├── image_001.jpg
#   │   ├── image_002.tif
#   │   └── ...
#   └── masks/
#       ├── category_1/
#       │   ├── image_001.png
#       │   ├── image_002.png
#       │   └── ...
#       └── category_2/
#           ├── image_001.png
#           ├── image_002.png
#           └── ...
#
# Pairing logic:
#   - Source images are loaded from the images/ directory.
#   - Binary masks are loaded from the chosen mask category directory under masks/.
#   - Images and masks are matched by filename stem (ignoring extension).
#   - The annotation category is provided via the --mask-category command-line argument.

require "optparse"
require "fileutils"
require "securerandom"
require_relative "lib/idah_client"
require_relative "lib/rle_encoder"
require_relative "lib/mask_encoder"

SUPPORTED_IMAGE_EXTENSIONS = %w[.png .jpg .jpeg .tif .tiff].freeze
SUPPORTED_MASK_EXTENSIONS  = %w[.png].freeze

options = {
  api_url: "https://idah.localhost:8443/",
  api_key: nil,
  project_id: nil,
  dataset_dir: nil,
  mask_category: nil,
  dataset_name: "Imported Dataset",
  insecure: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby main.rb [options]"

  opts.on("--api-url URL", "IDAH API base URL (default: https://idah.localhost:8443/)") do |v|
    options[:api_url] = v
  end

  opts.on("--api-key KEY", "API key for authentication") do |v|
    options[:api_key] = v
  end

  opts.on("--project-id ID", "Target project ID") do |v|
    options[:project_id] = v
  end

  opts.on("--dataset-dir DIR", "Root directory containing images/ and masks/ subdirectories") do |v|
    options[:dataset_dir] = v
  end

  opts.on("--mask-category CATEGORY", "Mask category name (e.g. 'category_1'). This is the subdirectory name under masks/ and the annotation category value.") do |v|
    options[:mask_category] = v
  end

  opts.on("--dataset-name NAME", "Name for the created dataset") do |v|
    options[:dataset_name] = v
  end

  opts.on("--revert-mask", "Treat black pixels as mask and white as background (inverted from default)") do
    options[:revert_mask] = true
  end

  opts.on("--insecure", "Disable SSL certificate verification (use for self-signed certs)") do
    options[:insecure] = true
  end

  opts.on("-h", "--help", "Prints help") do
    puts opts
    exit
  end
end.parse!

# Validate required options
%w[api_key project_id dataset_dir mask_category].each do |key|
  if options[key.to_sym].nil? || options[key.to_sym].empty?
    abort "ERROR: --#{key.tr("_", "-")} is required"
  end
end

dataset_dir = options[:dataset_dir]
unless Dir.exist?(dataset_dir)
  abort "ERROR: Dataset directory '#{dataset_dir}' does not exist"
end

# ── Locate subdirectories ────────────────────────────────────────────────

images_dir = File.join(dataset_dir, "images")
masks_dir  = File.join(dataset_dir, "masks", options[:mask_category])

unless Dir.exist?(images_dir)
  abort "ERROR: Images directory '#{images_dir}' does not exist"
end

unless Dir.exist?(masks_dir)
  abort "ERROR: Masks directory '#{masks_dir}' does not exist"
end

# ── Discover image/mask pairs ────────────────────────────────────────────

# Helper: strip extension(s) from basename to get the stem
# e.g. "image_001.png" -> "image_001", "photo.jpg" -> "photo"
def file_stem(filepath)
  ext = File.extname(filepath).downcase
  File.basename(filepath, ext)
end

# Collect all supported image files
image_glob = SUPPORTED_IMAGE_EXTENSIONS.map { |ext| File.join(images_dir, "*#{ext}") }
image_files = Dir.glob(image_glob).sort

if image_files.empty?
  abort "ERROR: No supported image files (#{SUPPORTED_IMAGE_EXTENSIONS.join(', ')}) found in '#{images_dir}'"
end

# Collect all supported mask files
mask_glob = SUPPORTED_MASK_EXTENSIONS.map { |ext| File.join(masks_dir, "*#{ext}") }
mask_files = Dir.glob(mask_glob).sort

if mask_files.empty?
  abort "ERROR: No supported mask files (#{SUPPORTED_MASK_EXTENSIONS.join(', ')}) found in '#{masks_dir}'"
end

# Build a lookup from mask stem → mask path
mask_by_stem = {}
mask_files.each do |m|
  stem = file_stem(m)
  if mask_by_stem.key?(stem)
    warn "WARNING: Duplicate mask stem '#{stem}' (#{mask_by_stem[stem]} and #{m}), using first"
  else
    mask_by_stem[stem] = m
  end
end

# Build pairs by matching image stems to mask stems
pairs = []
images_without_mask = []

image_files.each do |img_path|
  stem = file_stem(img_path)
  mask_path = mask_by_stem[stem]

  if mask_path.nil?
    images_without_mask << img_path
    next
  end

  pairs << {
    image: img_path,
    mask: mask_path,
    name: "#{stem}",
    category: options[:mask_category]
  }
end

# Report images without matching masks
if images_without_mask.any?
  warn "\nWARNING: #{images_without_mask.length} image(s) have no matching mask (skipped):"
  images_without_mask.each { |p| warn "  - #{p}" }
end

# Report masks without matching images
masks_without_image = mask_files.reject { |m| pairs.any? { |p| p[:mask] == m } }
if masks_without_image.any?
  warn "\nWARNING: #{masks_without_image.length} mask(s) have no matching image (unused):"
  masks_without_image.each { |p| warn "  - #{p}" }
end

if pairs.empty?
  abort "ERROR: No image/mask pairs found. Check that filenames (without extension) match between images/ and masks/#{options[:mask_category]}/"
end

puts "Found #{pairs.length} image/mask pair(s) (category: #{options[:mask_category]})"

# ── Initialize components ──────────────────────────────────────────────

client = IdahClient.new(
  api_url: options[:api_url],
  api_key: options[:api_key],
  insecure: options[:insecure]
)
mask_encoder = MaskEncoder.new(revert: options[:revert_mask])

# Authenticate: exchange the API key for a JWT bearer token
puts "\nAuthenticating..."
client.authenticate!
puts "Authenticated successfully"

# Build labeling_configuration with idah-image:mask tool type containing the category
# This follows the IConfig/IShapeConfig structure used by the frontend
labeling_configuration = {
  "idah-image:mask" => {
    values: [
      { id: options[:mask_category], label: options[:mask_category], color: "#9C1AB2", text_color: nil }
    ],
    properties: [],
    order: 1
  }
}

# ── Step 1: Create dataset with labeling configuration ─────────────────

puts "\nCreating dataset '#{options[:dataset_name]}'..."
dataset_response = client.create_dataset(
  options[:project_id],
  options[:dataset_name],
  labeling_configuration: labeling_configuration
)
dataset_id = dataset_response.dig("data", "id")
abort "ERROR: Failed to create dataset" unless dataset_id

puts "Dataset created: #{dataset_id}"

# Log the labeling config summary
config = labeling_configuration["idah-image:mask"]
puts "  Labeling config: idah-image:mask with #{config[:values]&.length || 0} category(ies)"

# ── Step 2: Import each image/mask pair ────────────────────────────────

success_count = 0
error_count = 0

pairs.each_with_index do |pair, idx|
  puts "\n--- [#{idx + 1}/#{pairs.length}] #{pair[:name]} ---"

  begin
    # a. Upload image to media service FIRST
    #    The resource key is a UUID-based identifier with file extension,
    #    matching the frontend pattern:
    #      crypto.randomUUID().replace(/-/g, "").substring(0, 16)
    file_ext = File.extname(pair[:image]).downcase
    resource_key = "#{SecureRandom.uuid.delete("-")[0, 16]}#{file_ext}"
    puts "  Uploading image..."
    client.upload_media(
      pair[:image],
      options[:project_id],
      resource: resource_key,
      modality: "idah-image"
    )
    puts "  Image uploaded (resource: #{resource_key})"

    # b. Create entry using the media's resource key
    puts "  Creating entry..."
    entry_response = client.create_entry(
      dataset_id,
      name: pair[:name],
      resource: resource_key
    )
    entry_id = entry_response.dig("data", "id")
    raise "Failed to create entry" unless entry_id
    puts "  Entry created: #{entry_id}"

    # c. Encode mask: split into 128x128 tiles, RLE each tile → base64
    puts "  Encoding mask (tile by tile)..."
    mask_png = File.binread(pair[:mask])
    metadata, tile_shapes = mask_encoder.encode_to_shapes(mask_png)
    puts "  Mask encoded: #{tile_shapes.length} tiles"

    # d. Build annotation payload
    shape_type = "idah-image:mask"
    shape_args = { points: [] }
    puts "  Category: #{pair[:category]}"

    # e. Create annotation
    puts "  Creating annotation..."
    annotation_response = client.create_annotation(
      entry_id,
      shape_type: shape_type,
      shape_args: shape_args,
      category: pair[:category]
    )
    annotation_id = annotation_response["id"]
    raise "Failed to create annotation" unless annotation_id
    puts "  Annotation created: #{annotation_id}"

    # f. Write each tile as a separate annotation_shape row
    puts "  Writing #{tile_shapes.length} tile shape(s)..."
    tile_shapes.each do |shape|
      client.write_shape(annotation_id, shape[:key], shape[:value])
    end
    puts "  Tile shapes written"

    success_count += 1
    puts "  ✓ #{pair[:name]} imported successfully"

  rescue StandardError => e
    error_count += 1
    warn "  ✗ #{pair[:name]} failed: #{e.message}"
    warn "    #{e.backtrace&.first(3)&.join("\n    ")}"
  end
end

# ── Summary ────────────────────────────────────────────────────────────

puts "\n" + "=" * 50
puts "Import complete"
puts "  Dataset ID: #{dataset_id}"
puts "  Category:   #{options[:mask_category]}"
puts "  Successful: #{success_count}"
puts "  Failed:     #{error_count}"
puts "=" * 50