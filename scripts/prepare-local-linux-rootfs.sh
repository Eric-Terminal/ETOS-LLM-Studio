#!/bin/bash
set -euo pipefail

# 发布资源只由开发/发布流程生成；终端用户设备不会联网下载 RootFS。
ROOT_PATH=$(cd "$(dirname "$0")/.." && pwd -P)
ISH_SOURCE_PATH="$ROOT_PATH/Dependencies/ish-multiarch"
BUILD_ROOT="${ETOS_ROOTFS_BUILD_ROOT:-$ROOT_PATH/Dependencies/ish-build/rootfs}"
SEED_PATH="$BUILD_ROOT/seed"
ARCHIVE_PATH="$BUILD_ROOT/ETOSLocalLinuxRootFSSeed.tar.gz"
METADATA_PATH="$BUILD_ROOT/ETOSLocalLinuxRootFSSeed.json"
COMPLIANCE_PATH="$BUILD_ROOT/compliance"
IOS_RESOURCE_PATH="$ROOT_PATH/ETOS LLM Studio/ETOS LLM Studio iOS App/Resources/LocalLinux"
WATCH_RESOURCE_PATH="$ROOT_PATH/ETOS LLM Studio/ETOS LLM Studio Watch App/Resources/LocalLinux"

if [[ ! -x "$ISH_SOURCE_PATH/tools/apple-aarch64-rootfs.sh" ||
      ! -x "$ISH_SOURCE_PATH/tools/apple-rootfs-seed-archive.py" ||
      ! -f "$ROOT_PATH/scripts/generate-local-linux-compliance.py" ]]; then
    echo "错误：ish-multiarch 子模块未初始化或缺少 RootFS 打包工具。" >&2
    exit 1
fi

mkdir -p "$BUILD_ROOT" "$IOS_RESOURCE_PATH" "$WATCH_RESOURCE_PATH"
"$ISH_SOURCE_PATH/tools/apple-aarch64-rootfs.sh" "$SEED_PATH"
"$ISH_SOURCE_PATH/tools/apple-rootfs-seed-archive.py" \
    "$SEED_PATH" "$ARCHIVE_PATH" --metadata "$METADATA_PATH"
ISH_REVISION=$(git -C "$ISH_SOURCE_PATH" rev-parse HEAD)
rm -rf "$COMPLIANCE_PATH"
python3 "$ROOT_PATH/scripts/generate-local-linux-compliance.py" \
    --metadata "$METADATA_PATH" \
    --ish-root "$ISH_SOURCE_PATH" \
    --ish-revision "$ISH_REVISION" \
    --output "$COMPLIANCE_PATH"

for resource_path in "$IOS_RESOURCE_PATH" "$WATCH_RESOURCE_PATH"; do
    cp "$ARCHIVE_PATH" "$resource_path/ETOSLocalLinuxRootFSSeed.tar.gz"
    cp "$METADATA_PATH" "$resource_path/ETOSLocalLinuxRootFSSeed.json"
    cp "$COMPLIANCE_PATH"/* "$resource_path/"
done

echo "已更新 iOS/watchOS 内置 AArch64 RootFS seed。"
