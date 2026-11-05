"""Make chr/handwriting.chr (4 KB, one pattern table) from chr/calderon-handwriting.png.

Usage: python3 tools/make_handwriting.py chr/calderon-handwriting.png chr/base.chr chr/handwriting.chr chr/handwriting-preview.png

The PNG is a 16 x 7 grid of 8x8 tiles, white ink on black.
Each glyph goes to the tile number of its ASCII code ($20-$7E), in color 3.
Tile $7F is the bullet from base.chr. All other tiles are blank.
The PNG has no '=' or '`', so this script draws them.
The last row of the PNG (non-ASCII symbols) is not used.
"""
import struct
import sys
import zlib

# The character for each tile of the PNG, row by row. None = not used.
GRID = [
    "0123456789ABCDEF",
    "GHIJKLMNOPQRSTUV",
    "WXYZabcdefghijkl",
    "mnopqrstuvwxyz',",
    [".", "-", None, "!", "?", '"', None, ":", ";", "&", "*", "#", "~", "$", "%", "^"],
    ["@", "(", ")", "/", "+", "<", ">", "[", "]", "\\", "_", "{", "}", "|", None, None],
    [None] * 16,
]

# Glyphs that the PNG does not have. Same style as '-'.
EXTRA = {
    "=": ["........", "........", "..#####.", "........", "..#####.", "........", "........", "........"],
    "`": ["...#....", "....#...", "....#...", "........", "........", "........", "........", "........"],
}


def read_png(path):
    """Return (width, height, rows of RGBA tuples) for an 8-bit, non-interlaced PNG."""
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG file"
    pos, idat = 8, b""
    while pos < len(d):
        ln, = struct.unpack(">I", d[pos:pos + 4])
        typ, body = d[pos + 4:pos + 8], d[pos + 8:pos + 8 + ln]
        pos += 12 + ln
        if typ == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif typ == b"IDAT":
            idat += body
    assert depth == 8 and interlace == 0 and ctype in (0, 2, 4, 6), "unsupported PNG type"
    bpp = {0: 1, 2: 3, 4: 2, 6: 4}[ctype]
    raw, stride, rows, prev, i = zlib.decompress(idat), w * bpp, [], bytearray(w * bpp), 0
    for _ in range(h):
        f, line = raw[i], bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append([line[x * bpp] for x in range(w)])  # first channel: the gray level
        prev = line
    return w, h, rows


def encode(t):
    """8x8 color numbers (0-3) to 16 bytes of NES tile data."""
    p0 = bytes(sum(((t[y][x] & 1) << (7 - x)) for x in range(8)) for y in range(8))
    p1 = bytes(sum((((t[y][x] >> 1) & 1) << (7 - x)) for x in range(8)) for y in range(8))
    return p0 + p1


def decode(b):
    return [[((b[y] >> (7 - x)) & 1) | (((b[y + 8] >> (7 - x)) & 1) << 1) for x in range(8)] for y in range(8)]


def write_preview(path, tiles, scale=3):
    """A 16 x 6 grid of tiles $20-$7F, black ink on white."""
    w, h = 16 * 8 * scale, 6 * 8 * scale
    raw = b""
    for py in range(h):
        row = bytearray([0])
        for px in range(w):
            n = 0x20 + (py // (8 * scale)) * 16 + px // (8 * scale)
            c = tiles[n][(py // scale) % 8][(px // scale) % 8]
            row.append(0 if c else 255)
        raw += bytes(row)

    def chunk(k, data):
        return struct.pack(">I", len(data)) + k + data + struct.pack(">I", zlib.crc32(k + data))

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    open(path, "wb").write(png)


def main():
    src_png, base_chr, out_chr, out_png = sys.argv[1:5]
    w, h, px = read_png(src_png)
    assert (w, h) == (128, 56), f"expected 128 x 56 pixels, got {w} x {h}"

    tiles = [[[0] * 8 for _ in range(8)] for _ in range(256)]
    for ty, chars in enumerate(GRID):
        for tx, ch in enumerate(chars):
            if ch is None:
                continue
            tiles[ord(ch)] = [[3 if px[ty * 8 + y][tx * 8 + x] > 128 else 0 for x in range(8)] for y in range(8)]
    for ch, art in EXTRA.items():
        tiles[ord(ch)] = [[3 if c == "#" else 0 for c in r] for r in art]
    base = open(base_chr, "rb").read()
    tiles[0x7F] = decode(base[0x7F * 16:0x80 * 16])  # the bullet

    missing = [chr(n) for n in range(0x21, 0x7F) if not any(any(r) for r in tiles[n])]
    assert not missing, f"no glyph for {missing}"

    data = b"".join(encode(t) for t in tiles)
    assert len(data) == 4096
    open(out_chr, "wb").write(data)
    write_preview(out_png, tiles)


if __name__ == "__main__":
    main()
