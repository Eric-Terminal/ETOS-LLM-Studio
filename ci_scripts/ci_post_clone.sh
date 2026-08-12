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

install_build_tool_if_needed meson
install_build_tool_if_needed ninja
