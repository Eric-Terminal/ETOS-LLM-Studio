import ETOSCore
import SwiftUI
import UniformTypeIdentifiers

struct MacLocalModelEditor: View {
    let source: MacLocalModelEditorSource
    @ObservedObject var library: MacLocalModelLibraryModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var draft: MacLocalModelDraft
    @State private var numbers: [MacLocalModelNumberPresentation]
    @State private var epoch: UUID
    @State private var importingProjector = false
    @State private var importingAdapter = false
    @State private var confirmingDelete = false
    @State private var confirmingDiscard = false
    @State private var cliRecord: LocalModelRecord?
    @State private var isPreparing = false
    @State private var preparation: Task<Void, Never>?

    init(source: MacLocalModelEditorSource, library: MacLocalModelLibraryModel) {
        self.source = source; self.library = library
        _draft = State(initialValue: source.draft)
        _numbers = State(initialValue: source.numbers)
        _epoch = State(initialValue: library.epoch)
    }

    private var canEdit: Bool {
        library.canWrite && epoch == library.epoch && workspace.canManageLocalModels && !isPreparing
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "local-model-\(source.id)", title: NSLocalizedString("使用说明", comment: ""),
                                         details: NSLocalizedString("Mac 本地模型管理使用说明", comment: ""), documentID: "local-models")
                    TextField(NSLocalizedString("名称", comment: ""), text: $draft.record.displayName)
                    if !source.row.record.isSpeechAuxiliaryModel {
                        Toggle(NSLocalizedString("加入候选模型", comment: ""), isOn: $draft.record.isActivated)
                    }
                    LabeledContent(NSLocalizedString("文件名", comment: ""), value: source.row.record.fileName)
                    LabeledContent(NSLocalizedString("文件大小", comment: ""), value: source.row.size)
                    if !source.row.fileExists {
                        Text(NSLocalizedString("文件缺失", comment: "")).font(.footnote).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(NSLocalizedString("修改保留为草稿，点击保存后生效。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                if let architecture = source.row.record.speechArchitecture {
                    Section {
                        LabeledContent(NSLocalizedString("GGUF 架构", comment: ""), value: architecture.localizedTitle)
                        if architecture.requiresDecoderModel {
                            Picker(NSLocalizedString("解码模型", comment: ""), selection: uuidBinding(\.speechDecoderModelID)) {
                                Text(NSLocalizedString("无", comment: "")).tag("")
                                ForEach(source.decoders) { Text($0.title).tag($0.id.uuidString) }
                                if let missing = source.missingDecoderID {
                                    Text(NSLocalizedString("文件缺失", comment: "")).tag(missing)
                                }
                            }
                        }
                        if architecture.isTranscriptionModel {
                            Picker(NSLocalizedString("VAD 模型", comment: ""), selection: uuidBinding(\.speechVADModelID)) {
                                Text(NSLocalizedString("无", comment: "")).tag("")
                                ForEach(source.vadModels) { Text($0.title).tag($0.id.uuidString) }
                                if let missing = source.missingVADID {
                                    Text(NSLocalizedString("文件缺失", comment: "")).tag(missing)
                                }
                            }
                        }
                    } header: { Text(NSLocalizedString("本地语音转写", comment: "")) }
                }
                Section {
                    Text(draft.projectorURL?.lastPathComponent ?? draft.record.mmprojFileName ?? NSLocalizedString("无", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                    if draft.projectorURL == nil && draft.record.hasMultimodalProjector && !source.row.projectorExists {
                        Text(NSLocalizedString("文件缺失", comment: "")).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button(NSLocalizedString("选择 mmproj", comment: "")) { importingProjector = true }
                    Button(NSLocalizedString("移除 mmproj", comment: "")) { draft.removeProjector() }
                        .disabled(!draft.record.hasMultimodalProjector && draft.projectorURL == nil)
                } header: { Text(NSLocalizedString("mmproj 投影器", comment: "")) }
                if !source.row.record.isSpeechTranscriptionModel && !source.row.record.isSpeechAuxiliaryModel {
                    Section {
                        Text(draft.adapterURL?.lastPathComponent ?? draft.record.loraFileName ?? NSLocalizedString("无", comment: ""))
                            .font(.footnote).foregroundStyle(.secondary)
                        if draft.adapterURL == nil && draft.record.hasLoRAAdapter && !source.row.adapterExists {
                            Text(NSLocalizedString("文件缺失", comment: "")).font(.footnote).foregroundStyle(.secondary)
                        }
                        Button(NSLocalizedString("选择 LoRA", comment: "")) { importingAdapter = true }
                        Button(NSLocalizedString("移除 LoRA", comment: "")) { draft.removeAdapter() }
                            .disabled(!draft.record.hasLoRAAdapter && draft.adapterURL == nil)
                    } header: { Text(NSLocalizedString("LoRA Adapter", comment: "")) }
                }
                Section {
                    ForEach(numbers) { field in
                        if field.id != "loraScale" || draft.record.hasLoRAAdapter || draft.adapterURL != nil {
                            VStack(alignment: .leading) {
                                TextField(field.title, text: numberBinding(field.id), prompt: Text(NSLocalizedString("默认", comment: "")))
                                Text(field.summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text(NSLocalizedString("生成参数", comment: "")) }
                Section {
                    optionalBoolPicker(NSLocalizedString("KV 缓存 GPU 卸载", comment: ""), path: \.kvOffload)
                    Picker(NSLocalizedString("Flash Attention", comment: ""), selection: flashBinding) {
                        Text(NSLocalizedString("默认", comment: "")).tag("default")
                        Text(NSLocalizedString("自动", comment: "")).tag("auto")
                        Text(NSLocalizedString("已关闭", comment: "")).tag("off")
                        Text(NSLocalizedString("已开启", comment: "")).tag("on")
                    }
                    optionalBoolPicker(NSLocalizedString("忽略 EOS", comment: ""), path: \.ignoreEOS)
                    TextField(NSLocalizedString("Grammar", comment: ""), text: Binding(get: { draft.record.grammar ?? "" }, set: { draft.record.grammar = $0 }), axis: .vertical)
                        .lineLimit(3...10)
                    TextField(NSLocalizedString("llama.cpp-style 参数", comment: ""), text: $draft.record.advancedArguments, axis: .vertical)
                        .lineLimit(3...10)
                    NavigationLink(NSLocalizedString("采样器链实验室", comment: "")) {
                        MacLocalSamplerEditor(chain: draft.record.samplerKinds, isActive: canEdit) { draft.record.samplerKinds = $0 }
                    }
                    Button(NSLocalizedString("参数导入", comment: "")) { prepareCLI() }
                } header: { Text(NSLocalizedString("高级参数", comment: "")) }
                Section {
                    Button(NSLocalizedString("删除权重", comment: ""), role: .destructive) { confirmingDelete = true }
                }
            }
            .formStyle(.grouped)
            .disabled(!canEdit)
            .navigationTitle(NSLocalizedString("本地模型", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) { confirmingDiscard = true }.disabled(library.isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) {
                        let value = draft, token = epoch
                        Task { if await library.save(value, original: source.row.record, expectedEpoch: token) { dismiss() } }
                    }.disabled(!canEdit)
                }
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-local-model-\(source.id)"), title: NSLocalizedString("本地模型", comment: ""),
                documents: [GuideDocumentReference(id: "local-models", title: "Local Models")],
                isActive: canEdit && cliRecord == nil && !importingProjector && !importingAdapter && !confirmingDelete && !confirmingDiscard,
                settings: guideSettings
            )
        }
        .frame(minWidth: 600, minHeight: 640)
        .interactiveDismissDisabled()
        .onDisappear { preparation?.cancel() }
        .onChange(of: library.epoch) { _, _ in dismiss() }
        .task(id: configuration.appLanguage) {
            let values = await Task.detached { MacLocalModelNumber.fields.map(MacLocalModelNumberPresentation.init) }.value
            if !Task.isCancelled { numbers = values }
        }
        .fileImporter(isPresented: $importingProjector, allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data]) { result in
            guard canEdit else { return }
            switch result {
            case .success(let url): draft.projectorURL = url
            case .failure(let error): library.error = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $importingAdapter, allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data]) { result in
            guard canEdit else { return }
            switch result {
            case .success(let url): draft.adapterURL = url
            case .failure(let error): library.error = error.localizedDescription
            }
        }
        .sheet(item: $cliRecord) { record in
            MacLocalCLIEditor(record: record, isActive: canEdit) { updated in
                let projector = draft.projectorURL, adapter = draft.adapterURL
                let adapterScale = draft.numbers["loraScale"]
                draft = MacLocalModelDraft(record: updated)
                draft.projectorURL = projector; draft.adapterURL = adapter
                draft.numbers["loraScale"] = adapterScale
            }
        }
        .confirmationDialog(NSLocalizedString("删除权重", comment: ""), isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                guard canEdit else { return }
                Task { if await library.delete(source.row.record, expectedEpoch: epoch) { dismiss() } }
            }
        } message: { Text(NSLocalizedString("将删除模型权重及不再使用的 mmproj 和 LoRA 文件。此操作不可撤销。", comment: "")) }
        .confirmationDialog(NSLocalizedString("放弃更改", comment: ""), isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button(NSLocalizedString("放弃更改", comment: ""), role: .destructive) { dismiss() }
        }
        .alert(NSLocalizedString("本地模型", comment: ""), isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) { library.error = nil }
        } message: { Text(library.error ?? "") }
    }

    private func numberBinding(_ id: String) -> Binding<String> {
        Binding(get: { draft.numbers[id] ?? "" }, set: { draft.numbers[id] = $0 })
    }

    private func uuidBinding(_ path: WritableKeyPath<LocalModelRecord, UUID?>) -> Binding<String> {
        Binding(get: { draft.record[keyPath: path]?.uuidString ?? "" }, set: { draft.record[keyPath: path] = UUID(uuidString: $0) })
    }

    private func boolBinding(_ path: WritableKeyPath<LocalModelRecord, Bool?>) -> Binding<String> {
        Binding(get: { draft.record[keyPath: path].map { $0 ? "on" : "off" } ?? "default" }, set: {
            draft.record[keyPath: path] = $0 == "default" ? nil : $0 == "on"
        })
    }

    private var flashBinding: Binding<String> {
        Binding(get: {
            switch draft.record.flashAttention {
            case .some(.auto): return "auto"
            case .some(.disabled): return "off"
            case .some(.enabled): return "on"
            case .none: return "default"
            }
        }, set: {
            switch $0 {
            case "auto": draft.record.flashAttention = .auto
            case "off": draft.record.flashAttention = .disabled
            case "on": draft.record.flashAttention = .enabled
            default: draft.record.flashAttention = nil
            }
        })
    }

    private func optionalBoolPicker(_ title: String, path: WritableKeyPath<LocalModelRecord, Bool?>) -> some View {
        Picker(title, selection: boolBinding(path)) {
            Text(NSLocalizedString("默认", comment: "")).tag("default")
            Text(NSLocalizedString("已关闭", comment: "")).tag("off")
            Text(NSLocalizedString("已开启", comment: "")).tag("on")
        }
    }

    private func prepareCLI() {
        guard canEdit else { return }
        isPreparing = true
        let value = draft
        preparation = Task {
            let result = await Task.detached { Result { try value.resolved() } }.value
            guard !Task.isCancelled else { return }
            isPreparing = false
            guard canEdit else { return }
            switch result {
            case .success(let record): cliRecord = record
            case .failure(let error): library.error = error.localizedDescription
            }
        }
    }

    private var guideSettings: [GuidePageSetting] {
        var fields: [GuidePageSetting] = [
            .readOnly("requires_save", label: NSLocalizedString("保存", comment: ""), value: { .bool(true) }),
            .readOnly("file", label: NSLocalizedString("文件名", comment: ""), value: { .string(source.row.record.fileName) }),
            .readOnly("file_available", label: NSLocalizedString("文件可用", comment: ""), value: { .bool(source.row.fileExists) }),
            .readOnly("file_bytes", label: NSLocalizedString("文件大小", comment: ""), value: { .int(Int(source.row.record.fileSize)) }),
            .readOnly("architecture", label: NSLocalizedString("GGUF 架构", comment: ""), value: { .string(source.row.record.ggufArchitecture ?? "") }),
            .readOnly("projector_selected", label: NSLocalizedString("mmproj 投影器", comment: ""), value: { .bool(draft.projectorURL != nil || draft.record.hasMultimodalProjector) }),
            .readOnly("adapter_selected", label: NSLocalizedString("LoRA Adapter", comment: ""), value: { .bool(draft.adapterURL != nil || draft.record.hasLoRAAdapter) }),
            .string("display_name", label: NSLocalizedString("名称", comment: ""), allowsEmpty: false, get: { draft.record.displayName }, set: { draft.record.displayName = $0 }),
            .string("kv_offload", label: NSLocalizedString("KV 缓存 GPU 卸载", comment: ""), allowedValues: ["default", "off", "on"], get: { boolBinding(\.kvOffload).wrappedValue }, set: { boolBinding(\.kvOffload).wrappedValue = $0 }),
            .string("ignore_eos", label: NSLocalizedString("忽略 EOS", comment: ""), allowedValues: ["default", "off", "on"], get: { boolBinding(\.ignoreEOS).wrappedValue }, set: { boolBinding(\.ignoreEOS).wrappedValue = $0 }),
            .string("flash_attention", label: NSLocalizedString("Flash Attention", comment: ""), allowedValues: ["default", "auto", "off", "on"], get: { flashBinding.wrappedValue }, set: { flashBinding.wrappedValue = $0 }),
            .string("grammar", label: NSLocalizedString("Grammar", comment: ""), get: { draft.record.grammar ?? "" }, set: { draft.record.grammar = $0 }),
            .string("arguments", label: NSLocalizedString("llama.cpp-style 参数", comment: ""), get: { draft.record.advancedArguments }, set: { draft.record.advancedArguments = $0 })
        ]
        if !source.row.record.isSpeechAuxiliaryModel {
            fields.append(.bool("activated", label: NSLocalizedString("加入候选模型", comment: ""), get: { draft.record.isActivated }, set: { draft.record.isActivated = $0 }))
        }
        for field in numbers where field.id != "loraScale" || draft.record.hasLoRAAdapter || draft.adapterURL != nil {
            fields.append(.string(field.id, label: field.title, get: { draft.numbers[field.id] ?? "" }, set: { draft.numbers[field.id] = $0 }))
        }
        if source.row.record.speechArchitecture?.requiresDecoderModel == true {
            fields.append(.readOnly("decoder_candidates", label: NSLocalizedString("解码模型", comment: ""), value: { source.decoderGuide }))
            fields.append(.string("decoder", label: NSLocalizedString("解码模型", comment: ""), allowedValues: source.decoderIDs, get: { uuidBinding(\.speechDecoderModelID).wrappedValue }, set: { uuidBinding(\.speechDecoderModelID).wrappedValue = $0 }))
        }
        if source.row.record.isSpeechTranscriptionModel {
            fields.append(.readOnly("vad_candidates", label: NSLocalizedString("VAD 模型", comment: ""), value: { source.vadGuide }))
            fields.append(.string("vad", label: NSLocalizedString("VAD 模型", comment: ""), allowedValues: source.vadIDs, get: { uuidBinding(\.speechVADModelID).wrappedValue }, set: { uuidBinding(\.speechVADModelID).wrappedValue = $0 }))
        }
        return fields
    }
}
