#!/bin/sh
set -eu

# 仅在 Xcode Cloud 环境优先使用官方仓库路径，便于脚本在云端与本地都可运行。
ROOT_PATH="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
IOS_PLIST_PATH="$ROOT_PATH/ETOS LLM Studio/Config/iOSInfo.plist"
WATCH_PLIST_PATH="$ROOT_PATH/ETOS LLM Studio/ETOS LLM Studio Watch App/Info.plist"

# 云端构建优先写入 CI_COMMIT 的短哈希，本地调试保留默认占位。
if [ -n "${CI_COMMIT:-}" ]; then
    COMMIT_HASH="$(printf '%s' "$CI_COMMIT" | cut -c1-7)"
else
    COMMIT_HASH="LocalBuild"
fi

write_commit_hash() {
    plist_path="$1"

    if [ ! -f "$plist_path" ]; then
        echo "未找到 plist 文件：$plist_path"
        exit 1
    fi

    if /usr/libexec/PlistBuddy -c "Print :ETCommitHash" "$plist_path" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :ETCommitHash $COMMIT_HASH" "$plist_path"
    else
        /usr/libexec/PlistBuddy -c "Add :ETCommitHash string $COMMIT_HASH" "$plist_path"
    fi

    echo "已写入 ETCommitHash=$COMMIT_HASH -> $plist_path"
}

write_commit_hash "$IOS_PLIST_PATH"
write_commit_hash "$WATCH_PLIST_PATH"

export CONFIGURATION="${CONFIGURATION:-Release}"

build_llama_static_library() {
    sdk_name="$1"
    archs="$2"

    echo "预构建 llama.cpp 静态库：$sdk_name / $archs / $CONFIGURATION"
    SDK_NAME="$sdk_name" ARCHS="$archs" "$ROOT_PATH/scripts/build-llama-static-library.sh"
}

# Xcode Cloud 只用于发布归档，预构建发布包实际会链接的设备 slice。
build_llama_static_library iphoneos arm64
build_llama_static_library watchos arm64
