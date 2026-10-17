import Combine
import Foundation
import Testing
@testable import ETOSCore

@Suite("本地模型后台存储")
struct LocalModelBackgroundStorageTests {
    @Test("同名并发导入保留所有文件和记录")
    func concurrentImports() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.gguf()
        let imported = try await withThrowingTaskGroup(of: LocalModelRecord.self) { group in
            for _ in 0..<8 {
                group.addTask { try fixture.store.importModel(from: source) }
            }
            var values: [LocalModelRecord] = []
            for try await value in group { values.append(value) }
            return values
        }
        #expect(Set(imported.map(\.relativePath)).count == 8)
        #expect(fixture.store.models.count == 8)
        #expect(imported.allSatisfy { fixture.store.fileExists(for: $0) })
        let reloaded = LocalModelStore(directoryURL: fixture.store.directoryURL)
        #expect(Set(reloaded.models.map(\.id)) == Set(imported.map(\.id)))
    }

    @Test("不同模型并发保存不会丢失另一条修改")
    func concurrentDraftWrites() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.record(name: "first")
        let second = try fixture.record(name: "second")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for original in [first, second] {
                group.addTask {
                    var draft = original
                    draft.contextSize = 8192
                    try fixture.store.saveDraft(draft, replacing: original)
                }
            }
            try await group.waitForAll()
        }
        let reloaded = LocalModelStore(directoryURL: fixture.store.directoryURL)
        #expect(reloaded.models.count == 2)
        #expect(reloaded.models.allSatisfy { $0.contextSize == 8192 })
    }

    @Test("过期草稿不能保存、删除或复活记录")
    func staleDrafts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try fixture.record()
        var draft = original
        draft.displayName = "更新后的名称"
        let saved = try fixture.store.saveDraft(draft, replacing: original)
        #expect(throws: LocalModelDraftWriteError.self) {
            try fixture.store.saveDraft(original, replacing: original)
        }
        #expect(throws: LocalModelDraftWriteError.self) {
            try fixture.store.deleteDraft(original)
        }
        #expect(fixture.store.models == [saved])
        try fixture.store.deleteDraft(saved)
        #expect(throws: LocalModelDraftWriteError.self) {
            try fixture.store.saveDraft(draft, replacing: saved)
        }
        #expect(fixture.store.models.isEmpty)
    }

    @Test("同一原件的并发保存只能有一次成功")
    func concurrentConflictingDrafts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try fixture.record()
        let successes = try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 0..<8 {
                group.addTask {
                    var draft = original
                    draft.displayName = "编辑器 \(index)"
                    do {
                        try fixture.store.saveDraft(draft, replacing: original)
                        return true
                    } catch LocalModelDraftWriteError.changedExternally {
                        return false
                    }
                }
            }
            var count = 0
            for try await succeeded in group where succeeded { count += 1 }
            return count
        }
        #expect(successes == 1)
        #expect(fixture.store.models.count == 1)
    }

    @Test("写入失败保留原快照和原附件，重试后才清理附件")
    func failedSavePreservesOldFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let initial = try fixture.record()
        var attached = initial
        attached.mmprojRelativePath = "original-mmproj.gguf"
        attached.loraRelativePath = "original-lora.gguf"
        let projector = fixture.store.directoryURL.appendingPathComponent(attached.mmprojRelativePath!)
        let adapter = fixture.store.directoryURL.appendingPathComponent(attached.loraRelativePath!)
        try Data([1]).write(to: projector)
        try Data([2]).write(to: adapter)
        let original = try fixture.store.saveDraft(attached, replacing: initial)
        var draft = original
        draft.mmprojRelativePath = nil
        draft.loraRelativePath = nil
        try fixture.blockMetadataWrites()
        #expect(throws: (any Error).self) { try fixture.store.saveDraft(draft, replacing: original) }
        #expect(fixture.store.models == [original])
        #expect(FileManager.default.fileExists(atPath: projector.path))
        #expect(FileManager.default.fileExists(atPath: adapter.path))
        fixture.store.update(draft)
        #expect(fixture.store.models == [original])
        try fixture.unblockMetadataWrites()
        let saved = try fixture.store.saveDraft(draft, replacing: original)
        #expect(fixture.store.models == [saved])
        #expect(!FileManager.default.fileExists(atPath: projector.path))
        #expect(!FileManager.default.fileExists(atPath: adapter.path))
    }

    @Test("导入元数据失败会清理本次复制的权重和投影器")
    func failedImportCleansCopies() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.gguf()
        let projector = fixture.root.appendingPathComponent("mmproj.gguf")
        try Data([1]).write(to: projector)
        try fixture.blockMetadataWrites()
        #expect(throws: (any Error).self) {
            try fixture.store.importModel(from: source, mmprojURL: projector)
        }
        #expect(fixture.store.models.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.store.directoryURL.path)
        #expect(files == ["local-models.json"])
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: projector.path))
    }

    @Test("删除落盘失败不会删除权重或清空语音伴随关系")
    func failedDeletePreservesCompanions() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let decoder = try fixture.record(name: "decoder")
        let initial = try fixture.record(name: "encoder")
        var draft = initial
        draft.speechDecoderModelID = decoder.id
        let encoder = try fixture.store.saveDraft(draft, replacing: initial)
        let before = fixture.store.models
        try fixture.blockMetadataWrites()
        #expect(throws: (any Error).self) { try fixture.store.deleteDraft(decoder) }
        #expect(fixture.store.models == before)
        #expect(fixture.store.fileExists(for: decoder))
        fixture.store.delete(decoder)
        #expect(fixture.store.models == before)
        try fixture.unblockMetadataWrites()
        try fixture.store.deleteDraft(decoder)
        #expect(fixture.store.models.count == 1)
        #expect(fixture.store.models.first?.id == encoder.id)
        #expect(fixture.store.models.first?.speechDecoderModelID == nil)
        #expect(!fixture.store.fileExists(for: decoder))
    }

    @Test("取消旧附件草稿不会删除另一编辑器已保存的文件")
    func cleanupRetainsSavedAttachments() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let initial = try fixture.record()
        var draft = initial
        draft.mmprojRelativePath = "shared-mmproj.gguf"
        draft.loraRelativePath = "shared-lora.gguf"
        let projector = fixture.store.directoryURL.appendingPathComponent(draft.mmprojRelativePath!)
        let adapter = fixture.store.directoryURL.appendingPathComponent(draft.loraRelativePath!)
        try Data([1]).write(to: projector)
        try Data([2]).write(to: adapter)
        let saved = try fixture.store.saveDraft(draft, replacing: initial)
        fixture.store.deleteProjectorFile(relativePath: draft.mmprojRelativePath!)
        fixture.store.deleteLoRAFile(relativePath: draft.loraRelativePath!)
        #expect(fixture.store.mmprojFileExists(for: saved))
        #expect(fixture.store.loraFileExists(for: saved))
        try fixture.store.deleteDraft(saved)
        #expect(!FileManager.default.fileExists(atPath: projector.path))
        #expect(!FileManager.default.fileExists(atPath: adapter.path))
    }

    @Test("复制权重期间展示快照可立即读取")
    func snapshotDoesNotWaitForCopy() async throws {
        let fileManager = PausedCopyFileManager()
        let fixture = try Fixture(fileManager: fileManager)
        defer { fixture.remove() }
        let initial = try fixture.record()
        let source = try fixture.gguf()
        let importTask = Task.detached { try fixture.store.importModel(from: source) }
        // 信号量只用于测试中的后台线程，超时后一定释放复制，避免断言失败留下悬挂任务。
        let readSucceeded = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                guard fileManager.copyStarted.wait(timeout: .now() + 5) == .success else {
                    fileManager.resumeCopy.signal()
                    continuation.resume(returning: false)
                    return
                }
                let readCompleted = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    #expect(fixture.store.models == [initial])
                    readCompleted.signal()
                }
                let succeeded = readCompleted.wait(timeout: .now() + 2) == .success
                fileManager.resumeCopy.signal()
                if !succeeded { _ = readCompleted.wait(timeout: .now() + 5) }
                continuation.resume(returning: succeeded)
            }
        }
        _ = try await importTask.value
        #expect(readSucceeded)
        #expect(fixture.store.models.count == 2)
    }

    @Test("后台修改的观察通知回到主线程并能读取新快照")
    @MainActor
    func observationPublishesOnMainThread() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try fixture.record()
        var draft = original
        draft.displayName = "后台修改"
        let updated = draft
        var subscription: AnyCancellable?
        await withCheckedContinuation { continuation in
            subscription = fixture.store.objectWillChange.sink {
                guard fixture.store.models.first?.displayName == updated.displayName else { return }
                #expect(Thread.isMainThread)
                subscription?.cancel()
                continuation.resume()
            }
            Task.detached { fixture.store.update(updated) }
        }
        withExtendedLifetime(subscription) {}
    }

    @Test("等待 UI 更新后才能认为存储任务完整收尾")
    @MainActor
    func waitsForQueuedUIUpdates() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try fixture.record()
        await fixture.store.waitForPendingUIUpdates()
        var didPublish = false
        let subscription = fixture.store.objectWillChange.sink { didPublish = true }
        await Task.detached {
            var draft = original
            draft.displayName = "已提交"
            fixture.store.update(draft)
        }.value
        await fixture.store.waitForPendingUIUpdates()
        #expect(didPublish)
        #expect(fixture.store.models.first?.displayName == "已提交")
        withExtendedLifetime(subscription) {}
    }
}

private struct Fixture: Sendable {
    let root: URL
    let store: LocalModelStore

    init(fileManager: FileManager = .default) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalModelBackground-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = LocalModelStore(fileManager: fileManager, directoryURL: root.appendingPathComponent("LocalModels"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func record(name: String = "model") throws -> LocalModelRecord {
        let record = LocalModelRecord(displayName: name, fileName: "\(name).gguf", relativePath: "\(name).gguf", fileSize: 1, ggufArchitecture: "llama")
        try Data([1]).write(to: store.fileURL(for: record))
        store.update(record)
        return try #require(store.models.first { $0.id == record.id })
    }

    func blockMetadataWrites() throws {
        let url = store.directoryURL.appendingPathComponent("local-models.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        // 使用非空目录阻止原子替换；磁盘失败与文件复制失败必须覆盖不同路径。
        try Data([1]).write(to: url.appendingPathComponent("occupied"))
    }

    func unblockMetadataWrites() throws {
        try FileManager.default.removeItem(at: store.directoryURL.appendingPathComponent("local-models.json"))
    }

    func gguf() throws -> URL {
        var bytes = Data([0x47, 0x47, 0x55, 0x46])
        func append<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
        }
        func string(_ value: String) {
            let utf8 = Array(value.utf8)
            append(UInt64(utf8.count))
            bytes.append(contentsOf: utf8)
        }
        append(UInt32(3)); append(UInt64(0)); append(UInt64(1))
        string("general.architecture"); append(Int32(8)); string("llama")
        let url = root.appendingPathComponent("source.gguf")
        try bytes.write(to: url)
        return url
    }
}

private final class PausedCopyFileManager: FileManager, @unchecked Sendable {
    let copyStarted = DispatchSemaphore(value: 0)
    let resumeCopy = DispatchSemaphore(value: 0)

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        copyStarted.signal()
        guard resumeCopy.wait(timeout: .now() + 10) == .success else { throw CocoaError(.fileWriteUnknown) }
        try super.copyItem(at: srcURL, to: dstURL)
    }
}
