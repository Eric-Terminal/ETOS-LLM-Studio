#!/usr/bin/env python3

"""为内置 Alpine RootFS 生成可复核的许可与 SBOM 伴随资源。"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="生成 ETOS 内置 RootFS 合规资源")
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--ish-root", type=Path, required=True)
    parser.add_argument("--ish-revision", required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(64 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def read_packages(path: Path) -> list[dict[str, str]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    expected = "package\tversion\torigin\tlicense\taports_commit"
    if not lines or lines[0] != expected:
        raise SystemExit("错误：Alpine package lock 表头无效。")
    packages = []
    for line in lines[1:]:
        fields = line.split("\t")
        if len(fields) != 5 or any(not field for field in fields):
            raise SystemExit("错误：Alpine package lock 数据无效。")
        packages.append(dict(zip(expected.split("\t"), fields)))
    if not packages:
        raise SystemExit("错误：Alpine package lock 不能为空。")
    return packages


def write_json(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def make_sbom(
    metadata: dict[str, object],
    packages: list[dict[str, str]],
    revision: str,
) -> dict[str, object]:
    namespace_digest = hashlib.sha256(
        f"{metadata['archiveSHA256']}:{revision}".encode("utf-8")
    ).hexdigest()
    rootfs_id = "SPDXRef-ETOS-Local-Linux-RootFS"
    spdx_packages: list[dict[str, object]] = [
        {
            "SPDXID": rootfs_id,
            "name": "ETOS Local Linux RootFS Seed",
            "versionInfo": metadata["alpineVersion"],
            "downloadLocation": metadata["sourceURL"],
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "checksums": [
                {
                    "algorithm": "SHA256",
                    "checksumValue": metadata["archiveSHA256"],
                }
            ],
        }
    ]
    relationships: list[dict[str, str]] = []
    for index, package in enumerate(packages, start=1):
        package_id = f"SPDXRef-Alpine-Package-{index}"
        spdx_packages.append(
            {
                "SPDXID": package_id,
                "name": package["package"],
                "versionInfo": package["version"],
                "downloadLocation": "NOASSERTION",
                "filesAnalyzed": False,
                "licenseConcluded": "NOASSERTION",
                "licenseDeclared": package["license"],
                "supplier": "Organization: Alpine Linux",
                "externalRefs": [
                    {
                        "referenceCategory": "PACKAGE-MANAGER",
                        "referenceType": "purl",
                        "referenceLocator": (
                            f"pkg:apk/alpine/{package['package']}@{package['version']}"
                            "?arch=aarch64"
                        ),
                    }
                ],
                "annotations": [
                    {
                        "annotationType": "OTHER",
                        "annotator": "Tool: ETOS compliance generator",
                        "annotationDate": "1970-01-01T00:00:00Z",
                        "comment": (
                            f"origin={package['origin']};"
                            f"aports_commit={package['aports_commit']}"
                        ),
                    }
                ],
            }
        )
        relationships.append(
            {
                "spdxElementId": rootfs_id,
                "relationshipType": "CONTAINS",
                "relatedSpdxElement": package_id,
            }
        )
    return {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": "ETOS-Local-Linux-RootFS-SBOM",
        "documentNamespace": f"https://github.com/Eric-Terminal/ETOS-LLM-Studio/spdx/{namespace_digest}",
        "creationInfo": {
            "created": "1970-01-01T00:00:00Z",
            "creators": ["Tool: ETOS compliance generator"],
        },
        "documentDescribes": [rootfs_id],
        "packages": spdx_packages,
        "relationships": relationships,
    }


def main() -> None:
    arguments = parse_arguments()
    metadata = json.loads(arguments.metadata.read_text(encoding="utf-8"))
    required_metadata = {
        "archiveSHA256",
        "alpineVersion",
        "sourceURL",
        "upstreamArchiveSHA256",
    }
    if not required_metadata.issubset(metadata):
        raise SystemExit("错误：RootFS metadata 缺少合规资源所需字段。")

    lock_root = arguments.ish_root / "third_party/alpine/3.24.1-aarch64"
    package_lock = lock_root / "packages.tsv"
    source_assets = lock_root / "source-assets.tsv"
    notices = lock_root / "THIRD-PARTY-NOTICES.txt"
    project_licenses = (
        arguments.ish_root
        / "distribution/apple/project-license/PROJECT-LICENSES.txt"
    )
    for required in (package_lock, source_assets, notices, project_licenses):
        if not required.is_file():
            raise SystemExit(f"错误：缺少合规输入：{required}")

    packages = read_packages(package_lock)
    output = arguments.output
    output.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(package_lock, output / "LocalLinuxRootFS-Packages.tsv")
    shutil.copyfile(source_assets, output / "LocalLinuxRootFS-Source-Assets.tsv")
    shutil.copyfile(notices, output / "LocalLinuxRootFS-Third-Party-Notices.txt")
    shutil.copyfile(project_licenses, output / "iSH-PROJECT-LICENSES.txt")
    write_json(
        output / "LocalLinuxRootFS-SBOM.spdx.json",
        make_sbom(metadata, packages, arguments.ish_revision),
    )

    source_offer = f"""ETOS 本地 Linux 对应源码说明 / Corresponding Source Information

本 App 内置的最小 Alpine AArch64 RootFS 由固定上游归档生成，只在 iSH guest
ABI/指令解释层内运行。它不作为 iOS 或 watchOS 原生可执行文件启动。

Alpine 版本：{metadata['alpineVersion']}
上游归档：{metadata['sourceURL']}
上游归档 SHA-256：{metadata['upstreamArchiveSHA256']}
内置 seed SHA-256：{metadata['archiveSHA256']}
iSH 修改源码：https://github.com/Eric-Terminal/ish-multiarch
iSH 精确提交：{arguments.ish_revision}

随本文件一同提供：
- ETOSLocalLinuxRootFSMigrations.json：随 App 固定交付的 RootFS 更新路径与脚本摘要；
- LocalLinuxRootFS-Packages.tsv：精确包版本、许可证和 aports 提交；
- LocalLinuxRootFS-Source-Assets.tsv：对应源码 URL、大小和摘要；
- LocalLinuxRootFS-Third-Party-Notices.txt：Alpine 包第三方声明；
- iSH-PROJECT-LICENSES.txt：iSH 项目许可证与公开源码入口；
- LocalLinuxRootFS-SBOM.spdx.json：SPDX 2.3 软件物料清单。

若公开源码入口暂时不可访问，请通过 App 内反馈渠道联系开发者索取与该版本
精确对应的源码。此说明不改变任何上游许可证授予的权利。
"""
    (output / "LocalLinuxRootFS-Source-Offer.txt").write_text(
        source_offer,
        encoding="utf-8",
    )

    manifest = {}
    for path in sorted(output.iterdir(), key=lambda item: item.name):
        if path.name == "LocalLinuxRootFS-Compliance.json" or not path.is_file():
            continue
        manifest[path.name] = {"bytes": path.stat().st_size, "sha256": sha256(path)}
    write_json(
        output / "LocalLinuxRootFS-Compliance.json",
        {
            "format": "etos-local-linux-compliance-v1",
            "ishRevision": arguments.ish_revision,
            "resources": manifest,
        },
    )


if __name__ == "__main__":
    main()
