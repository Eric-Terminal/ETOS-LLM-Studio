import Foundation
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacLocalModelDraftTests {
    @Test("本地参数保留未覆盖状态、零值和随机种子")
    func optionalParameterRoundTrip() throws {
        var original = record()
        original.contextSize = 4096; original.topK = 0; original.temperature = 0
        original.kvOffload = false; original.flashAttention = .auto; original.seed = UInt32.max
        original.grammar = "root ::= \"ok\""; original.advancedArguments = "--typical 0.9"
        var draft = MacLocalModelDraft(record: original)
        #expect(try draft.resolved() == original)
        draft.numbers["contextSize"] = ""
        draft.numbers["seed"] = "-1"
        let saved = try draft.resolved()
        #expect(saved.contextSize == nil)
        #expect(saved.topK == 0)
        #expect(saved.temperature == 0)
        #expect(saved.seed == UInt32.max)
        #expect(saved.kvOffload == false)
        #expect(saved.flashAttention == .auto)
    }

    @Test("无效数值阻止保存而不悄悄截断")
    func invalidParameters() {
        for input in [
            ("contextSize", "0"), ("gpuLayers", "-2"), ("topK", "1.5"),
            ("topP", "1.1"), ("temperature", "nan"), ("temperature", "inf"),
            ("seed", "4294967296"), ("seed", "-2"), ("batchSize", "1048577")
        ] {
            var draft = MacLocalModelDraft(record: record())
            draft.numbers[input.0] = input.1
            #expect(throws: MacLocalModelInputError.self) { try draft.resolved() }
        }
    }

    @Test("新 LoRA 选择保留待保存的强度，移除附件不修改原件")
    func attachmentDraftState() throws {
        var original = record()
        original.mmprojRelativePath = "vision.gguf"; original.mmprojFileName = "vision.gguf"
        var draft = MacLocalModelDraft(record: original)
        draft.adapterURL = URL(fileURLWithPath: "/chosen/adapter.gguf")
        draft.numbers["loraScale"] = "0.375"
        #expect(try draft.resolved().loraScale == 0.375)
        draft.removeProjector(); draft.removeAdapter()
        #expect(draft.projectorURL == nil)
        #expect(draft.adapterURL == nil)
        #expect(draft.record.mmprojRelativePath == nil)
        #expect(try draft.resolved().loraScale == nil)
        #expect(original.mmprojRelativePath == "vision.gguf")
    }

    @Test("LoRA 验证失败清理刚复制的投影器并保留原模型")
    func attachmentFailureCleansOnlyNewFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalModelStore(directoryURL: root.appendingPathComponent("models"))
        store.update(record())
        let original = try #require(store.models.first)
        let projector = root.appendingPathComponent("mmproj.gguf")
        let adapter = root.appendingPathComponent("invalid-lora.gguf")
        try Data([1]).write(to: projector); try Data([2]).write(to: adapter)
        var draft = MacLocalModelDraft(record: original)
        draft.projectorURL = projector; draft.adapterURL = adapter
        #expect(throws: (any Error).self) { try draft.save(in: store, replacing: original) }
        #expect(store.models == [original])
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path)
        #expect(files == ["local-models.json"])
        #expect(FileManager.default.fileExists(atPath: projector.path))
        #expect(FileManager.default.fileExists(atPath: adapter.path))
    }

    @Test("已变化的原件不会启动附件复制")
    func staleDraftDoesNotCopy() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalModelStore(directoryURL: root.appendingPathComponent("models"))
        store.update(record())
        let original = try #require(store.models.first)
        var newer = original
        newer.displayName = "其他编辑器的修改"
        store.update(newer)
        var draft = MacLocalModelDraft(record: original)
        draft.projectorURL = root.appendingPathComponent("does-not-exist.gguf")
        #expect(throws: LocalModelDraftWriteError.self) { try draft.save(in: store, replacing: original) }
        #expect(store.models.first?.displayName == newer.displayName)
    }

    @Test("批量导入区分权重与第一个投影器，拒绝只有投影器的选择")
    func importSelection() throws {
        let model = URL(fileURLWithPath: "/models/chat.gguf")
        let projector = URL(fileURLWithPath: "/models/MMPROJ-vision.gguf")
        let selection = try MacLocalModelLibraryModel.importSelection([projector, model])
        #expect(selection.weights == [model])
        #expect(selection.projector == projector)
        #expect(throws: MacLocalModelInputError.self) { try MacLocalModelLibraryModel.importSelection([projector]) }
    }

    @Test("采样链保留顺序、空白恢复默认、未知代码和重复项拒绝应用")
    func samplerCodes() throws {
        #expect(try MacLocalSamplerRow.parse("epkt") == [.penalties, .topP, .topK, .temperature])
        #expect(try MacLocalSamplerRow.parse("  ") == nil)
        #expect(throws: (any Error).self) { try MacLocalSamplerRow.parse("ekkt") }
        #expect(throws: (any Error).self) { try MacLocalSamplerRow.parse("unknown") }
    }

    @Test("语音候选排除缺失文件，并保留旧引用缺失状态")
    func speechCandidates() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalModelStore(directoryURL: root.appendingPathComponent("models"))
        var decoder = record(); decoder.ggufArchitecture = "qwen3"
        var missing = record(); missing.ggufArchitecture = "qwen3"; missing.relativePath = "missing.gguf"
        var encoder = record(); encoder.ggufArchitecture = "funasr-sensevoice-encoder"; encoder.speechDecoderModelID = missing.id
        try Data([1]).write(to: store.fileURL(for: decoder))
        let rows = [decoder, missing].map { MacLocalModelRow(record: $0, store: store) }
        let source = MacLocalModelEditorSource(row: MacLocalModelRow(record: encoder, store: store), rows: rows)
        #expect(source.decoders.map(\.id) == [decoder.id])
        #expect(source.missingDecoderID == missing.id.uuidString)
    }

    @Test("暂停后等待已登记的文件写入，旧页面即使恢复也不能再写")
    @MainActor
    func lifecycleWaitsForFileCommit() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = MacPausedLocalModelCopy()
        let store = LocalModelStore(fileManager: fileManager, directoryURL: root.appendingPathComponent("models"))
        store.update(record())
        let original = try #require(store.models.first)
        let projector = root.appendingPathComponent("mmproj.gguf")
        try Data([1]).write(to: projector)
        var draft = MacLocalModelDraft(record: original)
        draft.projectorURL = projector
        let library = MacLocalModelLibraryModel(store: store)
        let epoch = library.epoch, value = draft
        let save = Task { await library.save(value, original: original, expectedEpoch: epoch) }
        let entered = await Task.detached { fileManager.entered.wait(timeout: .now() + 5) == .success }.value
        #expect(entered)
        #expect(library.isWorking)
        library.suspend()
        #expect(await library.save(value, original: original, expectedEpoch: epoch) == false)
        var finished = false
        let wait = Task { await library.waitForPendingWrites(); finished = true }
        await Task.yield()
        #expect(!finished)
        fileManager.resume.signal()
        #expect(await save.value)
        await wait.value
        #expect(finished)
        #expect(!library.isWorking)
        #expect(!library.canWrite)
        #expect(store.models.first?.hasMultimodalProjector == true)
        library.resume()
        let saved = try #require(store.models.first)
        #expect(await library.delete(saved, expectedEpoch: epoch) == false)
        #expect(store.models.count == 1)
        library.suspend()
        await library.waitForPendingWrites()
    }

    private func record() -> LocalModelRecord {
        LocalModelRecord(displayName: "模型", fileName: "model.gguf", relativePath: "model.gguf", fileSize: 1, ggufArchitecture: "llama")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacLocalModels-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class MacPausedLocalModelCopy: FileManager, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        entered.signal()
        guard resume.wait(timeout: .now() + 10) == .success else { throw CocoaError(.fileWriteUnknown) }
        try super.copyItem(at: srcURL, to: dstURL)
    }
}
