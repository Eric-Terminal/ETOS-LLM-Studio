#!/usr/bin/env python3
"""生成字体回退回归使用的最小字体；不复制系统或第三方字形。

运行：uv run --with fonttools==4.66.1 python scripts/generate-font-test-fixtures.py
"""

from pathlib import Path

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen


destination = Path(__file__).resolve().parents[1] / "ETOSCore/ETOSCoreTests/Fixtures/Fonts"
destination.mkdir(parents=True, exist_ok=True)

for suffix, extra_characters, width in [
    ("Latin", "", 450),
    ("Mixed", "中文你好测试…", 850),
]:
    name = f"ELSFontFixture{suffix}"
    builder = FontBuilder(1000, isTTF=True)
    builder.setupGlyphOrder([".notdef", "space", "box"])
    mapping = {value: "box" for value in range(33, 127)}
    mapping.update({ord(character): "box" for character in extra_characters})
    mapping[32] = "space"
    builder.setupCharacterMap(mapping)
    pen = TTGlyphPen(None)
    pen.moveTo((50, 0))
    pen.lineTo((width - 50, 0))
    pen.lineTo((width - 50, 700))
    pen.lineTo((50, 700))
    pen.closePath()
    builder.setupGlyf({
        ".notdef": TTGlyphPen(None).glyph(),
        "space": TTGlyphPen(None).glyph(),
        "box": pen.glyph(),
    })
    builder.setupHorizontalMetrics({
        ".notdef": (width, 0), "space": (250, 0), "box": (width, 50),
    })
    builder.setupHorizontalHeader(ascent=800, descent=-200)
    builder.setupNameTable({
        "familyName": name,
        "styleName": "Regular",
        "uniqueFontIdentifier": name,
        "fullName": name,
        "psName": name,
        "version": "Version 1.0",
    })
    builder.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
    builder.setupPost()
    # 固定时间戳，使夹具在不同机器上重新生成时保持相同字节。
    builder.font.recalcTimestamp = False
    builder.font["head"].created = builder.font["head"].modified = 2082844800
    builder.save(destination / f"{name}.ttf")
