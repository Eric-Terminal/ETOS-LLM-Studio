#!/bin/sh
set -eu

# 为 Xcode 准备当前 SDK/Configuration 的原生静态依赖。llama 与 iSH 各自由
# 专属脚本构建；这里只负责把独立产物并列放入既有的 Xcode 库搜索目录。
ROOT_PATH="$(cd "$(dirname "$0")/.." && pwd)"
SDK_NAME="${SDK_NAME:-macosx}"
SDK_FAMILY="${PLATFORM_NAME:-}"
CONFIGURATION="${CONFIGURATION:-Release}"
REQUESTED_ARCHS="${ETOS_LLAMA_ARCHS:-${ARCHS:-${CURRENT_ARCH:-$(uname -m)}}}"

if [ -z "$SDK_FAMILY" ]; then
    SDK_FAMILY="$(printf '%s' "$SDK_NAME" | sed 's/[0-9.]*$//')"
fi
if [ "$REQUESTED_ARCHS" = "undefined_arch" ] || [ -z "$REQUESTED_ARCHS" ]; then
    REQUESTED_ARCHS="$(uname -m)"
fi

case "$SDK_FAMILY" in
    iphoneos|iphonesimulator|watchos|watchsimulator)
        "$ROOT_PATH/scripts/build-ish-static-library.sh"
        ;;
esac

"$ROOT_PATH/scripts/build-llama-static-library.sh" "$@"

case "$SDK_FAMILY" in
    iphoneos|iphonesimulator|watchos|watchsimulator)
        SOURCE_ISH_LIBRARY="$ROOT_PATH/Dependencies/ish-build/products/$SDK_FAMILY/libiSHApple.a"
        PRODUCT_DIR="$ROOT_PATH/Dependencies/llama-build/products/$SDK_FAMILY-$CONFIGURATION"
        LLAMA_LIBRARY="$PRODUCT_DIR/libetos-llama.a"
        STAGED_ISH_LIBRARY="$PRODUCT_DIR/libiSHApple.a"

        if [ ! -f "$SOURCE_ISH_LIBRARY" ]; then
            echo "iSHApple 构建完成但没有找到平台产物：$SOURCE_ISH_LIBRARY" >&2
            exit 1
        fi
        mkdir -p "$PRODUCT_DIR"
        if ! cmp -s "$SOURCE_ISH_LIBRARY" "$STAGED_ISH_LIBRARY"; then
            cp "$SOURCE_ISH_LIBRARY" "$STAGED_ISH_LIBRARY"
        fi

        for arch in $REQUESTED_ARCHS; do
            if ! xcrun lipo "$STAGED_ISH_LIBRARY" -verify_arch "$arch" >/dev/null 2>&1; then
                echo "iSHApple 独立静态库缺少架构 ${arch}：$STAGED_ISH_LIBRARY" >&2
                exit 1
            fi
        done
        if xcrun nm -g "$LLAMA_LIBRARY" 2>/dev/null | grep -q ' _ish_apple_'; then
            echo "libetos-llama.a 不得包含 iSHApple 公共符号。" >&2
            exit 1
        fi
        if ! xcrun nm -g "$STAGED_ISH_LIBRARY" 2>/dev/null |
                grep -q ' _ish_apple_runtime_start_v2$'; then
            echo "libiSHApple.a 缺少 runtime 公共入口。" >&2
            exit 1
        fi
        echo "iSHApple 独立静态库已就绪：$STAGED_ISH_LIBRARY"
        ;;
esac
