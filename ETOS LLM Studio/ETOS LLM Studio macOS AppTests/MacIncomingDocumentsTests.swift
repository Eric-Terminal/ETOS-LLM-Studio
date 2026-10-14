import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacIncomingDocumentsTests {
    @Test("文件分流保留 GGUF 批次并拒绝远程链接")
    func classification() throws {
        let model = URL(fileURLWithPath: "/models/chat.GGUF")
        let projector = URL(fileURLWithPath: "/models/mmproj.gguf")
        let image = URL(fileURLWithPath: "/files/photo.png")
        let selection = try MacIncomingDocumentSelection(urls: [projector, image, model])
        #expect(selection.weights == [projector, model])
        #expect(selection.attachments == [image])
        #expect(selection.weightCount == 1)
        #expect(throws: MacIncomingDocumentError.self) {
            try MacIncomingDocumentSelection(urls: [URL(string: "https://example.com/model.gguf")!])
        }
    }

    @Test("解锁前保留 Finder 批次，权重和投影器不成为聊天附件")
    @MainActor
    func queuedLaunchImport() async throws {
        let fixture = try MacIncomingFixture()
        defer { fixture.remove() }
        let library = MacLocalModelLibraryModel(store: fixture.store)
        var attachments: [MacComposerAttachment] = [], errors: [String] = []
        let incoming = MacIncomingDocumentsModel(library: library, applyAttachments: { attachments += $0 }, reportError: { errors.append($0) })
        #expect(incoming.enqueue([fixture.projector, fixture.text, fixture.weights]))
        incoming.suspend(acceptNewFiles: true)
        #expect(incoming.isWorking)
        #expect(fixture.store.models.isEmpty)
        incoming.resume(sessionID: UUID())
        await incoming.waitForPendingOperations()
        #expect(!incoming.isWorking)
        #expect(errors.isEmpty)
        #expect(attachments.map(\.fileName) == ["notes.txt"])
        #expect(attachments.first?.file?.data == Data("notes".utf8))
        #expect(incoming.importedModelCount == 1)
        #expect(fixture.store.models.first?.hasMultimodalProjector == true)
        #expect(FileManager.default.fileExists(atPath: fixture.weights.path))
        library.suspend(); incoming.suspend()
        await library.waitForPendingWrites()
    }

    @Test("暂停期间不处理文件，库恢复时通过通知接着导入")
    @MainActor
    func resumesFromLibraryNotification() async throws {
        let fixture = try MacIncomingFixture()
        defer { fixture.remove() }
        let library = MacLocalModelLibraryModel(store: fixture.store)
        library.suspend()
        let entered = DispatchSemaphore(value: 0)
        var attachments: [MacComposerAttachment] = []
        let incoming = MacIncomingDocumentsModel(library: library, loadAttachments: { urls in
            entered.signal()
            return try MacIncomingDocumentSelection.loadAttachments(urls)
        }, applyAttachments: { attachments += $0 }, reportError: { _ in })
        incoming.resume(sessionID: UUID())
        #expect(incoming.enqueue([fixture.text]))
        await incoming.waitForPendingOperations()
        #expect(incoming.isWorking)
        #expect(attachments.isEmpty)
        library.resume()
        let started = await Task.detached { entered.wait(timeout: .now() + 5) == .success }.value
        #expect(started)
        await incoming.waitForPendingOperations()
        #expect(attachments.count == 1)
        #expect(!incoming.isWorking)
        library.suspend(); incoming.suspend()
        await library.waitForPendingWrites()
    }

    @Test("恢复前清空排队文件，取消后仍等待读取收尾")
    @MainActor
    func suspensionDiscardsPendingAndLateAttachments() async throws {
        let fixture = try MacIncomingFixture()
        defer { fixture.remove() }
        let library = MacLocalModelLibraryModel(store: fixture.store)
        let gate = MacPausedAttachmentRead()
        var attachments: [MacComposerAttachment] = [], errors: [String] = []
        let incoming = MacIncomingDocumentsModel(library: library, loadAttachments: { try gate.read($0) },
                                                 applyAttachments: { attachments += $0 }, reportError: { errors.append($0) })
        incoming.resume(sessionID: UUID())
        #expect(incoming.enqueue([fixture.text]))
        let entered = await Task.detached { gate.entered.wait(timeout: .now() + 5) == .success }.value
        #expect(entered)
        #expect(incoming.enqueue([fixture.weights]))
        incoming.suspend()
        #expect(!incoming.enqueue([fixture.text]))
        var finished = false
        let waiter = Task { await incoming.waitForPendingOperations(); finished = true }
        await Task.yield()
        #expect(!finished)
        gate.resume.signal()
        await waiter.value
        #expect(finished)
        #expect(!incoming.isWorking)
        #expect(attachments.isEmpty)
        #expect(errors.isEmpty)
        #expect(fixture.store.models.isEmpty)
        incoming.resume(sessionID: UUID())
        await incoming.waitForPendingOperations()
        #expect(fixture.store.models.isEmpty)
        library.suspend(); incoming.suspend()
        await library.waitForPendingWrites()
    }

    @Test("切换后再返回同一会话，旧附件结果仍然失效")
    @MainActor
    func roundTripSessionSwitchInvalidatesAttachmentRead() async throws {
        let fixture = try MacIncomingFixture()
        defer { fixture.remove() }
        let library = MacLocalModelLibraryModel(store: fixture.store)
        let gate = MacPausedAttachmentRead()
        var attachments: [MacComposerAttachment] = [], errors: [String] = []
        let incoming = MacIncomingDocumentsModel(library: library, loadAttachments: { try gate.read($0) },
                                                 applyAttachments: { attachments += $0 }, reportError: { errors.append($0) })
        let session = UUID()
        incoming.resume(sessionID: session)
        let oldContext = incoming.contextID
        #expect(incoming.enqueue([fixture.text]))
        let entered = await Task.detached { gate.entered.wait(timeout: .now() + 5) == .success }.value
        #expect(entered)
        incoming.updateSession(UUID()); incoming.updateSession(session)
        #expect(incoming.contextID != oldContext)
        gate.resume.signal()
        await incoming.waitForPendingOperations()
        #expect(attachments.isEmpty)
        #expect(errors.count == 1)
        library.suspend(); incoming.suspend()
        await library.waitForPendingWrites()
    }

    @Test("只有投影器的批次报错且不附加到聊天")
    @MainActor
    func projectorOnlyImportIsRejected() async throws {
        let fixture = try MacIncomingFixture()
        defer { fixture.remove() }
        let library = MacLocalModelLibraryModel(store: fixture.store)
        var attachments: [MacComposerAttachment] = [], errors: [String] = []
        let incoming = MacIncomingDocumentsModel(library: library, applyAttachments: { attachments += $0 }, reportError: { errors.append($0) })
        incoming.resume(sessionID: UUID())
        #expect(incoming.enqueue([fixture.projector]))
        await incoming.waitForPendingOperations()
        #expect(attachments.isEmpty)
        #expect(errors.count == 1)
        #expect(incoming.importedModelCount == 0)
        #expect(fixture.store.models.isEmpty)
        library.suspend(); incoming.suspend()
        await library.waitForPendingWrites()
    }
}

private final class MacPausedAttachmentRead: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    func read(_ urls: [URL]) throws -> [MacComposerAttachment] {
        entered.signal()
        guard resume.wait(timeout: .now() + 10) == .success else { throw CocoaError(.fileReadUnknown) }
        // 故意忽略任务取消，验证工作区对迟到结果的隔离，而非只依赖加载器配合。
        return [MacComposerAttachment(data: Data("late".utf8), type: .plainText, fileName: urls[0].lastPathComponent)]
    }
}

private struct MacIncomingFixture {
    let root: URL
    let store: LocalModelStore
    let weights: URL
    let projector: URL
    let text: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacIncoming-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = LocalModelStore(directoryURL: root.appendingPathComponent("models"))
        weights = root.appendingPathComponent("chat.gguf")
        projector = root.appendingPathComponent("mmproj.gguf")
        text = root.appendingPathComponent("notes.txt")
        var bytes = Data([0x47, 0x47, 0x55, 0x46])
        func append<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
        }
        func string(_ value: String) {
            let utf8 = Array(value.utf8)
            append(UInt64(utf8.count)); bytes.append(contentsOf: utf8)
        }
        append(UInt32(3)); append(UInt64(0)); append(UInt64(1))
        string("general.architecture"); append(Int32(8)); string("llama")
        try bytes.write(to: weights)
        try Data([1]).write(to: projector)
        try Data("notes".utf8).write(to: text)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
