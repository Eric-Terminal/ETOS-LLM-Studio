#!/usr/bin/env python3
"""生成 watchOS 离线文案包；原始翻译留在打包目录外，避免同时携带两份。"""

import argparse
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import zipfile


ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Localization/watchOS"
WATCH_APP = ROOT / "ETOS LLM Studio/ETOS LLM Studio Watch App"
DESTINATION = WATCH_APP / "Resources/Localizations"
LANGUAGES = ("en", "ja", "zh-Hans", "zh-Hant-HK", "ru", "fr", "es", "ar")


def read_translation(path: Path) -> dict[str, str]:
    result = subprocess.run(
        ["plutil", "-convert", "binary1", "-o", "-", str(path)],
        check=True, capture_output=True,
    )
    table = plistlib.loads(result.stdout)
    if not isinstance(table, dict) or not all(
        isinstance(key, str) and isinstance(value, str) for key, value in table.items()
    ):
        raise ValueError(f"文案表必须只包含字符串键值：{path}")
    return table


def compressed_table(table: dict[str, str]) -> bytes:
    payload = plistlib.dumps(table, fmt=plistlib.FMT_BINARY, sort_keys=True)
    output = io.BytesIO()
    # 固定时间、权限和键序，确保相同翻译在不同机器上生成相同资源。
    entry = zipfile.ZipInfo("Localizable.strings", date_time=(1980, 1, 1, 0, 0, 0))
    entry.compress_type = zipfile.ZIP_DEFLATED
    entry.external_attr = 0o100644 << 16
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(entry, payload, compresslevel=9)
    result = output.getvalue()
    with zipfile.ZipFile(io.BytesIO(result)) as archive:
        if plistlib.loads(archive.read("Localizable.strings")) != table:
            raise ValueError("文案压缩前后的键值不一致。")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="校验已提交资源，不写入文件")
    args = parser.parse_args()
    tables = {
        language: read_translation(SOURCES / f"{language}.lproj/Localizable.strings")
        for language in LANGUAGES
    }
    english_keys = set(tables["en"])
    # App Intents 元数据由系统在进程外读取，不能依赖运行时的 Bundle 覆盖。
    system_keys = json.loads((SOURCES / "system-keys.json").read_text(encoding="utf-8"))
    if not set(system_keys) <= english_keys:
        raise ValueError(f"系统入口缺少翻译：{sorted(set(system_keys) - english_keys)}")
    generated = {}
    original_size = 0
    native_size = 0
    for language, table in tables.items():
        if set(table) != english_keys:
            raise ValueError(f"{language} 的文案键与英语不一致，请先补齐翻译。")
        original_size += len(plistlib.dumps(table, fmt=plistlib.FMT_BINARY))
        if language == "en":
            # 英语保留原生格式，供语言资源加载前及缺失键回退使用。
            generated[WATCH_APP / "en.lproj/Localizable.strings"] = (
                SOURCES / "en.lproj/Localizable.strings"
            ).read_bytes()
        else:
            generated[DESTINATION / f"WatchLocalizable-{language}.zip"] = compressed_table(table)
            native = {key: table[key] for key in sorted(system_keys)}
            header = "// 由 scripts/prepare-watch-localizations.py 生成，仅供系统读取 App Intents 元数据。\n"
            text = header + "\n".join(
                f"{json.dumps(key, ensure_ascii=False)} = {json.dumps(value, ensure_ascii=False)};"
                for key, value in native.items()
            ) + "\n"
            generated[WATCH_APP / f"{language}.lproj/Localizable.strings"] = text.encode("utf-8")
            native_size += len(plistlib.dumps(native, fmt=plistlib.FMT_BINARY))

    # 原文误放回 target 会在下方被判为过期；额外语言目录也不能绕过校验。
    unexpected = [
        path for path in WATCH_APP.glob("*.lproj/Localizable.strings")
        if path not in generated
    ]
    if unexpected:
        raise ValueError(f"watchOS target 内存在未声明的原生文案：{unexpected}")
    outdated = [path for path, data in generated.items() if not path.exists() or path.read_bytes() != data]
    if args.check and outdated:
        raise ValueError("文案包需要更新，请运行 scripts/prepare-watch-localizations.py：\n" +
                         "\n".join(str(path.relative_to(ROOT)) for path in outdated))
    if not args.check:
        for path in outdated:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(generated[path])
    packaged_size = native_size + len(plistlib.dumps(tables["en"], fmt=plistlib.FMT_BINARY)) + sum(
        len(data) for path, data in generated.items() if path.suffix == ".zip"
    )
    print(f"watchOS 文案：{len(english_keys)} 个键，{len(tables)} 种离线语言，{len(system_keys)} 个原生系统入口键；"
          f"资源 {original_size:,} → {packaged_size:,} 字节，减少 {original_size - packaged_size:,} 字节。")
    print("已提交文案包校验通过。" if args.check else f"已更新 {len(outdated)} 个资源。")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"watchOS 文案处理失败：{error}", file=sys.stderr)
        sys.exit(1)
