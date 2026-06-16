#!/usr/bin/env python3
"""Generate MelammuPGothic-Regular.ttf from ipagp.ttf (IPA Pゴシック).

Purpose: the proportional dialog face for EngineProfile.narrowProportional
engines. IPAPGothic's kana are the narrowest of any redistributable JP gothic
(~0.90 em vs BIZ UDPGothic 0.93 em), which stops the worst fixed-size dialog
clipping — but two problems remain that this script fixes:

1. Digit width. Fixed-pitch dialog labels (e.g. the yaneurao settings dialog's
   RGB "255" scale) are laid out in DLUs sized for MS PGothic's 0.500 em
   half-width digits. IPAPGothic ships 0.630 em digits (ink up to 0.565 em), so
   "255" overflows its control and the leading digit clips. We condense ONLY the
   half-width digit glyphs (0-9) horizontally to a 0.500 em advance — the
   widest-ink digit ("4") scales ~0.81x — so digits match the MS PGothic metric
   the control expects. Kana / kanji / Latin letters are left untouched, so
   label text renders exactly like IPAPGothic.

2. Name collision. ipagp.ttf advertises family "IPA Pゴシック" on its Japanese
   (lid 0x0411 / Mac-JP) name records. A derivative that only renames the Latin
   records leaves that JP name in place, so under a Japanese-locale game two
   files claim "IPA Pゴシック" and Wine's face selection breaks — digits resolve
   by the Latin name but CJK glyphs fall back to a wider face, regressing the
   kana labels. We overwrite EVERY family / style / PostScript name record in
   all languages so the font is unambiguously "Melammu PGothic" with no IPA
   name anywhere.

xAvgCharWidth is left at IPA's value (956 = 0.467 em) on purpose: these dialog
controls are fixed-pixel (they do NOT scale with the dialog font's average
width — proven by BIZ UDP's larger xAvg clipping *more*, not less), so the only
lever that matters is glyph advance, which (1) handles.

License: IPA Pゴシック is under the IPA Font License v1.0, which permits
derivative works provided the derived program is distributed under the same
license, carries a different program name from the original (satisfied by the
rename above), and ships the license text
(wine-support/fonts/IPA_Font_License_Agreement_v1.0.txt).

Usage:
  .build/fonttools-venv/bin/python tools/make_melammu_pgothic.py [out.ttf]
"""

import sys
from pathlib import Path

from fontTools.ttLib import TTFont

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "wine-support/fonts/ipagp.ttf"
DST = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / "wine-support/fonts/MelammuPGothic-Regular.ttf"

FAMILY = "Melammu PGothic"
PSNAME = "MelammuPGothic-Regular"
# name IDs that carry family / style / PostScript identity. Copyright (0) and
# license (13/14) are kept verbatim as the IPA Font License requires.
FAMILY_IDS = {1, 16}
FULL_ID = 4
PS_ID = 6
UNIQUE_ID = 3
SUBFAMILY_IDS = {17}


def main() -> None:
    font = TTFont(SRC)
    upm = font["head"].unitsPerEm
    adv = upm // 2                  # 0.500 em — the MS PGothic half-width digit advance
    margin = round(0.022 * upm)     # small symmetric side bearing so digits don't touch
    cmap = font.getBestCmap()
    glyf = font["glyf"]
    hmtx = font["hmtx"]

    # 1. Condense half-width digits to a 0.500 em advance (shape preserved).
    for ch in "0123456789":
        gname = cmap[ord(ch)]
        g = glyf[gname]
        if getattr(g, "numberOfContours", 0) == 0:
            hmtx[gname] = (adv, hmtx[gname][1])
            continue
        if g.isComposite():
            continue
        g.expand(glyf)
        coords = g.coordinates
        xs = [p[0] for p in coords]
        xmin, xmax = min(xs), max(xs)
        ink = xmax - xmin
        scale = min(1.0, (adv - 2 * margin) / ink) if ink > 0 else 1.0
        target_xmin = (adv - ink * scale) / 2.0
        for i, (x, y) in enumerate(coords):
            coords[i] = (int(round(target_xmin + (x - xmin) * scale)), y)
        g.recalcBounds(glyf)
        hmtx[gname] = (adv, int(round(target_xmin)))

    # 2. Overwrite EVERY identity name record (all platforms / languages) so no
    #    "IPA Pゴシック" name survives to collide with ipagp.ttf in a JP locale.
    name = font["name"]
    for rec in name.names:
        if rec.nameID in FAMILY_IDS:
            rec.string = FAMILY
        elif rec.nameID == FULL_ID:
            rec.string = FAMILY
        elif rec.nameID == PS_ID:
            rec.string = PSNAME
        elif rec.nameID == UNIQUE_ID:
            rec.string = f"{PSNAME}-1.0"
        elif rec.nameID in SUBFAMILY_IDS:
            rec.string = "Regular"
    # Ensure the canonical Windows + Mac records exist even if absent in source.
    for nid, val in [(1, FAMILY), (4, FAMILY), (6, PSNAME), (16, FAMILY), (17, "Regular")]:
        name.setName(val, nid, 3, 1, 0x409)
        name.setName(val, nid, 1, 0, 0)

    if "DSIG" in font:           # signature invalidated by modification
        del font["DSIG"]

    font.save(DST)
    print(f"wrote {DST} ({DST.stat().st_size} bytes)")

    # Verify: no IPA name leftover, digits at 0.500 em.
    chk = TTFont(DST)
    leftover = sorted({
        r.toUnicode() for r in chk["name"].names
        if r.nameID in (1, 3, 4, 6, 16) and "IPA" in r.toUnicode()
    })
    cupm = chk["head"].unitsPerEm
    cmap2, hmtx2 = chk.getBestCmap(), chk["hmtx"]
    digits = sum(hmtx2[cmap2[ord(c)]][0] for c in "255") / cupm
    print(f"  family names: {sorted({r.toUnicode() for r in chk['name'].names if r.nameID == 1})}")
    print(f"  IPA leftover in identity names: {leftover or 'none'}")
    print(f"  '255' advance: {digits:.3f} em (target 1.500)")


if __name__ == "__main__":
    main()
