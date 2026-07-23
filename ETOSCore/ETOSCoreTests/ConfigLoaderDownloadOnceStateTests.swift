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
}
