#!/usr/bin/env python3
"""从主 App 的翻译生成各扩展实际使用的文案，避免完整文案库被重复打包。"""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
APP_ROOT = ROOT / "ETOS LLM Studio"
EXTENSIONS = {
    "ETOS Agent Watch Widgets": "ETOS LLM Studio Watch App",
    "ETOS Agent Widgets": "ETOS LLM Studio iOS App",
    "ETOS Agent Share": "ETOS LLM Studio iOS App",
    "ETOS Workspace Provider": "ETOS LLM Studio iOS App",
}
# 扩展会调用此文件中的共享存储和入口模型；其中新增的提示也必须进入扩展文案。
SHARED_SOURCES = [ROOT / "ETOSCore/ETOSCore/System/SystemEntrySharedModels.swift"]


def read_strings(path: Path) -> dict[str, str]:
    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(path)],
        check=True,
        capture_output=True,
    )
    return json.loads(result.stdout)


def required_keys(directory: Path) -> list[str]:
    # 使用 Xcode 自带的提取器处理 Swift 字符串转义和多行调用，避免自行解析源码。
    sources = sorted(directory.rglob("*.swift")) + SHARED_SOURCES
    with tempfile.TemporaryDirectory(prefix="etos-extension-localizations-") as output:
        result = subprocess.run(
            ["xcrun", "extractLocStrings", "-q", "-u", "-o", output,
             *[str(path) for path in sources]],
            check=True,
            capture_output=True,
            text=True,
        )
        if result.stderr.strip():
            raise ValueError(f"{directory.name} 文案提取需要处理：\n{result.stderr.strip()}")
        return sorted(read_strings(Path(output) / "Localizable.strings"))


def render_strings(keys: list[str], translations: dict[str, str]) -> str:
    lines = [
        "// 由 scripts/sync-extension-localizations.py 生成，请在对应主 App 中维护翻译。",
        "// 仅打包本扩展及其共享入口代码需要的文案，保留全部支持语言。",
        "",
    ]
    for key in keys:
        lines.append(
            f"{json.dumps(key, ensure_ascii=False)} = "
            f"{json.dumps(translations[key], ensure_ascii=False)};"
        )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="只检查已提交文案是否完整、最新，不写入文件")
    args = parser.parse_args()
    generated: dict[Path, str] = {}
    translations_cache: dict[Path, dict[str, str]] = {}
    summaries = []

    # 全部语言检查通过后再写入，避免缺少翻译时留下只更新一部分的资源。
    for extension, app in EXTENSIONS.items():
        destination = APP_ROOT / extension
        keys = required_keys(destination)
        languages = sorted((APP_ROOT / app).glob("*.lproj/Localizable.strings"))
        for source in languages:
            if source not in translations_cache:
                translations_cache[source] = read_strings(source)
            translations = translations_cache[source]
            missing = sorted(set(keys) - translations.keys())
            if missing:
                raise ValueError(f"{source.relative_to(ROOT)} 缺少 {extension} 的翻译：{missing}")
            generated[destination / source.parent.name / source.name] = render_strings(keys, translations)
        summaries.append(f"{extension}：{len(keys)} 个文案键，{len(languages)} 种语言")

    outdated = [
        path for path, content in generated.items()
        if not path.exists() or path.read_text(encoding="utf-8") != content
    ]
    if args.check and outdated:
        print("扩展文案尚未同步，请运行 python3 scripts/sync-extension-localizations.py：", file=sys.stderr)
        for path in outdated:
            print(f"  {path.relative_to(ROOT)}", file=sys.stderr)
        return 1
    if not args.check:
        for path in outdated:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(generated[path], encoding="utf-8")
    for summary in summaries:
        print(summary)
    print("扩展文案检查通过。" if args.check else f"已同步 {len(outdated)} 份扩展文案。")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"扩展文案处理失败：{error}", file=sys.stderr)
        sys.exit(1)
