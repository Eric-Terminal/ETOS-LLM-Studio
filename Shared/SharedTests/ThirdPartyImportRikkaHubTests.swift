// ============================================================================
// ThirdPartyImportRikkaHubTests.swift
// ============================================================================
// ThirdPartyImportService RikkaHub 导入测试
// - 覆盖 settings.json provider 解析
// - 覆盖会话暂不支持时的提示信息
// ============================================================================

import Foundation
import Testing
@testable import Shared

@Suite("第三方导入 RikkaHub 兼容测试")
struct ThirdPartyImportRikkaHubTests {

    @Test("RikkaHub settings.json 可解析 provider")
    func testPrepareRikkaImportFromSettingsJSON() throws {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let settings: [String: Any] = [
            "providers": [
                [
                    "id": "rikka-provider-1",
                    "name": "Gemini 官方",
                    "type": "gemini",
                    "baseUrl": "https://generativelanguage.googleapis.com",
                    "apiKey": "rk-test-key",
                    "enabled": true,
                    "models": [
                        ["modelId": "gemini-2.5-pro", "displayName": "Gemini 2.5 Pro"]
                    ]
                ]
            ]
        ]

        let fileURL = sandbox.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: settings).write(to: fileURL)

        let prepared = try ThirdPartyImportService.prepareImport(
            source: .rikkahub,
            fileURL: fileURL
        )

        #expect(prepared.package.options.contains(.providers))
        #expect(!prepared.package.options.contains(.sessions))
        #expect(prepared.package.providers.count == 1)
        #expect(prepared.package.sessions.isEmpty)

        let provider = prepared.package.providers[0]
        #expect(provider.name == "Gemini 官方")
        #expect(provider.apiFormat == "gemini")
        #expect(provider.baseURL == "https://generativelanguage.googleapis.com/v1beta")
        #expect(provider.models.map(\.modelName) == ["gemini-2.5-pro"])
        #expect(prepared.warnings.contains(where: { $0.contains("会话内容暂未解析") }))
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
