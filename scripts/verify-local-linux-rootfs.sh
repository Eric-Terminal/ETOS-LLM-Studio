#!/bin/bash
set -euo pipefail

ROOT_PATH=$(cd "$(dirname "$0")/.." && pwd -P)
ISH_SOURCE_PATH="$ROOT_PATH/Dependencies/ish-multiarch"
IOS_RESOURCE_PATH="$ROOT_PATH/ETOS LLM Studio/ETOS LLM Studio iOS App/Resources/LocalLinux"
WATCH_RESOURCE_PATH="$ROOT_PATH/ETOS LLM Studio/ETOS LLM Studio Watch App/Resources/LocalLinux"
ISH_REVISION=$(git -C "$ISH_SOURCE_PATH" rev-parse HEAD)

verify_pair() {
    local resource_path=$1
    local archive="$resource_path/ETOSLocalLinuxRootFSSeed.tar.gz"
    local metadata="$resource_path/ETOSLocalLinuxRootFSSeed.json"
    local migrations="$resource_path/ETOSLocalLinuxRootFSMigrations.json"
    local compliance="$resource_path/LocalLinuxRootFS-Compliance.json"

    [[ -f "$archive" && -f "$metadata" && -f "$migrations" && -f "$compliance" ]] || {
        echo "错误：缺少内置 RootFS 资源：$resource_path" >&2
        exit 1
    }
    python3 - "$archive" "$metadata" "$migrations" "$compliance" "$resource_path" "$ISH_REVISION" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
import tarfile

archive = Path(sys.argv[1])
metadata = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
migrations = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
compliance = json.loads(Path(sys.argv[4]).read_text(encoding="utf-8"))
resource_path = Path(sys.argv[5])
ish_revision = sys.argv[6]
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
if metadata.get("format") != "ish-rootfs-seed-archive-v1":
    raise SystemExit("错误：RootFS 资源清单格式无效。")
if metadata.get("guestArchitecture") != "aarch64":
    raise SystemExit("错误：RootFS 资源不是 AArch64 guest。")
if metadata.get("archiveSHA256") != digest:
    raise SystemExit("错误：RootFS 资源 SHA-256 与清单不一致。")
if metadata.get("archiveBytes") != archive.stat().st_size:
    raise SystemExit("错误：RootFS 资源大小与清单不一致。")
# 原生安装收据使用内部清单的上游摘要；外层压缩包摘要只校验分发文件。
with tarfile.open(archive, "r:gz") as seed_archive:
    seed_manifest_bytes = seed_archive.extractfile("rootfs-manifest.txt").read()
if hashlib.sha256(seed_manifest_bytes).hexdigest() != metadata.get("seedManifestSHA256"):
    raise SystemExit("错误：RootFS 内部清单摘要与资源清单不一致。")
seed_manifest = dict(
    line.split("=", 1)
    for line in seed_manifest_bytes.decode("utf-8").splitlines()
    if "=" in line
)
receipt_digest = seed_manifest.get("archive_sha256", "").lower()
if len(receipt_digest) != 64 or any(c not in "0123456789abcdef" for c in receipt_digest):
    raise SystemExit("错误：RootFS 内部清单的安装收据摘要无效。")
if metadata.get("upstreamArchiveSHA256", "").lower() != receipt_digest:
    raise SystemExit("错误：RootFS 安装收据摘要与 seed 内部清单不一致。")
if migrations.get("format") != "etos-rootfs-migrations-v1":
    raise SystemExit("错误：RootFS 迁移清单格式无效。")
if migrations.get("targetSeedSHA256", "").lower() != receipt_digest:
    raise SystemExit("错误：RootFS 迁移清单目标与安装收据摘要不一致。")
seen_ids = set()
seen_sources = set()
for migration in migrations.get("migrations", []):
    migration_id = migration.get("id")
    source = migration.get("fromSeedSHA256")
    target = migration.get("toSeedSHA256")
    script_name = migration.get("scriptFile")
    script_digest = migration.get("scriptSHA256")
    if (
        not isinstance(migration_id, str)
        or not migration_id
        or migration_id in seen_ids
        or not isinstance(source, str)
        or len(source) != 64
        or source in seen_sources
        or not isinstance(target, str)
        or len(target) != 64
        or source == target
        or not isinstance(script_name, str)
        or Path(script_name).name != script_name
        or not isinstance(script_digest, str)
        or len(script_digest) != 64
    ):
        raise SystemExit("错误：RootFS 迁移项无效。")
    seen_ids.add(migration_id)
    seen_sources.add(source)
    script = resource_path / script_name
    if not script.is_file() or hashlib.sha256(script.read_bytes()).hexdigest() != script_digest:
        raise SystemExit(f"错误：RootFS 迁移脚本摘要无效：{script_name}")
if compliance.get("format") != "etos-local-linux-compliance-v1":
    raise SystemExit("错误：RootFS 合规清单格式无效。")
if compliance.get("ishRevision") != ish_revision:
    raise SystemExit("错误：RootFS 合规清单与当前 ish-multiarch revision 不一致。")
for name, expected in compliance.get("resources", {}).items():
    path = resource_path / name
    if not path.is_file():
        raise SystemExit(f"错误：缺少 RootFS 合规资源：{name}")
    body = path.read_bytes()
    if expected.get("bytes") != len(body):
        raise SystemExit(f"错误：RootFS 合规资源大小不一致：{name}")
    if expected.get("sha256") != hashlib.sha256(body).hexdigest():
        raise SystemExit(f"错误：RootFS 合规资源摘要不一致：{name}")
sbom = json.loads((resource_path / "LocalLinuxRootFS-SBOM.spdx.json").read_text(encoding="utf-8"))
if sbom.get("spdxVersion") != "SPDX-2.3" or not sbom.get("packages"):
    raise SystemExit("错误：RootFS SPDX SBOM 无效。")
PY
}

verify_pair "$IOS_RESOURCE_PATH"
verify_pair "$WATCH_RESOURCE_PATH"

if ! cmp -s \
        "$IOS_RESOURCE_PATH/ETOSLocalLinuxRootFSSeed.tar.gz" \
        "$WATCH_RESOURCE_PATH/ETOSLocalLinuxRootFSSeed.tar.gz" ||
   ! cmp -s \
        "$IOS_RESOURCE_PATH/ETOSLocalLinuxRootFSSeed.json" \
        "$WATCH_RESOURCE_PATH/ETOSLocalLinuxRootFSSeed.json" ||
   ! diff -qr "$IOS_RESOURCE_PATH" "$WATCH_RESOURCE_PATH" >/dev/null; then
    echo "错误：iOS 与 watchOS 内置 RootFS 资源不一致。" >&2
    exit 1
fi

echo "内置 RootFS 资源校验通过。"
