#!/bin/sh
set -eu

# Xcode Cloud 的临时环境不会预装 iSH 构建链。把工具准备放在克隆后阶段，
# 避免进入原生静态库构建后才因缺少 Meson 或 Ninja 提前终止。
install_build_tool_if_needed() {
    tool_name="$1"

    if command -v "$tool_name" >/dev/null 2>&1; then
        echo "构建工具已可用：${tool_name}"
        return
    fi

    if ! command -v brew >/dev/null 2>&1; then
        echo "错误：缺少构建工具 ${tool_name}，且当前环境没有 Homebrew。" >&2
        exit 1
    fi

    echo "正在通过 Homebrew 安装构建工具：${tool_name}"
    HOMEBREW_NO_AUTO_UPDATE=1 brew install "$tool_name"

    if ! command -v "$tool_name" >/dev/null 2>&1; then
        echo "错误：Homebrew 安装完成后仍找不到构建工具 ${tool_name}。" >&2
        exit 1
    fi
}

llvm_supports_ish_vdso() {
    llvm_prefix="$(brew --prefix llvm 2>/dev/null || true)"
    [ -n "$llvm_prefix" ] || return 1
    llvm_clang="${llvm_prefix}/bin/clang"

    [ -x "$llvm_clang" ] || return 1
    printf '%s\n' \
        '#if !defined(__i386__) || !defined(__ELF__)' \
        '#error "缺少 iSH VDSO 所需的 i386 ELF 目标支持"' \
        '#endif' | "$llvm_clang" \
            -target i386-linux -fuse-ld=lld -shared -nostdlib \
            -x c - -o /dev/null >/dev/null 2>&1
}

install_llvm_toolchain_if_needed() {
    if ! command -v brew >/dev/null 2>&1; then
        echo "错误：构建 iSH VDSO 需要 Homebrew LLVM 与 LLD，但当前环境没有 Homebrew。" >&2
        exit 1
    fi

    if llvm_supports_ish_vdso; then
        echo "构建工具已可用：Homebrew LLVM（i386 ELF + LLD）"
        return
    fi

    # Homebrew 已把 LLD 从 llvm formula 拆出；lld formula 会同时拉取匹配版本的
    # LLVM，直接安装它可兼容全新环境和“已有 LLVM、缺少 LLD”两种情况。
    echo "正在通过 Homebrew 安装构建工具：LLVM + LLD"
    HOMEBREW_NO_AUTO_UPDATE=1 brew install lld

    if ! llvm_supports_ish_vdso; then
        echo "错误：Homebrew LLVM 与 LLD 安装完成后仍无法构建 iSH VDSO。" >&2
        exit 1
    fi
}

install_build_tool_if_needed meson
install_build_tool_if_needed ninja
install_llvm_toolchain_if_needed
