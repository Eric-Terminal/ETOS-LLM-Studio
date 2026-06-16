#!/bin/sh
set -eu

# 禁用动态终端进度，避免构建日志残留 \r 刷新字符。
export TERM=dumb

ROOT_PATH="$(cd "$(dirname "$0")/.." && pwd)"
LLAMA_SOURCE_PATH="$ROOT_PATH/Dependencies/llama.cpp"
OUTPUT_ROOT="$ROOT_PATH/Dependencies/llama-build"
PRODUCT_ROOT="$OUTPUT_ROOT/products"

SDK_NAME="${SDK_NAME:-macosx}"
SDK_FAMILY="${PLATFORM_NAME:-}"
CONFIGURATION="${CONFIGURATION:-Release}"
REQUESTED_ARCHS="${ETOS_LLAMA_ARCHS:-${ARCHS:-${CURRENT_ARCH:-$(uname -m)}}}"
EXPLICIT_LLAMA_ARCHS=0
CMAKE_GENERATOR="Ninja"
CMAKE_BUILD_DIR_SUFFIX="ninja"
PARALLEL_BUILD="${ETOS_LLAMA_PARALLEL:-0}"
PARALLEL_JOBS="${ETOS_LLAMA_PARALLEL_JOBS:-}"

usage() {
    cat <<'EOF'
用法：build-llama-static-library.sh [--parallel[=线程数]] [--jobs 线程数] [-j线程数]

选项：
  --parallel        开启 CMake 多线程构建，默认使用本机 CPU 数。
  --parallel=线程数  开启 CMake 多线程构建，并指定线程数。
  --jobs 线程数      等同于 --parallel=线程数。
  -j 线程数          等同于 --parallel=线程数。
  -j线程数           等同于 --parallel=线程数。

环境变量：
  ETOS_LLAMA_PARALLEL=1       开启 CMake 多线程构建。
  ETOS_LLAMA_PARALLEL_JOBS=8  指定 CMake 构建线程数。

说明：
  脚本默认使用 Ninja 作为 CMake Generator；如果本机缺少 ninja，会尝试通过 Homebrew 安装。
  Ninja 默认会并行构建；--parallel 和 ETOS_LLAMA_PARALLEL_JOBS 只用于显式指定任务数。
EOF
}

default_parallel_jobs() {
    if command -v sysctl >/dev/null 2>&1; then
        jobs="$(sysctl -n hw.ncpu 2>/dev/null || true)"
        if [ -n "$jobs" ]; then
            printf '%s' "$jobs"
            return
        fi
    fi

    jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
    if [ -n "$jobs" ]; then
        printf '%s' "$jobs"
        return
    fi

    printf '2'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --parallel)
            PARALLEL_BUILD=1
            ;;
        --parallel=*)
            PARALLEL_BUILD=1
            PARALLEL_JOBS="${1#*=}"
            ;;
        --jobs=*)
            PARALLEL_BUILD=1
            PARALLEL_JOBS="${1#*=}"
            ;;
        --jobs|-j)
            if [ "$#" -lt 2 ]; then
                echo "$1 需要指定线程数。" >&2
                exit 2
            fi
            PARALLEL_BUILD=1
            shift
            PARALLEL_JOBS="$1"
            ;;
        -j*)
            PARALLEL_BUILD=1
            PARALLEL_JOBS="${1#-j}"
            ;;
        *)
            echo "未知参数：$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

case "$PARALLEL_BUILD" in
    1|true|TRUE|yes|YES|on|ON) PARALLEL_BUILD=1 ;;
    0|false|FALSE|no|NO|off|OFF|'') PARALLEL_BUILD=0 ;;
    *)
        echo "ETOS_LLAMA_PARALLEL 必须是 1/0、true/false、yes/no 或 on/off：$PARALLEL_BUILD" >&2
        exit 2
        ;;
esac

if [ -n "$PARALLEL_JOBS" ]; then
    PARALLEL_BUILD=1
fi

if [ "$PARALLEL_BUILD" = "1" ]; then
    if [ -z "$PARALLEL_JOBS" ]; then
        PARALLEL_JOBS="$(default_parallel_jobs)"
    fi

    case "$PARALLEL_JOBS" in
        ''|*[!0-9]*|0)
            echo "CMake 多线程构建线程数必须是正整数：$PARALLEL_JOBS" >&2
            exit 2
            ;;
    esac
fi

if [ -n "${ETOS_LLAMA_ARCHS:-}" ]; then
    EXPLICIT_LLAMA_ARCHS=1
fi

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

# 本地调试只需要当前目标架构；CI 和显式架构列表保留完整产物。
# Xcode 的脚本阶段可能只运行一次并把 CURRENT_ARCH 设为 undefined_arch。
# 这种情况下如果 ARCHS 是多架构，必须保留完整列表，否则后续链接会缺 slice。
if [ "$EXPLICIT_LLAMA_ARCHS" = "0" ] && [ "${CI_XCODE_CLOUD:-FALSE}" != "TRUE" ] && [ "${ETOS_LLAMA_FULL_ARCHS:-0}" != "1" ]; then
    if [ -n "${CURRENT_ARCH:-}" ] && [ "$CURRENT_ARCH" != "undefined_arch" ]; then
        case " $REQUESTED_ARCHS " in
            *" $CURRENT_ARCH "*) REQUESTED_ARCHS="$CURRENT_ARCH" ;;
        esac
    fi
fi

PRODUCT_CONFIGURATION="$CONFIGURATION"
LOCAL_LIGHTWEIGHT_DEBUG=0

# Xcode 仍按 Debug 目录找库，但本地 Debug 不需要 llama.cpp 的调试符号。
if [ -n "${ETOS_LLAMA_CMAKE_BUILD_TYPE:-}" ]; then
    CMAKE_BUILD_TYPE="$ETOS_LLAMA_CMAKE_BUILD_TYPE"
else
    case "$CONFIGURATION" in
        Debug)
            if [ "${CI_XCODE_CLOUD:-FALSE}" = "TRUE" ] || [ "${ETOS_LLAMA_DEBUG_SYMBOLS:-0}" = "1" ]; then
                CMAKE_BUILD_TYPE="Debug"
            else
                CMAKE_BUILD_TYPE="Release"
                LOCAL_LIGHTWEIGHT_DEBUG=1
            fi
            ;;
        Release) CMAKE_BUILD_TYPE="Release" ;;
        *) CMAKE_BUILD_TYPE="RelWithDebInfo" ;;
    esac
fi

case "$SDK_NAME" in
    *simulator*) PLATFORM_SUFFIX="simulator" ;;
    *) PLATFORM_SUFFIX="device" ;;
esac

METAL_ENABLED=ON
case "$SDK_NAME" in
    watchos*|watchsimulator*) METAL_ENABLED=OFF ;;
esac
LLAMA_WARNING_FLAGS="-Wno-ambiguous-macro -Wno-deprecated-declarations -Wno-documentation -Wno-shorten-64-to-32 -Wno-unreachable-code -Wno-unused-function -Wpointer-to-int-cast -Wint-to-pointer-cast"

PRODUCT_DIR="$PRODUCT_ROOT/$SDK_FAMILY-$PRODUCT_CONFIGURATION"
PRODUCT_LIBRARY="$PRODUCT_DIR/libetos-llama.a"
PRODUCT_STAMP="$PRODUCT_DIR/libetos-llama.stamp"
DEPLOYMENT_TARGET="default"
# 默认只保留最终链接库，避免 CMake 中间目录和单架构临时库长期占盘。
KEEP_CMAKE_BUILD="${ETOS_LLAMA_KEEP_CMAKE_BUILD:-0}"
KEEP_ARCH_PRODUCTS="${ETOS_LLAMA_KEEP_ARCH_PRODUCTS:-0}"

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

PRODUCT_SIGNATURE="sdk=$SDK_FAMILY product_config=$PRODUCT_CONFIGURATION cmake_config=$CMAKE_BUILD_TYPE generator=$CMAKE_GENERATOR archs=$REQUESTED_ARCHS deployment=$DEPLOYMENT_TARGET metal=$METAL_ENABLED warnings=$LLAMA_WARNING_FLAGS"

cleanup_intermediates() {
    if [ "$KEEP_CMAKE_BUILD" != "1" ]; then
        for arch in $REQUESTED_ARCHS; do
            rm -rf "$OUTPUT_ROOT/cmake/$SDK_FAMILY-$arch-$CMAKE_BUILD_TYPE-$CMAKE_BUILD_DIR_SUFFIX"
            rm -rf "$OUTPUT_ROOT/cmake/$SDK_FAMILY-$arch-$CMAKE_BUILD_TYPE"
        done
    fi

    if [ "$KEEP_ARCH_PRODUCTS" != "1" ]; then
        for arch in $REQUESTED_ARCHS; do
            rm -rf "$PRODUCT_ROOT/$SDK_FAMILY-$arch-$PRODUCT_CONFIGURATION"
        done
    fi
}

product_matches_archs() {
    [ -f "$PRODUCT_LIBRARY" ] || return 1
    [ -f "$PRODUCT_STAMP" ] || return 1
    [ "$(cat "$PRODUCT_STAMP")" = "$PRODUCT_SIGNATURE" ] || return 1

    product_archs="$(xcrun lipo -archs "$PRODUCT_LIBRARY" 2>/dev/null)" || return 1
    for arch in $REQUESTED_ARCHS; do
        case " $product_archs " in
            *" $arch "*) ;;
            *) return 1 ;;
        esac
    done

    return 0
}

if product_matches_archs; then
    cleanup_intermediates
    echo "llama.cpp 静态库已存在：$PRODUCT_LIBRARY"
    exit 0
fi

if [ "$LOCAL_LIGHTWEIGHT_DEBUG" = "1" ]; then
    echo "本地 Debug 使用 Release 编译 llama.cpp，避免生成调试符号。若需要调试 llama.cpp，请设置 ETOS_LLAMA_DEBUG_SYMBOLS=1。"
fi

if [ "$PARALLEL_BUILD" = "1" ]; then
    echo "CMake 多线程构建已开启：$PARALLEL_JOBS 个任务。"
fi

if ! command -v cmake >/dev/null 2>&1; then
    if [ "${CI_XCODE_CLOUD:-FALSE}" = "TRUE" ] || [ "${ETOS_LLAMA_INSTALL_CMAKE:-0}" = "1" ]; then
        if command -v brew >/dev/null 2>&1; then
            echo "未找到 cmake，正在通过 Homebrew 安装。"
            HOMEBREW_NO_AUTO_UPDATE=1 brew install cmake
        fi
    fi
fi

if ! command -v cmake >/dev/null 2>&1; then
    echo "未找到 cmake，请先运行 brew install cmake 后再构建 llama.cpp 静态库。" >&2
    exit 1
fi

if ! command -v ninja >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        echo "未找到 ninja，正在通过 Homebrew 安装。"
        HOMEBREW_NO_AUTO_UPDATE=1 brew install ninja
    fi
fi

# ninja 不可用时降级为 Unix Makefiles，避免 CI 环境 Homebrew 网络故障导致构建失败。
if command -v ninja >/dev/null 2>&1; then
    NINJA_PATH="$(command -v ninja)"
else
    echo "ninja 不可用，降级使用 Unix Makefiles。"
    CMAKE_GENERATOR="Unix Makefiles"
    CMAKE_BUILD_DIR_SUFFIX="make"
    NINJA_PATH=""
fi

SDK_PATH="$(xcrun --sdk "$SDK_NAME" --show-sdk-path)"
CC_PATH="$(xcrun --sdk "$SDK_NAME" --find clang)"
CXX_PATH="$(xcrun --sdk "$SDK_NAME" --find clang++)"

mkdir -p "$PRODUCT_DIR"

ARCH_PRODUCTS=""

for arch in $REQUESTED_ARCHS; do
    BUILD_DIR="$OUTPUT_ROOT/cmake/$SDK_FAMILY-$arch-$CMAKE_BUILD_TYPE-$CMAKE_BUILD_DIR_SUFFIX"
    ARCH_PRODUCT_DIR="$PRODUCT_ROOT/$SDK_FAMILY-$arch-$PRODUCT_CONFIGURATION"
    ARCH_PRODUCT_LIBRARY="$ARCH_PRODUCT_DIR/libetos-llama.a"
    ARCH_PRODUCT_STAMP="$ARCH_PRODUCT_DIR/libetos-llama.stamp"
    ARCH_SIGNATURE="sdk=$SDK_FAMILY product_config=$PRODUCT_CONFIGURATION cmake_config=$CMAKE_BUILD_TYPE generator=$CMAKE_GENERATOR arch=$arch deployment=$DEPLOYMENT_TARGET metal=$METAL_ENABLED warnings=$LLAMA_WARNING_FLAGS"

    if [ ! -f "$ARCH_PRODUCT_LIBRARY" ] ||
       [ ! -f "$ARCH_PRODUCT_STAMP" ] ||
       [ "$(cat "$ARCH_PRODUCT_STAMP")" != "$ARCH_SIGNATURE" ] ||
       ! xcrun lipo -verify_arch "$arch" "$ARCH_PRODUCT_LIBRARY" >/dev/null 2>&1; then
        mkdir -p "$BUILD_DIR" "$ARCH_PRODUCT_DIR"

        CMAKE_EXTRA_ARGS=""
        if [ -n "$NINJA_PATH" ]; then
            CMAKE_EXTRA_ARGS="-DCMAKE_MAKE_PROGRAM=$NINJA_PATH"
        fi

        cmake -S "$LLAMA_SOURCE_PATH" -B "$BUILD_DIR" -G "$CMAKE_GENERATOR" \
            -DCMAKE_BUILD_TYPE="$CMAKE_BUILD_TYPE" \
            -DCMAKE_SYSTEM_NAME="$CMAKE_SYSTEM_NAME" \
            $CMAKE_EXTRA_ARGS \
            -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
            -DCMAKE_OSX_ARCHITECTURES="$arch" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
            -DCMAKE_C_COMPILER="$CC_PATH" \
            -DCMAKE_CXX_COMPILER="$CXX_PATH" \
            -DCMAKE_C_FLAGS="-D_DARWIN_C_SOURCE=1 $LLAMA_WARNING_FLAGS" \
            -DCMAKE_CXX_FLAGS="-D_DARWIN_C_SOURCE=1 $LLAMA_WARNING_FLAGS" \
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

        if [ "$PARALLEL_BUILD" = "1" ]; then
            cmake --build "$BUILD_DIR" --config "$CMAKE_BUILD_TYPE" --target llama-common --parallel "$PARALLEL_JOBS"
        else
            cmake --build "$BUILD_DIR" --config "$CMAKE_BUILD_TYPE" --target llama-common
        fi

        set --
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
                set -- "$@" "$archive"
            fi
        done

        if [ "$#" -eq 0 ]; then
            echo "CMake 构建完成但没有找到静态库产物：$BUILD_DIR" >&2
            exit 1
        fi

        rm -f "$ARCH_PRODUCT_LIBRARY"
        xcrun libtool -static -o "$ARCH_PRODUCT_LIBRARY" "$@"
        printf '%s' "$ARCH_SIGNATURE" > "$ARCH_PRODUCT_STAMP"
    fi

    ARCH_PRODUCTS="${ARCH_PRODUCTS}${ARCH_PRODUCT_LIBRARY}
"
done

rm -f "$PRODUCT_LIBRARY"
if [ "$(printf '%s\n' "$REQUESTED_ARCHS" | wc -w | tr -d ' ')" = "1" ]; then
    first_arch_product="$(printf '%s' "$ARCH_PRODUCTS" | sed -n '1p')"
    cp "$first_arch_product" "$PRODUCT_LIBRARY"
else
    set --
    while IFS= read -r arch_product; do
        [ -n "$arch_product" ] || continue
        set -- "$@" "$arch_product"
    done <<EOF
$ARCH_PRODUCTS
EOF
    xcrun lipo -create "$@" -output "$PRODUCT_LIBRARY"
fi
printf '%s' "$PRODUCT_SIGNATURE" > "$PRODUCT_STAMP"
cleanup_intermediates

echo "已生成 llama.cpp 静态库：$PRODUCT_LIBRARY"
echo "构建平台：$SDK_FAMILY/$REQUESTED_ARCHS/$PLATFORM_SUFFIX/${PRODUCT_CONFIGURATION}，CMake=${CMAKE_BUILD_TYPE}，Generator=${CMAKE_GENERATOR}"
