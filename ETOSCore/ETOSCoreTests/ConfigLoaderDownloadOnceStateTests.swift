// ============================================================================
// ConfigLoaderDownloadOnceStateTests.swift
// ============================================================================
// ConfigLoaderDownloadOnceStateTests 测试文件
// - 覆盖 download_once 完成标记读写
// - 覆盖官方数据路径与内容校验
// ============================================================================

import Testing
import Foundation
import CryptoKit
@testable import ETOSCore

@Suite("ConfigLoader 官方数据同步状态测试")
struct ConfigLoaderDownloadOnceStateTests {

    @Test("完成标记仅在显式设置后为 true")
    func testDownloadOnceCompletionFlagRoundTrip() {
        let suiteName = "ConfigLoaderDownloadOnceStateTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("无法创建测试用 UserDefaults 套件")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(ConfigLoader.isDownloadOnceCompleted(defaults: defaults) == false)

        ConfigLoader.setDownloadOnceCompleted(true, defaults: defaults)
        #expect(ConfigLoader.isDownloadOnceCompleted(defaults: defaults) == true)

        ConfigLoader.setDownloadOnceCompleted(false, defaults: defaults)
        #expect(ConfigLoader.isDownloadOnceCompleted(defaults: defaults) == false)
    }

    @Test("官方数据目标目录必须位于 Documents 内")
    func testOfficialDataDestinationRejectsTraversal() {
        #expect(ConfigLoader.resolveDownloadDestination(for: "/Documents/Providers") != nil)
        #expect(ConfigLoader.resolveDownloadDestination(for: "Documents/Backgrounds") != nil)
        #expect(ConfigLoader.resolveDownloadDestination(for: "/Documents") != nil)
        #expect(ConfigLoader.resolveDownloadDestination(for: "/Library") == nil)
        #expect(ConfigLoader.resolveDownloadDestination(for: "/Documents/../Library") == nil)
        #expect(ConfigLoader.resolveDownloadDestination(for: "Documents/Providers/../../Library") == nil)
        #expect(ConfigLoader.resolveDownloadDestination(for: "Documents//Providers") == nil)
    }

    @Test("官方数据仅接受大小和 SHA-256 均匹配的内容")
    func testOfficialDataChecksumValidation() {
        let data = Data("official-data".utf8)
        let checksum = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()

        #expect(
            ConfigLoader.officialDataMatches(
                data,
                expectedSize: Int64(data.count),
                expectedSHA256: checksum
            )
        )
        #expect(
            ConfigLoader.officialDataMatches(
                data,
                expectedSize: Int64(data.count + 1),
                expectedSHA256: checksum
            ) == false
        )
        #expect(
            ConfigLoader.officialDataMatches(
                data,
                expectedSize: Int64(data.count),
                expectedSHA256: String(repeating: "0", count: 64)
            ) == false
        )
    }

    @Test("旧版 version 1 清单缺少 actions 时仍可解码")
    func legacyManifestWithoutActionsStillDecodes() throws {
        let data = Data(#"{"version":1,"downloads":[]}"#.utf8)
        let manifest = try JSONDecoder().decode(ConfigLoader.OfficialDataManifest.self, from: data)

        #expect(manifest.version == 1)
        #expect(manifest.downloads.isEmpty)
        #expect(manifest.actions.isEmpty)
    }

    @Test("操作清单携带执行范围与合并策略并按触发方式过滤")
    func actionManifestDecodesPreviewMetadata() throws {
        let data = Data(
            #"""
            {
              "version": 1,
              "downloads": [],
              "actions": [
                {
                  "id": "official-provider.test",
                  "revision": 1,
                  "kind": "provider.upsert",
                  "apply_on": ["manual_sync"],
                  "payload_url": "/v1/distribution/files/checksum/provider-action.json",
                  "payload_file_name": "provider-action.json",
                  "payload_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
                  "payload_size": 1,
                  "merge_policy": {
                    "provider_fields": "update_if_unmodified",
                    "api_keys": "preserve_local_if_nonempty",
                    "header_overrides": "update_if_unmodified",
                    "proxy_configuration": "preserve_local",
                    "models": {
                      "fields": "update_if_unmodified",
                      "is_activated": "preserve_local",
                      "on_missing": "insert",
                      "on_removed": "delete_if_unmodified",
                      "user_models": "preserve"
                    },
                    "if_user_deleted": "restore_on_manual_sync"
                  }
                }
              ]
            }
            """#.utf8
        )
        let manifest = try JSONDecoder().decode(ConfigLoader.OfficialDataManifest.self, from: data)
        let action = try #require(manifest.actions.first)

        #expect(action.applyOn == [.manualSync])
        #expect(action.mergePolicy.apiKeys == .preserveLocalIfNonempty)
        #expect(ConfigLoader.actionEntryApplies(action, trigger: .manualSync))
        #expect(ConfigLoader.actionEntryApplies(action, trigger: .initialSync) == false)
    }

    @Test("未知操作不会阻断旧版文件清单解码")
    func unknownActionDoesNotBreakDownloads() throws {
        let data = Data(
            #"{"version":1,"downloads":[{"name":"背景","path":"/Documents/Backgrounds","url":"/background.png","file_name":"background.png","sha256":"0000000000000000000000000000000000000000000000000000000000000000","size":1}],"actions":[{"id":"future","revision":1,"kind":"future.operation"}]}"#.utf8
        )
        let manifest = try JSONDecoder().decode(ConfigLoader.OfficialDataManifest.self, from: data)

        #expect(manifest.downloads.count == 1)
        #expect(manifest.actions.isEmpty)
    }
}
