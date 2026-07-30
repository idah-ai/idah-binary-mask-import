# frozen_string_literal: true

# RLE codec for binary mask tiles.
#
# Matches the frontend codec in plugins/idah-image/frontend/src/lib/mask/rle.ts
#
# Format: implicit alternating runs starting with a 0-run, last run omitted.
# Each run length is encoded as 1 byte (0–127) or 2 bytes (128–32767) with
# bit 7 of the first byte as the size flag. The byte sequence is then
# base64-encoded (RFC 4648 with padding).
class RleEncoder
  MAX_RUN_LENGTH = 32_767

  # Encode a flat binary array (values 0 or 1) into an RLE base64 string.
  def encode(buffer, w, h)
    total = w * h
    return "" if total == 0

    runs = []
    current_bit = 0
    count = 0

    total.times do |i|
      v = buffer[i]
      if v == current_bit
        count += 1
      else
        runs << count
        current_bit = current_bit == 0 ? 1 : 0
        count = 1
      end
    end
    runs << count
    runs.pop # last run omitted (canonical)

    bytes = pack_run_lengths(runs)
    return "" if bytes.empty?

    [bytes.pack("C*")].pack("m0")
  end

  # Decode an RLE base64 string back into a flat binary array.
  def decode(rle, w, h)
    total = w * h
    return Array.new(total, 0) if total == 0 || rle.nil? || rle.empty?

    bytes = rle.unpack1("m0").bytes
    explicit_runs = unpack_run_lengths(bytes)
    sum_explicit = explicit_runs.sum
    implicit_len = total - sum_explicit

    if implicit_len < 0
      raise ArgumentError,
            "RLE data exceeds tile size: sum of explicit runs (#{sum_explicit}) > total pixels (#{total})"
    end

    buffer = Array.new(total, 0)
    offset = 0
    bit = 0

    explicit_runs.each do |run|
      if bit == 1
        run.times { |j| buffer[offset + j] = 1 }
      end
      offset += run
      bit = 1 - bit
    end

    if bit == 1 && implicit_len > 0
      implicit_len.times { |j| buffer[offset + j] = 1 }
    end

    buffer
  end

  private

  def pack_run_lengths(runs)
    bytes = []
    runs.each do |run|
      if run > MAX_RUN_LENGTH
        raise ArgumentError, "Run length #{run} exceeds maximum representable value #{MAX_RUN_LENGTH}"
      end
      if run < 128
        bytes << (run & 0x7f)
      else
        bytes << (0x80 | ((run >> 8) & 0x7f))
        bytes << (run & 0xff)
      end
    end
    bytes
  end

  def unpack_run_lengths(bytes)
    runs = []
    i = 0
    while i < bytes.length
      b0 = bytes[i]
      if b0 & 0x80 != 0
        raise ArgumentError, "Truncated RLE data" if i + 1 >= bytes.length
        runs << ((b0 & 0x7f) << 8) | bytes[i + 1]
        i += 2
      else
        runs << b0
        i += 1
      end
    end
    runs
  end
end
