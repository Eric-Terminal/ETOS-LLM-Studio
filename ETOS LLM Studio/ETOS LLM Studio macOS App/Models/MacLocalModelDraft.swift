import ETOSCore
import Foundation

/// 数值保留原始输入，保存时统一校验；空白表示不覆盖核心默认值。
struct MacLocalModelDraft: Sendable {
    var record: LocalModelRecord
    var numbers: [String: String]
    var projectorURL: URL?
    var adapterURL: URL?

    init(record: LocalModelRecord) {
        self.record = record
        numbers = Dictionary(uniqueKeysWithValues: MacLocalModelNumber.fields.map { ($0.id, $0.text(in: record)) })
    }

    func resolved() throws -> LocalModelRecord {
        var result = record
        guard !record.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MacLocalModelInputError.emptyName
        }
        for field in MacLocalModelNumber.fields {
            try field.apply(numbers[field.id] ?? "", to: &result)
        }
        let adapterScale = result.loraScale
        result.normalizeGenerationParameters()
        if adapterURL != nil { result.loraScale = adapterScale }
        return result
    }

    /// 附件先复制为草稿，提交冲突或失败只清理本次副本，不触碰原件。
    func save(in store: LocalModelStore, replacing original: LocalModelRecord) throws {
        guard store.models.first(where: { $0.id == original.id }) == original else {
            throw LocalModelDraftWriteError.changedExternally
        }
        var result = try resolved()
        var copiedProjector: String?
        var copiedAdapter: String?
        do {
            if let projectorURL {
                try store.copyMultimodalProjector(from: projectorURL, into: &result)
                copiedProjector = result.mmprojRelativePath
            }
            if let adapterURL {
                let scale = result.loraScale
                try store.copyLoRAAdapter(from: adapterURL, into: &result)
                result.loraScale = scale ?? LocalModelRecord.defaultLoRAScale
                copiedAdapter = result.loraRelativePath
            }
            try store.saveDraft(result, replacing: original)
        } catch {
            if let copiedProjector { store.deleteProjectorFile(relativePath: copiedProjector) }
            if let copiedAdapter { store.deleteLoRAFile(relativePath: copiedAdapter) }
            throw error
        }
    }

    mutating func removeProjector() {
        projectorURL = nil
        record.mmprojRelativePath = nil; record.mmprojFileName = nil; record.mmprojFileSize = nil
    }

    mutating func removeAdapter() {
        adapterURL = nil
        record.loraRelativePath = nil; record.loraFileName = nil; record.loraFileSize = nil; record.loraScale = nil
        numbers["loraScale"] = ""
    }
}

enum MacLocalModelInputError: LocalizedError {
    case emptyName
    case invalidNumber(String)
    case noWeights

    var errorDescription: String? {
        switch self {
        case .emptyName: return NSLocalizedString("名称不能为空。", comment: "")
        case .invalidNumber(let title):
            return String(format: NSLocalizedString("%@：请输入范围内的有效数字，或留空使用默认值。", comment: ""), title)
        case .noWeights: return NSLocalizedString("请选择模型权重；mmproj 投影器可与权重一起导入。", comment: "")
        }
    }
}

struct MacLocalModelNumber: Identifiable, @unchecked Sendable {
    enum Storage {
        case integer(WritableKeyPath<LocalModelRecord, Int?>, ClosedRange<Int>)
        case decimal(WritableKeyPath<LocalModelRecord, Double?>, ClosedRange<Double>)
        case seed
    }

    let id: String
    let storage: Storage

    func text(in record: LocalModelRecord) -> String {
        switch storage {
        case .integer(let path, _): return record[keyPath: path].map(String.init) ?? ""
        case .decimal(let path, _): return record[keyPath: path].map { String($0) } ?? ""
        case .seed: return record.seed.map { String($0) } ?? ""
        }
    }

    func apply(_ raw: String, to record: inout LocalModelRecord) throws {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = id == "loraScale" ? NSLocalizedString("LoRA 强度", comment: "") : LocalLLMParameterCatalog.localizedDescriptors().first(where: { $0.id == id })?.title ?? id
        switch storage {
        case .integer(let path, let range):
            if raw.isEmpty { record[keyPath: path] = nil; return }
            guard let value = Int(raw), range.contains(value) else { throw MacLocalModelInputError.invalidNumber(title) }
            record[keyPath: path] = value
        case .decimal(let path, let range):
            if raw.isEmpty { record[keyPath: path] = nil; return }
            guard let value = Double(raw), value.isFinite, range.contains(value) else { throw MacLocalModelInputError.invalidNumber(title) }
            record[keyPath: path] = value
        case .seed:
            if raw.isEmpty { record.seed = nil; return }
            if raw == "-1" { record.seed = UInt32.max; return }
            guard let value = UInt32(raw) else { throw MacLocalModelInputError.invalidNumber(title) }
            record.seed = value
        }
    }

    static let fields: [Self] = [
        .init(id: "contextSize", storage: .integer(\.contextSize, 1...1_048_576)),
        .init(id: "maxOutputTokens", storage: .integer(\.maxOutputTokens, 1...131_072)),
        .init(id: "gpuLayers", storage: .integer(\.gpuLayers, -1...999)),
        .init(id: "batchSize", storage: .integer(\.batchSize, 0...1_048_576)),
        .init(id: "ubatchSize", storage: .integer(\.ubatchSize, 0...1_048_576)),
        .init(id: "seed", storage: .seed),
        .init(id: "temperature", storage: .decimal(\.temperature, 0...5)),
        .init(id: "topK", storage: .integer(\.topK, 0...1_000)),
        .init(id: "topP", storage: .decimal(\.topP, 0...1)),
        .init(id: "minP", storage: .decimal(\.minP, 0...1)),
        .init(id: "repeatLastN", storage: .integer(\.repeatLastN, -1...1_048_576)),
        .init(id: "repeatPenalty", storage: .decimal(\.repeatPenalty, 0...4)),
        .init(id: "frequencyPenalty", storage: .decimal(\.frequencyPenalty, -2...2)),
        .init(id: "presencePenalty", storage: .decimal(\.presencePenalty, -2...2)),
        .init(id: "imageMinTokens", storage: .integer(\.imageMinTokens, -1...1_048_576)),
        .init(id: "imageMaxTokens", storage: .integer(\.imageMaxTokens, -1...1_048_576)),
        .init(id: "loraScale", storage: .decimal(\.loraScale, -100...100))
    ]
}

struct MacLocalModelRow: Identifiable, Sendable {
    let record: LocalModelRecord
    let title: String
    let size: String
    let fileExists: Bool
    let projectorExists: Bool
    let adapterExists: Bool
    var id: UUID { record.id }

    init(record: LocalModelRecord, store: LocalModelStore) {
        self.record = record
        title = record.sanitizedDisplayName
        size = ByteCountFormatter.string(fromByteCount: record.fileSize, countStyle: .file)
        fileExists = store.fileExists(for: record)
        projectorExists = store.mmprojFileExists(for: record)
        adapterExists = store.loraFileExists(for: record)
    }
}

struct MacLocalModelNumberPresentation: Identifiable, Sendable {
    let id: String
    let title: String
    let summary: String

    init(_ field: MacLocalModelNumber) {
        id = field.id
        if id == "loraScale" {
            title = NSLocalizedString("LoRA 强度", comment: "")
            summary = NSLocalizedString("请选择与基础模型架构匹配的 LoRA GGUF。强度 1 使用原始效果，0 保留挂载但不改变输出。", comment: "")
        } else {
            let descriptor = LocalLLMParameterCatalog.localizedDescriptors().first { $0.id == field.id }
            title = descriptor?.title ?? field.id
            summary = descriptor?.summary ?? ""
        }
    }
}

struct MacLocalModelEditorSource: Identifiable, Sendable {
    let row: MacLocalModelRow
    let draft: MacLocalModelDraft
    let numbers: [MacLocalModelNumberPresentation]
    let decoders: [MacLocalModelRow]
    let vadModels: [MacLocalModelRow]
    let decoderIDs: [String]
    let vadIDs: [String]
    let missingDecoderID: String?
    let missingVADID: String?
    let decoderGuide: JSONValue
    let vadGuide: JSONValue
    var id: UUID { row.id }

    init(row: MacLocalModelRow, rows: [MacLocalModelRow]) {
        self.row = row
        draft = MacLocalModelDraft(record: row.record)
        numbers = MacLocalModelNumber.fields.map(MacLocalModelNumberPresentation.init)
        decoders = rows.filter { $0.id != row.id && $0.record.ggufArchitecture == "qwen3" && $0.fileExists }
        vadModels = rows.filter { $0.id != row.id && $0.record.speechArchitecture == .fsmnVAD && $0.fileExists }
        decoderIDs = [""] + decoders.map { $0.id.uuidString }
        vadIDs = [""] + vadModels.map { $0.id.uuidString }
        if let existing = row.record.speechDecoderModelID?.uuidString, !decoderIDs.contains(existing) {
            missingDecoderID = existing
        } else { missingDecoderID = nil }
        if let existing = row.record.speechVADModelID?.uuidString, !vadIDs.contains(existing) {
            missingVADID = existing
        } else { missingVADID = nil }
        decoderGuide = .array(decoders.map { .dictionary(["id": .string($0.id.uuidString), "name": .string($0.title)]) })
        vadGuide = .array(vadModels.map { .dictionary(["id": .string($0.id.uuidString), "name": .string($0.title)]) })
    }
}
