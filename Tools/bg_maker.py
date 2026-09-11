#!/usr/bin/env python3
"""
bg_maker.py - Converts any image into a bg.bmp for NeoSDLoader's custom
menu background feature (root bg.bmp, and per-game bg.bmp).

Output format (required by LoadCustomBG / LoadCustomBGSilent in
Patch/Patch0011/ui_bg.asm):
    - 320x224 pixels
    - 4 bits per pixel (16-color indexed palette)
    - Uncompressed (BI_RGB)
    - Standard 40-byte BITMAPINFOHEADER, bottom-up row order
    - 16-entry BGRA palette right after the header

Usage:
    python bg_maker.py <input_image> [output.bmp] [options]

If output.bmp is omitted, writes "bg.bmp" next to the input image.

Options:
    --fit {cover,contain}   How to fit the image into 320x224 (default: cover)
                            cover   = fill the whole frame, cropping overflow
                            contain = fit the whole image, padding with --pad-color
    --pad-color RRGGBB      Padding color for --fit contain (default: 000000)
    --no-dither             Disable dithering during 16-color quantization
    --colors N              Palette size, 2-16 (default: 16)

Examples:
    python bg_maker.py cover.jpg
    python bg_maker.py cover.jpg "D:\\SD\\SomeGame\\bg.bmp"
    python bg_maker.py screenshot.png --fit contain --pad-color 101018
"""
import argparse
import os
import struct
import sys

from PIL import Image

TARGET_W, TARGET_H = 320, 224


def fit_cover(img: Image.Image) -> Image.Image:
    src_w, src_h = img.size
    scale = max(TARGET_W / src_w, TARGET_H / src_h)
    new_w, new_h = round(src_w * scale), round(src_h * scale)
    img = img.resize((new_w, new_h), Image.LANCZOS)
    left = (new_w - TARGET_W) // 2
    top = (new_h - TARGET_H) // 2
    return img.crop((left, top, left + TARGET_W, top + TARGET_H))


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

    row_bytes = (TARGET_W * 4 + 7) // 8  # 160, already a multiple of 4
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
            dither: bool, colors: int):
    img = Image.open(input_path).convert("RGB")

    if fit == "cover":
        img = fit_cover(img)
    else:
        pad_rgb = tuple(int(pad_color[i:i + 2], 16) for i in (0, 2, 4))
        img = fit_contain(img, pad_rgb)

    quantized = img.quantize(
        colors=colors,
        method=Image.MEDIANCUT,
        dither=Image.FLOYDSTEINBERG if dither else Image.NONE,
    )

    write_4bpp_bmp(quantized, output_path, colors)
    size = os.path.getsize(output_path)
    print(f"OK: wrote {output_path} ({size} bytes, {colors} colors, fit={fit})")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("input", help="Source image (jpg/png/bmp/etc.)")
    parser.add_argument("output", nargs="?", default=None,
                         help="Output path (default: bg.bmp next to input)")
    parser.add_argument("--fit", choices=["cover", "contain"], default="cover")
    parser.add_argument("--pad-color", default="000000", help="RRGGBB hex, used with --fit contain")
    parser.add_argument("--no-dither", action="store_true")
    parser.add_argument("--colors", type=int, default=16, choices=range(2, 17), metavar="[2-16]")
    args = parser.parse_args()

    if not os.path.isfile(args.input):
        print(f"Error: input file not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    output = args.output
    if output is None:
        output = os.path.join(os.path.dirname(os.path.abspath(args.input)), "bg.bmp")

    convert(args.input, output, args.fit, args.pad_color, not args.no_dither, args.colors)


if __name__ == "__main__":
    main()
