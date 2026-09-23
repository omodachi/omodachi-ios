#!/usr/bin/env python3
"""STORE-2 §1. Renders the app icon from the brand's v6 symbol.

    python3 scripts/render_app_icon.py [--brand <path to v6-omodachi-symbol.svg>]

The source is `omodachi-brand/concepts/v6-omodachi-symbol.svg` — the same
outline `OmodachiSymbol.swift` draws, and the one the brand README names as the
standalone mark. Nothing here redraws it: the SVG's own `translate` and `d`
strings are read and filled with the even-odd rule the file declares.

Every step in that outline is an axis-aligned move on a 4-unit grid, so the
render is exact rather than anti-aliased: the 96-unit canvas is scaled by 7
(672 px, one grid unit = 28 px) and centred on 1024, which puts the 88-unit
glyph at 616 px — the size the brand's own wallpapers use for a standalone o.
A pixel is ink when its centre is inside the shape. The output is 8-bit RGB
with no alpha channel, because App Store Connect refuses an icon that has one.

Three files, one per appearance the asset catalog declares (Xcode 16+ reads
the dark and tinted ones on iOS 18+ and ignores them below):

  AppIcon.png         the brand's paper #faf7f2, ink #292b28   (index.html :root)
  AppIcon-dark.png    the brand's night #202321, ink #f5f2e9   (index.html [data-theme=night])
  AppIcon-tinted.png  white on black; the system tints the greyscale itself

Standard library only (no rsvg-convert, no Pillow), so it re-runs anywhere the
repository does. Run it again after the brand changes the symbol; the PNGs are
committed.
"""
from __future__ import annotations

import argparse
import os
import re
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_BRAND = os.path.join(ROOT, "..", "omodachi-brand", "concepts", "v6-omodachi-symbol.svg")
OUT = os.path.join(ROOT, "Omodachi", "Resources", "AppIcon.xcassets", "AppIcon.appiconset")

SIZE = 1024
VIEWBOX = 96
SCALE = 7
ORIGIN = (SIZE - VIEWBOX * SCALE) // 2  # 176

APPEARANCES = {
    "AppIcon.png": ("#faf7f2", "#292b28"),
    "AppIcon-dark.png": ("#202321", "#f5f2e9"),
    "AppIcon-tinted.png": ("#000000", "#ffffff"),
}


def parse_svg(path: str) -> tuple[tuple[int, int], list[list[tuple[int, int]]]]:
    with open(path, encoding="utf-8") as handle:
        source = handle.read()
    if 'viewBox="0 0 96 96"' not in source:
        sys.exit(f"{path}: expected a 96×96 viewBox")
    translate = re.search(r'id="symbol-o"[^>]*transform="translate\((\d+) (\d+)\)"', source)
    if not translate:
        sys.exit(f"{path}: no translate on #symbol-o")
    offset = (int(translate.group(1)), int(translate.group(2)))
    polygons: list[list[tuple[int, int]]] = []
    for d in re.findall(r'<path[^>]*\sd="([^"]+)"', source):
        for sub in re.findall(r"M[^M]+", d):
            tokens = re.findall(r"[MHVZ]|-?\d+", sub)
            if any(t.isalpha() and t not in "MHVZ" for t in tokens):
                sys.exit(f"{path}: only absolute M/H/V/Z are supported, got {sub!r}")
            points: list[tuple[int, int]] = []
            x = y = 0
            i = 0
            while i < len(tokens):
                op = tokens[i]
                if op == "M":
                    x, y = int(tokens[i + 1]), int(tokens[i + 2]); i += 3
                    points.append((x, y))
                elif op == "H":
                    x = int(tokens[i + 1]); i += 2
                    points.append((x, y))
                elif op == "V":
                    y = int(tokens[i + 1]); i += 2
                    points.append((x, y))
                elif op == "Z":
                    i += 1
                else:
                    sys.exit(f"{path}: unexpected token {op!r}")
            for px, py in points:
                if px % 4 or py % 4:
                    sys.exit(f"{path}: ({px}, {py}) is off the 4-unit grid; the exact render assumes it")
            polygons.append(points)
    if len(polygons) != 4:
        sys.exit(f"{path}: expected outline, counter and two eyes (4 subpaths), got {len(polygons)}")
    return offset, polygons


def inside(polygons: list[list[tuple[int, int]]], x: float, y: float) -> bool:
    """Even-odd: count the vertical edges a ray to the right crosses."""
    crossings = 0
    for poly in polygons:
        for (x1, y1), (x2, y2) in zip(poly, poly[1:] + poly[:1]):
            if x1 != x2:
                continue  # horizontal edges never cross a horizontal ray
            low, high = min(y1, y2), max(y1, y2)
            if low <= y < high and x1 > x:
                crossings += 1
    return crossings % 2 == 1


def colour(hex_value: str) -> bytes:
    return bytes(int(hex_value[i:i + 2], 16) for i in (1, 3, 5))


def mask(offset: tuple[int, int], polygons: list[list[tuple[int, int]]]) -> list[bytearray]:
    """One row per pixel row; 1 where the centre is ink. Evaluated per SVG unit
    cell (7×7 px) because the shape is constant inside each one."""
    cells = [[inside(polygons, (cx + 0.5) - offset[0], (cy + 0.5) - offset[1])
              for cx in range(VIEWBOX)] for cy in range(VIEWBOX)]
    rows = []
    for py in range(SIZE):
        row = bytearray(SIZE)
        cy = (py - ORIGIN) // SCALE
        if 0 <= py - ORIGIN < VIEWBOX * SCALE:
            for px in range(ORIGIN, ORIGIN + VIEWBOX * SCALE):
                if cells[cy][(px - ORIGIN) // SCALE]:
                    row[px] = 1
        rows.append(row)
    return rows


def png(rows: list[bytearray], background: str, ink: str) -> bytes:
    bg, fg = colour(background), colour(ink)
    raw = bytearray()
    for row in rows:
        raw.append(0)  # filter: none
        for value in row:
            raw += fg if value else bg

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)  # 8-bit RGB, no alpha
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--brand", default=DEFAULT_BRAND)
    parser.add_argument("--out", default=OUT)
    options = parser.parse_args()
    offset, polygons = parse_svg(os.path.abspath(options.brand))
    rows = mask(offset, polygons)
    os.makedirs(options.out, exist_ok=True)
    for name, (background, ink) in APPEARANCES.items():
        path = os.path.join(options.out, name)
        with open(path, "wb") as handle:
            handle.write(png(rows, background, ink))
        print(f"{path}: {SIZE}x{SIZE} RGB, background {background}, ink {ink}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
