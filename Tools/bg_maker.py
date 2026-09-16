#!/usr/bin/env python3
"""
bg_maker.py - Converts any image into a bg.bmp for NeoSDLoader's cover-art
box feature (root bg.bmp, and per-game bg.bmp).

Output format (required by LoadCustomBG / LoadCustomBGSilent in
Patch/Patch0011/ui_bg.asm):
    - 128x128 pixels (the menu's fixed cover-art box, see BG_BOX_W_TILES /
      BG_BOX_H_TILES in Patch/Patch0011/equ.asm)
    - 4 bits per pixel, but with up to BG_PALETTE_COUNT (default 8) different
      16-color palettes, one assigned per 16x16 tile (8x8 tile grid) - a
      classic Neo Geo sprite trick to get more than 16 colors on screen at
      once, since each SPRITE TILE (not each pixel) can pick its own bank.
      A single-palette (--palettes 1) mode is still available and produces
      a plain, standard-looking 4bpp BMP.
    - Uncompressed (BI_RGB)
    - Standard 40-byte BITMAPINFOHEADER, bottom-up row order
    - BGRA palette(s) right after the header - with --palettes > 1, this is
      BG_PALETTE_COUNT*16 entries (not a standard BMP viewers will render
      correctly - the extra palettes ride in the same slot as biClrUsed
      extra entries), followed by a tile-to-palette-index byte per tile
      (column-major, top-to-bottom-per-column) appended after the pixel
      data - this last part only the patch's decoder understands.

Usage:
    python bg_maker.py <input_image> [output.bmp] [options]

If output.bmp is omitted, writes "bg.bmp" next to the input image.

Options:
    --fit {stretch,cover,blur,contain}  How to fit the image into 128x128
                                        (default: stretch)
                            stretch = resize straight to 128x128, ignoring
                                      aspect ratio - whole image visible,
                                      nothing cropped, no padding; may look
                                      squashed/stretched if the source isn't
                                      already close to square
                            cover   = fill the whole frame, cropping overflow
                            blur    = whole image visible (like contain), but the
                                      side gaps are filled with a blurred/darkened
                                      cover-cropped version of the same image
                                      instead of a flat color
                            contain = fit the whole image, padding with --pad-color
    --pad-color RRGGBB      Padding color for --fit contain (default: 000000)
    --no-dither             Disable dithering during 16-color-per-palette quantization
    --colors N              Colors per palette, 2-16 (default: 16)
    --palettes N             How many independent 16-color palettes to use
                              across the 8x8 tile grid, one per tile cluster
                              (default: 8; use 1 for a plain single-palette
                              image, e.g. for compatibility/simplicity)

Examples:
    python bg_maker.py cover.jpg
    python bg_maker.py cover.jpg "D:\\SD\\SomeGame\\bg.bmp"
    python bg_maker.py screenshot.png --fit blur
    python bg_maker.py poster.jpg --fit contain --pad-color 101018
    python bg_maker.py flat_logo.png --palettes 1
"""
import argparse
import os
import struct
import sys

import numpy as np
from PIL import Image, ImageEnhance, ImageFilter

TARGET_W, TARGET_H = 128, 128
BG_BOX_W_TILES, BG_BOX_H_TILES = 8, 8
TILE_PX_W, TILE_PX_H = TARGET_W // BG_BOX_W_TILES, TARGET_H // BG_BOX_H_TILES
TILE_COUNT = BG_BOX_W_TILES * BG_BOX_H_TILES


def fit_stretch(img: Image.Image) -> Image.Image:
    # Straight resize to fill the frame, ignoring aspect ratio - whole image
    # visible, nothing cropped, no padding/blur fill needed.
    return img.resize((TARGET_W, TARGET_H), Image.LANCZOS)


def fit_cover(img: Image.Image, size=(TARGET_W, TARGET_H)) -> Image.Image:
    w, h = size
    src_w, src_h = img.size
    scale = max(w / src_w, h / src_h)
    new_w, new_h = round(src_w * scale), round(src_h * scale)
    img = img.resize((new_w, new_h), Image.LANCZOS)
    left = (new_w - w) // 2
    top = (new_h - h) // 2
    return img.crop((left, top, left + w, top + h))


def fit_contain(img: Image.Image, pad_color) -> Image.Image:
    src_w, src_h = img.size
    scale = min(TARGET_W / src_w, TARGET_H / src_h)
    new_w, new_h = round(src_w * scale), round(src_h * scale)
    img = img.resize((new_w, new_h), Image.LANCZOS)
    canvas = Image.new("RGB", (TARGET_W, TARGET_H), pad_color)
    left = (TARGET_W - new_w) // 2
    top = (TARGET_H - new_h) // 2
    canvas.paste(img, (left, top))
    return canvas


def fit_blur(img: Image.Image) -> Image.Image:
    # Backdrop: cover-cropped, blurred and darkened so it reads as texture,
    # not as a second copy of the image competing with the sharp one on top.
    backdrop = fit_cover(img, (TARGET_W, TARGET_H))
    # Upscale a bit before blurring so the blur radius doesn't get "diluted"
    # by the final downscale, then blur and darken.
    backdrop = backdrop.filter(ImageFilter.GaussianBlur(radius=8))
    backdrop = ImageEnhance.Brightness(backdrop).enhance(0.45)

    # Foreground: whole image visible, fit within the frame.
    src_w, src_h = img.size
    scale = min(TARGET_W / src_w, TARGET_H / src_h)
    new_w, new_h = round(src_w * scale), round(src_h * scale)
    fg = img.resize((new_w, new_h), Image.LANCZOS)

    canvas = backdrop.copy()
    left = (TARGET_W - new_w) // 2
    top = (TARGET_H - new_h) // 2
    canvas.paste(fg, (left, top))
    return canvas


_HW_4BIT_LUT = [((v >> 4) * 17) for v in range(256)]  # matches ui_bg.asm's "lsr.b #4" truncation exactly


def round_to_hardware_colorspace(img: Image.Image) -> Image.Image:
    """The console's palette RAM only keeps the upper 4 bits of each R/G/B
    channel (see the palette-conversion code in ui_bg.asm), so it can only
    ever show 16 levels per channel (4096 colors total), not the full 24-bit
    range. Rounding to that space *before* picking the 16-color palette
    lets PIL choose colors from what will actually be displayed, instead of
    optimizing in full color space and then having the hardware truncate
    them afterwards to something else - which is what was producing the
    poor-looking result."""
    lut = _HW_4BIT_LUT * 3  # same LUT for R, G, B bands
    return img.point(lut)


def iter_tiles_column_major():
    """Yields (tile_index, col, row) in the exact order SetupBGSprites (in
    ui_bg.asm) writes the SCB1 tilemap: outer loop over columns, inner loop
    over rows within each column. tile_index 0..63 must line up with that
    order since it's also how tile NUMBERS are assigned during decode."""
    idx = 0
    for col in range(BG_BOX_W_TILES):
        for row in range(BG_BOX_H_TILES):
            yield idx, col, row
            idx += 1


SPATIAL_WEIGHT = 0.7  # 0 = pure color clustering (can scatter same-color tiles
                       # anywhere, giving a "patchwork" look with visible tile-
                       # edge color jumps even across smooth gradients); higher
                       # pulls neighboring tiles towards sharing a palette,
                       # trading a little color precision for smoother-looking
                       # region boundaries. Tuned by eye, not a hard science.


def cluster_tiles(tile_means: np.ndarray, k: int, positions: np.ndarray = None,
                   spatial_weight: float = 0.0, iters: int = 25, seed: int = 0) -> np.ndarray:
    """Simple Lloyd's-algorithm k-means (no external ML dependency) on the
    64 per-tile mean colors - optionally blended with each tile's (col, row)
    position (scaled to the same 0-255 range and weighted by
    `spatial_weight`) so spatially adjacent tiles are more likely to land in
    the same cluster, instead of clusters being scattered purely by color
    similarity (which reads as a "checkerboard" of independently-chosen
    palettes at every tile boundary). Returns a (64,) array of cluster
    indices 0..k-1. k is small (<=16) and there are only 64 points, so this
    converges in a handful of iterations."""
    features = tile_means
    if positions is not None and spatial_weight > 0:
        max_pos = max(positions[:, 0].max(), positions[:, 1].max(), 1)
        pos_scaled = (positions.astype(np.float64) / max_pos) * 255.0 * spatial_weight
        features = np.concatenate([tile_means, pos_scaled], axis=1)

    rng = np.random.default_rng(seed)
    n = features.shape[0]
    k = min(k, n)
    # k-means++-ish seeding: pick well-separated starting centroids instead
    # of pure random, so small k doesn't get an unlucky duplicate start.
    first = rng.integers(n)
    centroids = [features[first]]
    for _ in range(k - 1):
        d2 = np.min([np.sum((features - c) ** 2, axis=1) for c in centroids], axis=0)
        probs = d2 / (d2.sum() + 1e-9)
        next_idx = rng.choice(n, p=probs)
        centroids.append(features[next_idx])
    centroids = np.stack(centroids)

    assignments = np.zeros(n, dtype=np.int64)
    for _ in range(iters):
        dists = np.stack([np.sum((features - c) ** 2, axis=1) for c in centroids], axis=1)
        new_assignments = np.argmin(dists, axis=1)
        if np.array_equal(new_assignments, assignments) and _ > 0:
            break
        assignments = new_assignments
        for c_idx in range(k):
            members = features[assignments == c_idx]
            if len(members):
                centroids[c_idx] = members.mean(axis=0)
    return assignments


def quantize_multi_palette(img: Image.Image, k: int, colors: int, dither: bool):
    """Splits the image into its 8x8 tile grid, clusters the tiles into `k`
    groups by average color, quantizes each group's actual pixels to its own
    `colors`-size palette, and returns:
        index_img: a (128,128) uint8 array, each pixel an index 0..colors-1
                   *relative to its own tile's assigned palette*
        palettes:  list of k palettes, each a list of `colors` (r,g,b) tuples
        tile_palette_map: list of 64 ints (0..k-1), column-major tile order
    """
    arr = np.asarray(img, dtype=np.float64)  # (H, W, 3)

    tile_means = np.zeros((TILE_COUNT, 3))
    tile_positions = np.zeros((TILE_COUNT, 2))
    for idx, col, row in iter_tiles_column_major():
        block = arr[row * TILE_PX_H:(row + 1) * TILE_PX_H, col * TILE_PX_W:(col + 1) * TILE_PX_W]
        tile_means[idx] = block.reshape(-1, 3).mean(axis=0)
        tile_positions[idx] = (col, row)

    tile_cluster = cluster_tiles(tile_means, k, positions=tile_positions, spatial_weight=SPATIAL_WEIGHT)
    actual_k = int(tile_cluster.max()) + 1

    index_img = np.zeros((TARGET_H, TARGET_W), dtype=np.uint8)
    palettes = []
    for c_idx in range(actual_k):
        tiles_in_cluster = [(idx, col, row) for idx, col, row in iter_tiles_column_major() if tile_cluster[idx] == c_idx]

        # Build a temporary image out of just this cluster's tiles, side by
        # side, so PIL's quantizer sees only the colors relevant to this
        # region and picks a palette tuned for it.
        strip = Image.new("RGB", (TILE_PX_W, TILE_PX_H * len(tiles_in_cluster)))
        for i, (idx, col, row) in enumerate(tiles_in_cluster):
            tile_img = Image.fromarray(arr[row * TILE_PX_H:(row + 1) * TILE_PX_H,
                                            col * TILE_PX_W:(col + 1) * TILE_PX_W].astype(np.uint8))
            strip.paste(tile_img, (0, i * TILE_PX_H))

        q = strip.quantize(colors=colors, method=Image.MEDIANCUT, kmeans=8,
                            dither=Image.FLOYDSTEINBERG if dither else Image.NONE)
        pal_flat = q.getpalette() or []
        pal_flat = pal_flat[:colors * 3] + [0] * (colors * 3 - min(len(pal_flat), colors * 3))
        palette = [tuple(pal_flat[i * 3:i * 3 + 3]) for i in range(colors)]
        palettes.append(palette)

        q_pixels = np.asarray(q)
        for i, (idx, col, row) in enumerate(tiles_in_cluster):
            index_img[row * TILE_PX_H:(row + 1) * TILE_PX_H, col * TILE_PX_W:(col + 1) * TILE_PX_W] = \
                q_pixels[i * TILE_PX_H:(i + 1) * TILE_PX_H, :]

    tile_palette_map = [int(tile_cluster[idx]) for idx, _, _ in iter_tiles_column_major()]
    return index_img, palettes, tile_palette_map, actual_k


def write_multi_palette_bmp(index_img: np.ndarray, palettes, tile_palette_map, out_path: str):
    """Extended format: standard BMP header/DIB, then all palettes back to
    back (palette 0 is what a normal BMP viewer would show, palettes 1..k-1
    ride along as extra biClrUsed entries most viewers ignore or mishandle -
    this file is meant for the patch's own decoder), then 4bpp pixel data
    (indices are tile-local, 0..colors-1 within whichever palette that
    tile's entry in tile_palette_map names), then one extra byte per tile
    (0..k-1, column-major) appended after the pixel data - purely custom,
    nothing in the standard BMP format accounts for it."""
    colors = len(palettes[0])
    k = len(palettes)

    row_bytes = (TARGET_W * 4 + 7) // 8
    rows = []
    for y in range(TARGET_H):
        row = bytearray(row_bytes)
        for x in range(TARGET_W):
            idx = int(index_img[y, x]) & 0x0F
            byte_i = x // 2
            if x % 2 == 0:
                row[byte_i] = (row[byte_i] & 0x0F) | (idx << 4)
            else:
                row[byte_i] = (row[byte_i] & 0xF0) | idx
        rows.append(bytes(row))
    pixel_data = b"".join(rows[::-1])

    pal_data = b"".join(
        struct.pack("<BBBB", b, g, r, 0)
        for palette in palettes
        for (r, g, b) in palette
    )

    dib_header_size = 40
    file_header_size = 14
    pixel_offset = file_header_size + dib_header_size + len(pal_data)
    tile_map_data = bytes(tile_palette_map)
    file_size = pixel_offset + len(pixel_data) + len(tile_map_data)

    file_header = struct.pack("<2sIHHI", b"BM", file_size, 0, 0, pixel_offset)
    dib_header = struct.pack(
        "<IiiHHIIiiII",
        dib_header_size,
        TARGET_W,
        TARGET_H,
        1,
        4,
        0,
        len(pixel_data),
        0, 0,
        colors * k,   # biClrUsed - total color entries across all palettes
        0,
    )

    with open(out_path, "wb") as f:
        f.write(file_header + dib_header + pal_data + pixel_data + tile_map_data)


def write_4bpp_bmp(img: Image.Image, out_path: str, colors: int):
    """img must already be exactly TARGET_W x TARGET_H, mode 'P' with a
    palette of <= `colors` entries (unused palette slots are zero-filled up
    to 16, since the console always reads exactly 16 palette entries)."""
    assert img.size == (TARGET_W, TARGET_H)
    assert img.mode == "P"

    pal = img.getpalette() or []
    # getpalette() returns a flat [R,G,B, R,G,B, ...] list, possibly shorter
    # than 16*3 entries; pad with black.
    pal = pal[: colors * 3] + [0] * (16 * 3 - min(len(pal), colors * 3))
    palette_entries = []
    for i in range(16):
        r, g, b = pal[i * 3 : i * 3 + 3] if i * 3 + 3 <= len(pal) else (0, 0, 0)
        palette_entries.append((r, g, b))

    row_bytes = (TARGET_W * 4 + 7) // 8  # 64, already a multiple of 4
    pixels = img.load()
    rows = []
    for y in range(TARGET_H):
        row = bytearray(row_bytes)
        for x in range(TARGET_W):
            idx = pixels[x, y] & 0x0F  # clamp defensively, palette has <=16 entries
            byte_i = x // 2
            if x % 2 == 0:
                row[byte_i] = (row[byte_i] & 0x0F) | (idx << 4)
            else:
                row[byte_i] = (row[byte_i] & 0xF0) | idx
        rows.append(bytes(row))
    pixel_data = b"".join(rows[::-1])  # BMP rows are bottom-up

    pal_data = b"".join(struct.pack("<BBBB", b, g, r, 0) for (r, g, b) in palette_entries)

    dib_header_size = 40
    file_header_size = 14
    pixel_offset = file_header_size + dib_header_size + len(pal_data)
    file_size = pixel_offset + len(pixel_data)

    file_header = struct.pack("<2sIHHI", b"BM", file_size, 0, 0, pixel_offset)
    dib_header = struct.pack(
        "<IiiHHIIiiII",
        dib_header_size,
        TARGET_W,
        TARGET_H,   # positive height = bottom-up
        1,          # biPlanes
        4,          # biBitCount
        0,          # biCompression (BI_RGB)
        len(pixel_data),
        0, 0,
        16,         # biClrUsed (console always reads 16 entries)
        0,
    )

    with open(out_path, "wb") as f:
        f.write(file_header + dib_header + pal_data + pixel_data)


def convert(input_path: str, output_path: str, fit: str, pad_color: str,
            dither: bool, colors: int, palettes: int):
    img = Image.open(input_path).convert("RGB")

    if fit == "stretch":
        img = fit_stretch(img)
    elif fit == "cover":
        img = fit_cover(img)
    elif fit == "blur":
        img = fit_blur(img)
    else:
        pad_rgb = tuple(int(pad_color[i:i + 2], 16) for i in (0, 2, 4))
        img = fit_contain(img, pad_rgb)

    # A mild sharpen before quantizing helps edges/text read as crisp rather
    # than "washed out" once color gets reduced down to 16-per-palette -
    # costs nothing on the hardware side, purely a source-image tweak.
    img = img.filter(ImageFilter.UnsharpMask(radius=2, percent=60, threshold=2))

    img = round_to_hardware_colorspace(img)

    if palettes <= 1:
        # MAXCOVERAGE (the original default) picks poorly for photographic /
        # gradient-heavy source art like box covers - it optimizes for
        # distinct region coverage rather than representative color, and
        # produced visibly worse skin tones/gradients than MEDIANCUT here.
        quantized = img.quantize(
            colors=colors,
            method=Image.MEDIANCUT,
            kmeans=8,
            dither=Image.FLOYDSTEINBERG if dither else Image.NONE,
        )
        write_4bpp_bmp(quantized, output_path, colors)
        size = os.path.getsize(output_path)
        print(f"OK: wrote {output_path} ({size} bytes, {colors} colors x 1 palette, fit={fit})")
    else:
        index_img, pals, tile_map, actual_k = quantize_multi_palette(img, palettes, colors, dither)
        write_multi_palette_bmp(index_img, pals, tile_map, output_path)
        size = os.path.getsize(output_path)
        print(f"OK: wrote {output_path} ({size} bytes, {colors} colors x {actual_k} palettes, fit={fit})")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("input", help="Source image (jpg/png/bmp/etc.)")
    parser.add_argument("output", nargs="?", default=None,
                         help="Output path (default: bg.bmp next to input)")
    parser.add_argument("--fit", choices=["stretch", "cover", "blur", "contain"], default="stretch")
    parser.add_argument("--pad-color", default="000000", help="RRGGBB hex, used with --fit contain")
    parser.add_argument("--no-dither", action="store_true")
    parser.add_argument("--colors", type=int, default=16, choices=range(2, 17), metavar="[2-16]")
    parser.add_argument("--palettes", type=int, default=8, choices=range(1, 17), metavar="[1-16]")
    args = parser.parse_args()

    if not os.path.isfile(args.input):
        print(f"Error: input file not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    output = args.output
    if output is None:
        output = os.path.join(os.path.dirname(os.path.abspath(args.input)), "bg.bmp")

    convert(args.input, output, args.fit, args.pad_color, not args.no_dither, args.colors, args.palettes)


if __name__ == "__main__":
    main()
