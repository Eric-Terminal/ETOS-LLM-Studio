#!/bin/sh
set -eu

ROOT_PATH="$(cd "$(dirname "$0")/.." && pwd)"
LLAMA_SOURCE_PATH="$ROOT_PATH/Dependencies/llama.cpp"
OUTPUT_ROOT="$ROOT_PATH/Dependencies/llama-build"
PRODUCT_ROOT="$OUTPUT_ROOT/products"

SDK_NAME="${SDK_NAME:-macosx}"
SDK_FAMILY="${PLATFORM_NAME:-}"
CONFIGURATION="${CONFIGURATION:-Release}"
REQUESTED_ARCHS="${ETOS_LLAMA_ARCHS:-${ARCHS:-${CURRENT_ARCH:-$(uname -m)}}}"

if [ "$REQUESTED_ARCHS" = "undefined_arch" ] || [ -z "$REQUESTED_ARCHS" ]; then
    REQUESTED_ARCHS="$(uname -m)"
fi

if [ -z "$SDK_FAMILY" ]; then
    SDK_FAMILY="$(printf '%s' "$SDK_NAME" | sed 's/[0-9.]*$//')"
fi

case "$SDK_NAME" in
    iphoneos*) CMAKE_SYSTEM_NAME="iOS" ;;
    iphonesimulator*) CMAKE_SYSTEM_NAME="iOS" ;;
    macosx*) CMAKE_SYSTEM_NAME="Darwin" ;;
    xros*) CMAKE_SYSTEM_NAME="visionOS" ;;
    xrsimulator*) CMAKE_SYSTEM_NAME="visionOS" ;;
    watchos*) CMAKE_SYSTEM_NAME="watchOS" ;;
    watchsimulator*) CMAKE_SYSTEM_NAME="watchOS" ;;
    *) CMAKE_SYSTEM_NAME="Darwin" ;;
esac

case "$CONFIGURATION" in
    Debug) CMAKE_BUILD_TYPE="Debug" ;;
    Release) CMAKE_BUILD_TYPE="Release" ;;
    *) CMAKE_BUILD_TYPE="RelWithDebInfo" ;;
esac

case "$SDK_NAME" in
    *simulator*) PLATFORM_SUFFIX="simulator" ;;
    *) PLATFORM_SUFFIX="device" ;;
esac

METAL_ENABLED=ON
case "$SDK_NAME" in
    watchos*|watchsimulator*) METAL_ENABLED=OFF ;;
esac

PRODUCT_DIR="$PRODUCT_ROOT/$SDK_FAMILY-$CMAKE_BUILD_TYPE"
PRODUCT_LIBRARY="$PRODUCT_DIR/libetos-llama.a"
PRODUCT_STAMP="$PRODUCT_DIR/libetos-llama.stamp"
DEPLOYMENT_TARGET="default"

case "$SDK_FAMILY" in
    iphoneos|iphonesimulator)
        DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
        ;;
    macosx)
        DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
        ;;
    xros|xrsimulator)
        DEPLOYMENT_TARGET="${XROS_DEPLOYMENT_TARGET:-1.0}"
        ;;
    watchos|watchsimulator)
        DEPLOYMENT_TARGET="${WATCHOS_DEPLOYMENT_TARGET:-10.0}"
        ;;
esac

PRODUCT_SIGNATURE="sdk=$SDK_FAMILY config=$CMAKE_BUILD_TYPE archs=$REQUESTED_ARCHS deployment=$DEPLOYMENT_TARGET metal=$METAL_ENABLED"

product_matches_archs() {
    [ -f "$PRODUCT_LIBRARY" ] || return 1
    [ -f "$PRODUCT_STAMP" ] || return 1
    [ "$(cat "$PRODUCT_STAMP")" = "$PRODUCT_SIGNATURE" ] || return 1

    product_archs="$(xcrun lipo -archs "$PRODUCT_LIBRARY")"
    for arch in $REQUESTED_ARCHS; do
        case " $product_archs " in
            *" $arch "*) ;;
            *) return 1 ;;
        esac
    done

    return 0
}

if product_matches_archs; then
    echo "llama.cpp 静态库已存在：$PRODUCT_LIBRARY"
    exit 0
fi

if ! command -v cmake >/dev/null 2>&1; then
    if [ "${CI_XCODE_CLOUD:-FALSE}" = "TRUE" ] || [ "${ETOS_LLAMA_INSTALL_CMAKE:-0}" = "1" ]; then
        if command -v brew >/dev/null 2>&1; then
            echo "未找到 cmake，正在通过 Homebrew 安装。"
            brew install cmake
        fi
    fi
fi

if ! command -v cmake >/dev/null 2>&1; then
    echo "未找到 cmake，请先运行 brew install cmake 后再构建 llama.cpp 静态库。" >&2
    exit 1
fi

SDK_PATH="$(xcrun --sdk "$SDK_NAME" --show-sdk-path)"
CC_PATH="$(xcrun --sdk "$SDK_NAME" --find clang)"
CXX_PATH="$(xcrun --sdk "$SDK_NAME" --find clang++)"

mkdir -p "$PRODUCT_DIR"

ARCH_PRODUCTS=""

for arch in $REQUESTED_ARCHS; do
    BUILD_DIR="$OUTPUT_ROOT/cmake/$SDK_FAMILY-$arch-$CMAKE_BUILD_TYPE"
    ARCH_PRODUCT_DIR="$PRODUCT_ROOT/$SDK_FAMILY-$arch-$CMAKE_BUILD_TYPE"
    ARCH_PRODUCT_LIBRARY="$ARCH_PRODUCT_DIR/libetos-llama.a"
    ARCH_PRODUCT_STAMP="$ARCH_PRODUCT_DIR/libetos-llama.stamp"
    ARCH_SIGNATURE="sdk=$SDK_FAMILY config=$CMAKE_BUILD_TYPE arch=$arch deployment=$DEPLOYMENT_TARGET metal=$METAL_ENABLED"

    if [ ! -f "$ARCH_PRODUCT_LIBRARY" ] || [ ! -f "$ARCH_PRODUCT_STAMP" ] || [ "$(cat "$ARCH_PRODUCT_STAMP")" != "$ARCH_SIGNATURE" ]; then
        mkdir -p "$BUILD_DIR" "$ARCH_PRODUCT_DIR"

        cmake -S "$LLAMA_SOURCE_PATH" -B "$BUILD_DIR" \
            -DCMAKE_BUILD_TYPE="$CMAKE_BUILD_TYPE" \
            -DCMAKE_SYSTEM_NAME="$CMAKE_SYSTEM_NAME" \
            -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
            -DCMAKE_OSX_ARCHITECTURES="$arch" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
            -DCMAKE_C_COMPILER="$CC_PATH" \
            -DCMAKE_CXX_COMPILER="$CXX_PATH" \
            -DCMAKE_C_FLAGS="-D_DARWIN_C_SOURCE=1" \
            -DCMAKE_CXX_FLAGS="-D_DARWIN_C_SOURCE=1" \
            -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
            -DBUILD_SHARED_LIBS=OFF \
            -DLLAMA_BUILD_COMMON=ON \
            -DLLAMA_BUILD_TESTS=OFF \
            -DLLAMA_BUILD_TOOLS=OFF \
            -DLLAMA_BUILD_EXAMPLES=OFF \
            -DLLAMA_BUILD_SERVER=OFF \
            -DLLAMA_BUILD_APP=OFF \
            -DLLAMA_BUILD_UI=OFF \
            -DLLAMA_OPENSSL=OFF \
            -DGGML_NATIVE=OFF \
            -DGGML_OPENMP=OFF \
            -DGGML_BLAS=OFF \
            -DGGML_ACCELERATE=ON \
            -DGGML_LLAMAFILE=OFF \
            -DGGML_METAL="$METAL_ENABLED" \
            -DGGML_METAL_EMBED_LIBRARY="$METAL_ENABLED" \
            -DGGML_CCACHE=OFF

        cmake --build "$BUILD_DIR" --config "$CMAKE_BUILD_TYPE" --target llama-common

        ARCHIVES=""
        for archive in \
            "$BUILD_DIR/src/libllama.a" \
            "$BUILD_DIR/common/libllama-common.a" \
            "$BUILD_DIR/common/libllama-common-base.a" \
            "$BUILD_DIR/ggml/src/libggml.a" \
            "$BUILD_DIR/ggml/src/libggml-base.a" \
            "$BUILD_DIR/ggml/src/libggml-cpu.a" \
            "$BUILD_DIR/ggml/src/ggml-metal/libggml-metal.a" \
            "$BUILD_DIR/vendor/cpp-httplib/libcpp-httplib.a"; do
            if [ -f "$archive" ]; then
                ARCHIVES="$ARCHIVES $archive"
            fi
        done

        if [ -z "$ARCHIVES" ]; then
            echo "CMake 构建完成但没有找到静态库产物：$BUILD_DIR" >&2
            exit 1
        fi

        rm -f "$ARCH_PRODUCT_LIBRARY"
        xcrun libtool -static -o "$ARCH_PRODUCT_LIBRARY" $ARCHIVES
        printf '%s' "$ARCH_SIGNATURE" > "$ARCH_PRODUCT_STAMP"
    fi

    ARCH_PRODUCTS="$ARCH_PRODUCTS $ARCH_PRODUCT_LIBRARY"
done

rm -f "$PRODUCT_LIBRARY"
if [ "$(printf '%s\n' "$REQUESTED_ARCHS" | wc -w | tr -d ' ')" = "1" ]; then
    cp $ARCH_PRODUCTS "$PRODUCT_LIBRARY"
else
    xcrun lipo -create $ARCH_PRODUCTS -output "$PRODUCT_LIBRARY"
fi
printf '%s' "$PRODUCT_SIGNATURE" > "$PRODUCT_STAMP"

echo "已生成 llama.cpp 静态库：$PRODUCT_LIBRARY"
echo "构建平台：$SDK_FAMILY/$REQUESTED_ARCHS/$PLATFORM_SUFFIX/$CMAKE_BUILD_TYPE"
