#!/usr/bin/env python3
"""Generate MelammuUDGothic-Regular.ttf from BIZUDGothic-Regular.ttf.

Purpose: a single-weight gothic family that mirrors MS Gothic's rendering
mechanics on Windows. Two ingredients:

1. Single-weight (Regular-only) family. MS Gothic has no real Bold face, so
   on Windows every Bold request is met by GDI synthetic bold (smearing) on
   the Regular outlines. Removing the Bold face reproduces that exactly:
   Regular request → plain Regular, Bold request → synthetic bold.

2. MS Gothic-compatible average char width (OS/2.xAvgCharWidth = 0.5 em).
   BIZ UD ships 0.8389 em. GDI scales glyphs horizontally by
   lfWidth / tmAveCharWidth when an engine requests a specific width
   (GIGA asks for condensed ＭＳ ゴシック: height -30, width 11), so an
   oversized average width over-compresses text vs Windows (0.44x instead
   of 0.73x). Metadata-only change; outlines and advances are untouched.

History: a Bold-outline base presented as Regular was tried because the Regular
base looked "too thin" — but that judgment was contaminated by the 0.44x
over-compression above. With the width fixed, the bold base rendered Regular
requests bolder than Windows (the engine's 太文字 setting defaults to off →
Regular requests). Regular base + width fix matched the Windows reference
screenshot and was confirmed readable.

The rename also avoids family-name collision with the macOS downloadable
asset "BIZ UDGothic" (which has a real Bold face and would defeat the
synthetic-bold behavior on Macs where that asset is active).

License: BIZ UDGothic is SIL OFL 1.1 with no Reserved Font Name, so a
renamed Modified Version may be redistributed under OFL with the original
copyright notice and license text (wine-support/fonts/OFL-BIZUD.txt).

Usage:
  .build/fonttools-venv/bin/python tools/make_melammu_gothic.py [regular|bold] [out.ttf]

Base selection ("regular" default) is kept for A/B experiments only.
"""

import sys
from pathlib import Path

from fontTools.ttLib import TTFont

REPO = Path(__file__).resolve().parent.parent
BASE = sys.argv[1] if len(sys.argv) > 1 else "regular"
SRC = REPO / f"wine-support/fonts/BIZUDGothic-{BASE.capitalize()}.ttf"
DST = Path(sys.argv[2]) if len(sys.argv) > 2 else REPO / "wine-support/fonts/MelammuUDGothic-Regular.ttf"

# (old, new) applied to family-identity name records in all languages.
# Order matters: family renames first, then the Bold→Regular style rename.
RENAMES = [
    ("BIZ UDPGothic", "Melammu UDGothic"),  # safety; not expected in this file
    ("BIZ UDGothic", "Melammu UDGothic"),
    ("BIZUDGothic", "MelammuUDGothic"),  # PostScript-style (no spaces)
    ("BIZ-UDGothic", "Melammu-UDGothic"),  # unique-ID style (hyphenated)
    ("BIZ UDゴシック", "Melammu UDGothic"),
    ("Bold", "Regular"),  # presented as the family's only (Regular) face
]
# name IDs that carry family/style identity. Copyright (0) and license (13/14)
# are kept verbatim as OFL requires. 2/17 are subfamily (style) names.
RENAME_IDS = {1, 2, 3, 4, 6, 16, 17, 21, 22}


def main() -> None:
    font = TTFont(SRC)

    for rec in font["name"].names:
        if rec.nameID not in RENAME_IDS:
            continue
        text = rec.toUnicode()
        for old, new in RENAMES:
            text = text.replace(old, new)
        if rec.nameID == 6:  # PostScript name: no spaces allowed
            text = text.replace(" ", "")
        rec.string = text

    os2 = font["OS/2"]
    head = font["head"]
    # Present the bold outlines as the Regular face so GDI/Wine treat Bold
    # requests as unsatisfied and synthesize bold on top.
    os2.usWeightClass = 400
    os2.fsSelection = (os2.fsSelection & ~0x21) | 0x40  # clear BOLD|ITALIC, set REGULAR
    head.macStyle &= ~0x3  # clear bold/italic bits
    # MS Gothic-compatible average width (see module docstring, ingredient 2).
    os2.xAvgCharWidth = head.unitsPerEm // 2

    # The digital signature is invalidated by modification.
    if "DSIG" in font:
        del font["DSIG"]

    font.save(DST)
    print(f"wrote {DST} ({DST.stat().st_size} bytes)")

    check = TTFont(DST)
    for nid in (1, 2, 4, 6, 16, 17):
        rec = check["name"].getDebugName(nid)
        print(f"  nameID {nid}: {rec}")
    cos2, chead = check["OS/2"], check["head"]
    print(f"  usWeightClass={cos2.usWeightClass} fsSelection={cos2.fsSelection:#06x} "
          f"macStyle={chead.macStyle:#04x} xAvgCharWidth={cos2.xAvgCharWidth} "
          f"({cos2.xAvgCharWidth / chead.unitsPerEm:.4f}em)")


if __name__ == "__main__":
    main()
