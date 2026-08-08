#!/bin/bash
set -euo pipefail

# iSH 的公共门禁一次生成 iOS/watchOS 七切片与 XCFramework；这里把可消费产物
# 收敛到 ETOS 的忽略目录，供本地构建与 Xcode Cloud 复用。
ROOT_PATH=$(cd "$(dirname "$0")/.." && pwd -P)
ISH_SOURCE_PATH="$ROOT_PATH/Dependencies/ish-multiarch"
OUTPUT_ROOT="${ETOS_ISH_BUILD_ROOT:-$ROOT_PATH/Dependencies/ish-build}"
GATE_ROOT="$OUTPUT_ROOT/apple-core"
PRODUCT_ROOT="$OUTPUT_ROOT/products"
XCFRAMEWORK_PATH="$OUTPUT_ROOT/iSHApple.xcframework"
STAMP_PATH="$OUTPUT_ROOT/iSHApple.stamp"

if [[ ! -f "$ISH_SOURCE_PATH/tools/apple-core-gate.sh" ]]; then
    echo "错误：ish-multiarch 子模块未初始化，请先执行 git submodule update --init --recursive。" >&2
    exit 1
fi

if ! command -v meson >/dev/null 2>&1; then
    echo "错误：构建 iSHApple 需要 Meson，请先安装 meson。" >&2
    exit 1
fi
if ! command -v ninja >/dev/null 2>&1; then
    echo "错误：构建 iSHApple 需要 Ninja，请先安装 ninja。" >&2
    exit 1
fi

ISH_REVISION=$(git -C "$ISH_SOURCE_PATH" rev-parse HEAD)
ISH_WORKTREE_FINGERPRINT=$(
    cd "$ISH_SOURCE_PATH"
    {
        git diff --binary HEAD --
        git ls-files --others --exclude-standard | LC_ALL=C sort | while IFS= read -r source_file; do
            [[ -f "$source_file" ]] || continue
            printf 'untracked:%s\n' "$source_file"
            shasum -a 256 "$source_file"
        done
    } | shasum -a 256 | awk '{print $1}'
)
XCODE_VERSION=$(xcodebuild -version | tr '\n' ' ')
SIGNATURE="ish=$ISH_REVISION worktree=$ISH_WORKTREE_FINGERPRINT xcode=$XCODE_VERSION gate=apple-core-v1"

products_are_current() {
    [[ -f "$STAMP_PATH" && "$(<"$STAMP_PATH")" == "$SIGNATURE" ]] || return 1
    [[ -f "$XCFRAMEWORK_PATH/Info.plist" ]] || return 1

    local platform
    for platform in iphoneos iphonesimulator watchos watchsimulator; do
        [[ -f "$PRODUCT_ROOT/$platform/libiSHApple.a" ]] || return 1
    done
}

if products_are_current && [[ "${ETOS_ISH_FORCE_REBUILD:-0}" != 1 ]]; then
    echo "iSHApple 公共产物已存在：$XCFRAMEWORK_PATH"
    exit 0
fi

mkdir -p "$OUTPUT_ROOT" "$PRODUCT_ROOT"
"$ISH_SOURCE_PATH/tools/apple-core-gate.sh" "$GATE_ROOT"

SOURCE_XCFRAMEWORK="$GATE_ROOT/xcframeworks/iSHApple.xcframework"
if [[ ! -f "$SOURCE_XCFRAMEWORK/Info.plist" ]]; then
    echo "错误：iSHApple 门禁没有生成公共 XCFramework。" >&2
    exit 1
fi

rm -rf "$XCFRAMEWORK_PATH"
ditto "$SOURCE_XCFRAMEWORK" "$XCFRAMEWORK_PATH"

copy_product() {
    local platform=$1
    local variant=$2
    local source="$SOURCE_XCFRAMEWORK/$variant/libiSHApple.a"
    local destination="$PRODUCT_ROOT/$platform"

    if [[ ! -f "$source" ]]; then
        echo "错误：iSHApple XCFramework 缺少 $variant 变体。" >&2
        exit 1
    fi
    mkdir -p "$destination"
    cp "$source" "$destination/libiSHApple.a"
}

copy_product iphoneos ios-arm64
copy_product iphonesimulator ios-arm64_x86_64-simulator
copy_product watchos watchos-arm64_arm64_32
copy_product watchsimulator watchos-arm64_x86_64-simulator

printf '%s' "$SIGNATURE" > "$STAMP_PATH"
echo "已生成 iSHApple XCFramework 与 ETOS 链接产物：$OUTPUT_ROOT"
