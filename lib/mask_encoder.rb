# frozen_string_literal: true

require "chunky_png"

# Converts a binary mask PNG into the IDAH binary mask format.
#
# Encoding pipeline per tile:
#   1. Extract 128x128 pixel tile from the mask image
#   2. Run-length encode (RLE) the tile's binary pixel data
#   3. Pack run lengths into bytes (1 or 2 bytes per run)
#   4. Base64-encode the byte array
#
# The result is a hash containing metadata and per-tile RLE data.
class MaskEncoder
  TILE_SIZE = 128

  def initialize(rle_encoder = RleEncoder.new)
    @rle_encoder = rle_encoder
  end

  # Encode a binary mask PNG.
  #
  # The mask is divided into 128x128 tiles. Each tile is RLE-encoded
  # independently (pixels read left-to-right, top-to-bottom).
  #
  # @param png_data [String] raw PNG file bytes
  # @return [Hash] mask metadata + per-tile RLE data
  def encode(png_data)
    image = ChunkyPNG::Image.from_blob(png_data)
    width = image.width
    height = image.height

    tiles = {}
    tile_index = 0

    n_cols = (width.to_f / TILE_SIZE).ceil
    n_rows = (height.to_f / TILE_SIZE).ceil

    n_rows.times do |row|
      n_cols.times do |col|
        tile_data = extract_tile(image, col, row, width, height)
        encoded = @rle_encoder.encode(tile_data, TILE_SIZE, TILE_SIZE)
        # Only include non-empty tiles
        tiles["tile-#{col}x#{row}"] = {
          rle: encoded
        }
        tile_index += 1
      end
    end

    {
      type: "binary_mask",
      encoding: "rle-varint-base64",
      tile_size: TILE_SIZE,
      width: width,
      height: height,
      tiles: tiles
    }
  end

  # Encode a binary mask PNG and return the tiles as individual shape entries
  # (one per tile), plus the non-tile metadata for the annotation's dimensions.
  def encode_to_shapes(png_data)
    image = ChunkyPNG::Image.from_blob(png_data)
    width = image.width
    height = image.height

    shapes = []
    tile_index = 0

    n_cols = (width.to_f / TILE_SIZE).ceil
    n_rows = (height.to_f / TILE_SIZE).ceil

    n_rows.times do |row|
      n_cols.times do |col|
        tile_data = extract_tile(image, col, row, width, height)
        encoded = @rle_encoder.encode(tile_data, TILE_SIZE, TILE_SIZE)
        if encoded == ""
          # Skip empty tiles (no shape entry)
          tile_index += 1
          next
        end

        shapes << {
          key: "tile-#{col}x#{row}",
          value: { rle: encoded }
        }
        tile_index += 1
      end
    end

    metadata = {
      type: "binary_mask",
      encoding: "rle-varint-base64",
      tile_size: TILE_SIZE,
      width: width,
      height: height
    }

    [metadata, shapes]
  end

  private

  def extract_tile(image, col, row, img_width, img_height)
    tile = Array.new(TILE_SIZE * TILE_SIZE, 0)

    TILE_SIZE.times do |py|
      TILE_SIZE.times do |px|
        img_x = col * TILE_SIZE + px
        img_y = row * TILE_SIZE + py
        next if img_x >= img_width || img_y >= img_height

        pixel = image[img_x, img_y]
        r = ChunkyPNG::Color.r(pixel)
        g = ChunkyPNG::Color.g(pixel)
        b = ChunkyPNG::Color.b(pixel)

        # Any non-zero pixel is mask (1), zero is background (0)
        value = (r > 0 || g > 0 || b > 0) ? 1 : 0
        tile[py * TILE_SIZE + px] = value
      end
    end

    tile
  end
end