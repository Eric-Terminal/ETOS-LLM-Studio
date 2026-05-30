// ============================================================================
// LocalModelStoreTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证本地模型元数据、文件生命周期与虚拟提供商映射。
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("本地模型存储测试")
struct LocalModelStoreTests {
    @Test("导入、更新和删除本地模型")
    func importUpdateDeleteLocalModel() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source.gguf")
        try Data([1, 2, 3, 4]).write(to: source)
        let store = LocalModelStore(directoryURL: root.appendingPathComponent("LocalModels"))

        var record = try store.importModel(from: source, displayName: "  小模型  ")
        #expect(store.models.count == 1)
        #expect(record.sanitizedDisplayName == "小模型")
        #expect(store.fileExists(for: record))

        record.displayName = "新名字"
        record.contextSize = 0
        record.maxOutputTokens = 0
        store.update(record)

        let reloaded = LocalModelStore(directoryURL: store.directoryURL)
        #expect(reloaded.models.first?.sanitizedDisplayName == "新名字")
        #expect(reloaded.models.first?.contextSize == 1)
        #expect(reloaded.models.first?.maxOutputTokens == 1)

        if let saved = reloaded.models.first {
            reloaded.delete(saved)
            #expect(reloaded.models.isEmpty)
            #expect(!reloaded.fileExists(for: saved))
        }
    }

    @Test("本地模型虚拟提供商使用稳定 ID")
    func localProviderBridgeUsesStableRunnableID() {
        let id = UUID()
        let record = LocalModelRecord(
            id: id,
            displayName: "TinyLlama",
            fileName: "tiny.gguf",
            relativePath: "tiny.gguf",
            fileSize: 8
        )

        let runnable = LocalModelProviderBridge.runnableModel(for: record)

        #expect(runnable.provider.id == LocalModelProviderBridge.providerID)
        #expect(runnable.provider.apiFormat == LocalModelProviderBridge.apiFormat)
        #expect(runnable.model.id == id)
        #expect(LocalModelProviderBridge.localRecordID(from: runnable.id) == id)
    }

    @Test("缺失文件的本地模型不会进入可用候选")
    func missingLocalModelIsNotActivatedCandidate() {
        let store = LocalModelStore(directoryURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
        store.update(LocalModelRecord(
            displayName: "Missing",
            fileName: "missing.gguf",
            relativePath: "missing.gguf",
            fileSize: 0,
            isActivated: true
        ))

        let service = ChatService(localModelStore: store)

        #expect(service.configuredRunnableModels.contains(where: { LocalModelProviderBridge.isLocalRunnableModel($0) }))
        #expect(!service.activatedConversationModels.contains(where: { LocalModelProviderBridge.isLocalRunnableModel($0) }))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
