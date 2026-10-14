import ETOSCore
import SwiftUI

struct MacLocalCLIEditor: View {
    let record: LocalModelRecord
    let isActive: Bool
    let apply: (LocalModelRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var input = ""
    @State private var result: LocalLLMCLIStyleImportResult?
    @State private var isWorking = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "local-cli", title: NSLocalizedString("使用说明", comment: ""),
                                         details: NSLocalizedString("Mac 本地模型管理使用说明", comment: ""), documentID: "local-models")
                    TextEditor(text: $input).font(.system(.body, design: .monospaced)).frame(minHeight: 130)
                    Button(NSLocalizedString("解析预览", comment: "")) { parse() }
                        .disabled(isWorking || !isActive)
                } footer: {
                    Text(NSLocalizedString("支持常用 llama.cpp 风格参数，不等于完整 llama.cpp CLI。导入后会转换为 App 的本地配置。", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let result {
                    Section {
                        ForEach(result.appliedParameters) { item in LabeledContent(item.title, value: item.value) }
                    } header: { Text(NSLocalizedString("解析预览", comment: "")) }
                    Section {
                        ForEach(result.unsupportedParameters) { item in
                            LabeledContent(item.option, value: item.message).font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(result.errorParameters) { item in
                            LabeledContent(item.option, value: item.message).font(.footnote).foregroundStyle(.secondary)
                        }
                    } header: { Text(NSLocalizedString("提示", comment: "")) }
                }
            }
            .formStyle(.grouped)
            .disabled(isWorking || !isActive)
            .navigationTitle(NSLocalizedString("参数导入", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("应用到草稿", comment: "")) {
                        guard isActive, let result, result.hasAppliedParameters else { return }
                        apply(result.updatedRecord); dismiss()
                    }.disabled(isWorking || !isActive || result?.hasAppliedParameters != true)
                }
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-local-cli-\(record.id)"), title: NSLocalizedString("参数导入", comment: ""),
                documents: [GuideDocumentReference(id: "local-models", title: "Local Models")],
                isActive: isActive && !isWorking,
                settings: [
                    .string("arguments", label: NSLocalizedString("llama.cpp-style 参数", comment: ""), get: { input }, set: { input = $0 }),
                    .readOnly("requires_apply_and_save", label: NSLocalizedString("保存", comment: ""), value: { .bool(true) }),
                    .readOnly("applied_count", label: NSLocalizedString("解析预览", comment: ""), value: { .int(result?.appliedParameters.count ?? 0) }),
                    .readOnly("error_count", label: NSLocalizedString("提示", comment: ""), value: { .int(result?.errorParameters.count ?? 0) })
                ]
            )
        }
        .frame(minWidth: 550, minHeight: 460)
        .onChange(of: input) { _, _ in result = nil }
        .onChange(of: configuration.appLanguage) { _, _ in task?.cancel(); isWorking = false; result = nil }
        .onDisappear { task?.cancel() }
    }

    private func parse() {
        guard !isWorking, isActive else { return }
        isWorking = true
        let input = input, record = record
        task = Task {
            let value = await Task.detached { LocalLLMCLIStyleArgumentImporter.importArguments(input, into: record) }.value
            guard !Task.isCancelled else { return }
            isWorking = false; result = value
        }
    }
}

struct MacLocalSamplerEditor: View {
    let isActive: Bool
    let apply: ([LocalLLMSamplerKind]?) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var chain: [LocalLLMSamplerKind]?
    @State private var text = ""
    @State private var rows: [MacLocalSamplerRow] = []
    @State private var available: [MacLocalSamplerRow] = []
    @State private var presets: [LocalLLMSamplerChainPreset] = []
    @State private var error: String?
    @State private var isWorking = false
    @State private var isPreparing = true
    @State private var didPrepareText = false
    @State private var isVisible = false
    @State private var parseTask: Task<Void, Never>?
    @State private var preparationID = UUID()

    init(chain: [LocalLLMSamplerKind]?, isActive: Bool, apply: @escaping ([LocalLLMSamplerKind]?) -> Void) {
        _chain = State(initialValue: chain)
        self.isActive = isActive; self.apply = apply
    }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "local-samplers", title: NSLocalizedString("使用说明", comment: ""),
                                     details: NSLocalizedString("Mac 本地模型管理使用说明", comment: ""), documentID: "local-models")
                TextField(NSLocalizedString("等价字符串", comment: ""), text: $text)
                Button(NSLocalizedString("解析预览", comment: "")) { applyText(finish: false) }
                Button(NSLocalizedString("重置为默认", comment: "")) { setChain(nil) }
            }
            Section {
                ForEach(presets) { preset in
                    Button { setChain(preset.samplerKinds == LocalLLMSamplerKind.defaultChain ? nil : preset.samplerKinds) } label: {
                        VStack(alignment: .leading) {
                            Text(preset.title)
                            Text(preset.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
            } header: { Text(NSLocalizedString("预设链", comment: "")) }
            Section {
                ForEach(rows) { row in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(row.title)
                            Text(row.kind.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(row.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { move(row.kind, by: -1) } label: { Image(systemName: "arrow.up") }
                            .accessibilityLabel(NSLocalizedString("上移", comment: "")).disabled(row.isFirst)
                        Button { move(row.kind, by: 1) } label: { Image(systemName: "arrow.down") }
                            .accessibilityLabel(NSLocalizedString("下移", comment: "")).disabled(row.isLast)
                        Button { setChain((chain ?? LocalLLMSamplerKind.defaultChain).filter { $0 != row.kind }) } label: { Image(systemName: "minus.circle") }
                            .accessibilityLabel(NSLocalizedString("移除", comment: ""))
                    }.buttonStyle(.borderless)
                }
            } header: { Text(NSLocalizedString("当前采样链", comment: "")) }
            Section {
                ForEach(available) { row in
                    Button(row.title) { setChain((chain ?? LocalLLMSamplerKind.defaultChain) + [row.kind]) }
                }
            } header: { Text(NSLocalizedString("可用采样器", comment: "")) }
        }
        .formStyle(.grouped)
        .disabled(!isActive || isWorking || isPreparing)
        .navigationTitle(NSLocalizedString("采样器链实验室", comment: ""))
        .toolbar {
            Button(NSLocalizedString("完成", comment: "")) { applyText(finish: true) }.disabled(!isActive || isWorking || isPreparing)
        }
        .task(id: chain) { await prepare() }
        .task(id: configuration.appLanguage) { await prepare() }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false; parseTask?.cancel(); preparationID = UUID() }
        .alert(NSLocalizedString("采样链", comment: ""), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .guideSettingsPageContext(
            id: "mac-local-samplers", title: NSLocalizedString("采样器链实验室", comment: ""),
            documents: [GuideDocumentReference(id: "local-models", title: "Local Models")], isActive: isActive && !isWorking && !isPreparing && isVisible,
            settings: [
                .string("chain_codes", label: NSLocalizedString("等价字符串", comment: ""), get: { text }, set: { text = $0 }),
                .readOnly("requires_apply_and_save", label: NSLocalizedString("保存", comment: ""), value: { .bool(true) })
            ]
        )
    }

    private func prepare() async {
        isPreparing = true
        preparationID = UUID()
        let token = preparationID
        let value = chain
        let prepared = await Task.detached {
            let kinds = value ?? LocalLLMSamplerKind.defaultChain
            let rows = kinds.enumerated().map { MacLocalSamplerRow(kind: $0.element, isFirst: $0.offset == 0, isLast: $0.offset == kinds.count - 1) }
            let available = LocalLLMSamplerKind.allCases.filter { !kinds.contains($0) }.map { MacLocalSamplerRow(kind: $0, isFirst: false, isLast: false) }
            return (rows, available, LocalLLMSamplerChainPreset.allPresets, value.map(LocalLLMSamplerKind.chainString) ?? "")
        }.value
        guard !Task.isCancelled, token == preparationID, chain == value else { return }
        rows = prepared.0; available = prepared.1; presets = prepared.2
        if !didPrepareText { text = prepared.3; didPrepareText = true }
        isPreparing = false
    }

    private func setChain(_ value: [LocalLLMSamplerKind]?) {
        text = value.map(LocalLLMSamplerKind.chainString) ?? ""
        if chain != value { isPreparing = true; chain = value }
    }

    private func move(_ kind: LocalLLMSamplerKind, by offset: Int) {
        var value = chain ?? LocalLLMSamplerKind.defaultChain
        guard let index = value.firstIndex(of: kind), value.indices.contains(index + offset) else { return }
        value.swapAt(index, index + offset); setChain(value)
    }

    private func applyText(finish: Bool) {
        guard isActive, isVisible, !isWorking, !isPreparing else { return }
        isWorking = true
        let input = text
        parseTask = Task {
            let result = await Task.detached { Result { try MacLocalSamplerRow.parse(input) } }.value
            isWorking = false
            guard isActive, isVisible, !Task.isCancelled else { return }
            switch result {
            case .success(let value):
                setChain(value)
                if finish { apply(value); dismiss() }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}

struct MacLocalSamplerRow: Identifiable, Sendable {
    let kind: LocalLLMSamplerKind
    let isFirst: Bool
    let isLast: Bool
    let title: String
    let summary: String
    var id: Int32 { kind.rawValue }

    init(kind: LocalLLMSamplerKind, isFirst: Bool, isLast: Bool) {
        self.kind = kind; self.isFirst = isFirst; self.isLast = isLast
        title = kind.localizedTitle; summary = kind.summary
    }

    static func parse(_ text: String) throws -> [LocalLLMSamplerKind]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let byCode = Dictionary(uniqueKeysWithValues: LocalLLMSamplerKind.allCases.map { ($0.code, $0) })
        var result: [LocalLLMSamplerKind] = []
        for code in trimmed {
            guard let kind = byCode[String(code)], !result.contains(kind) else {
                throw NSError(domain: "MacLocalSampler", code: 1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("采样链请使用不重复的代码 edskypmxta；留空恢复默认。", comment: "")])
            }
            result.append(kind)
        }
        return result
    }
}
