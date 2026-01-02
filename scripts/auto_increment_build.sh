#!/bin/bash

# 自动增加 Build 号
# 在 Scheme Pre-action 中运行，可以直接修改项目文件

# 获取脚本所在目录，从而定位工作空间根目录
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="$(dirname "$SCRIPT_DIR")"

# 如果在 Xcode 中运行，使用 SRCROOT 的上级目录
if [ -n "$SRCROOT" ]; then
    WORKSPACE_ROOT="$(dirname "$SRCROOT")"
fi

# 构建号文件
BUILD_NUMBER_FILE="${WORKSPACE_ROOT}/build_number.txt"

# 如果文件不存在，初始化为当前最大值
if [ ! -f "$BUILD_NUMBER_FILE" ]; then
    echo "17" > "$BUILD_NUMBER_FILE"
fi

# 读取当前 build 号
CURRENT_BUILD=$(cat "$BUILD_NUMBER_FILE")

# 增加 build 号
NEW_BUILD=$((CURRENT_BUILD + 1))

# 保存新的 build 号
echo "$NEW_BUILD" > "$BUILD_NUMBER_FILE"

# 更新所有项目的 CURRENT_PROJECT_VERSION
update_project() {
    local PROJECT_FILE="$1"
    if [ -f "$PROJECT_FILE" ]; then
        # 替换所有 CURRENT_PROJECT_VERSION
        sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = ${NEW_BUILD};/g" "$PROJECT_FILE"
        echo "📦 已更新: $(basename $(dirname "$PROJECT_FILE"))"
    else
        echo "⚠️  未找到: $PROJECT_FILE"
    fi
}

echo "🔍 工作空间: $WORKSPACE_ROOT"

# 更新 iOS 项目
update_project "${WORKSPACE_ROOT}/ETOS LLM Studio iOS App/ETOS LLM Studio iOS App.xcodeproj/project.pbxproj"

# 更新 watchOS 项目
update_project "${WORKSPACE_ROOT}/ETOS LLM Studio Watch App/ETOS LLM Studio Watch App.xcodeproj/project.pbxproj"

# 更新 Shared 项目
update_project "${WORKSPACE_ROOT}/Shared/Shared.xcodeproj/project.pbxproj"

echo "✅ Build 号: $CURRENT_BUILD → $NEW_BUILD"
