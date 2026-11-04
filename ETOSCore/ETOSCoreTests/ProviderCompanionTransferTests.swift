import Foundation
import Testing
@testable import ETOSCore

struct ProviderCompanionTransferTests {
    @Test("单个提供商载荷保留凭据、模型和代理，且兼容现有接收信封")
    func preservesConfigurationWithoutUnrelatedData() throws {
        let provider = Provider(
            name: "测试提供商",
            baseURL: "https://example.com/v1",
            chatEndpointPath: "/custom/chat",
            apiKeys: ["test-key-a", "test-key-b"],
            apiFormat: "openai-compatible",
            models: [
                Model(modelName: "chat", isActivated: true, overrideParameters: ["reasoning": .dictionary(["effort": .string("high")])]),
                Model(modelName: "disabled", isActivated: false)
            ],
            headerOverrides: ["X-Test": "test-header"],
            proxyConfiguration: NetworkProxyConfiguration(isEnabled: true, type: .socks5, host: "localhost", port: 1080, username: "test-user", password: "test-password"),
            multiKeyEnabled: true,
            apiKeyNotes: ["test-key-a": "主密钥", "test-key-b": "备用密钥"],
            maximumKeyRetries: 5
        )
        let now = Date(timeIntervalSince1970: 100)
        let envelope = try ProviderCompanionTransfer.makeEnvelope(provider: provider, now: now)
        // 与 WatchSyncManager 的现有接收结构一致，新增发送入口不要求另一端更换协议。
        struct ReceivedPacket: Decodable {
            let manifest: SyncManifest
            let delta: SyncDeltaPackage?
        }
        let packet = try JSONDecoder().decode(ReceivedPacket.self, from: JSONEncoder().encode(envelope))
        let delta = try #require(packet.delta)
        #expect(packet.manifest.options == [.providers])
        #expect(packet.manifest.records.count == 1)
        #expect(packet.manifest.records.first?.recordID == provider.id.uuidString)
        #expect(packet.manifest.records.first?.updatedAt == now)
        #expect(packet.manifest.records.first?.checksum == SyncDeltaEngine.stableChecksum(provider))
        #expect(delta.package.providers == [provider])
        #expect(delta.package.options == [.providers])
        #expect(delta.package.sessions.isEmpty)
        #expect(delta.package.sessionTags.isEmpty)
        #expect(delta.package.imageFiles.isEmpty)
        #expect(delta.package.audioFiles.isEmpty)
        #expect(delta.package.mcpServers.isEmpty)
        #expect(delta.package.skills.isEmpty)
        #expect(delta.package.appStorageSnapshot == nil)
        #expect(delta.package.globalSystemPrompt == nil)
        #expect(delta.deletions.isEmpty)
    }

    @Test("连续发送不同提供商不会携带上一项或生成删除记录")
    func consecutiveTransfersStayIndependent() throws {
        let first = Provider(name: "提供商一", baseURL: "https://one.example", apiKeys: [], apiFormat: "openai-compatible")
        let second = Provider(name: "提供商二", baseURL: "https://two.example", apiKeys: [], apiFormat: "anthropic")
        for provider in [first, second, first] {
            let envelope = try ProviderCompanionTransfer.makeEnvelope(provider: provider)
            #expect(envelope.delta.package.providers == [provider])
            #expect(envelope.manifest.records.map(\.recordID) == [provider.id.uuidString])
            #expect(envelope.delta.deletions.isEmpty)
        }
    }

    @Test("本地提供商无论通过固定 ID 还是本地协议识别都不能发送")
    func rejectsLocalProviders() {
        var localByID = LocalModelProviderBridge.provider
        localByID.apiFormat = "openai-compatible"
        var localByFormat = LocalModelProviderBridge.provider
        localByFormat.id = UUID()
        for provider in [localByID, localByFormat] {
            #expect(throws: ProviderCompanionTransfer.TransferError.self) {
                try ProviderCompanionTransfer.makeEnvelope(provider: provider)
            }
        }
    }

    @Test("提供商向导说明涵盖双向入口、发送边界与只读权限")
    func guideDocumentsTransferBoundaries() throws {
        let document = try #require(GuideDocumentCatalog.documents.first { $0.id == "provider-model-basics" })
        #expect(document.keywords.contains("单个提供商同步"))
        #expect(document.content.contains("发送到 Apple Watch"))
        #expect(document.content.contains("发送到 iPhone"))
        #expect(document.content.contains("不包含其他提供商、聊天记录、全局设置或本地模型文件"))
        #expect(document.content.contains("向导不能发送凭据"))
        #expect(document.content.contains("macOS 不支持这条配对设备通道"))
    }

    #if os(iOS) || os(watchOS)
    @MainActor
    @Test("发送说明只提供只读向导字段，不提供传输执行器或凭据")
    func guideSettingsAreReadOnly() {
        let settings = ProviderCompanionTransferHelp.guideSettings
        #expect(settings.allSatisfy { $0.access == .readOnly })
    }
    #endif
}
