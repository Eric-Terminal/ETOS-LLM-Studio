import ETOSCore
import SwiftUI
import UniformTypeIdentifiers

struct MacSkillImportView: View {
    let isActive: Bool
    @ObservedObject var model: MacSkillsModel
    @Environment(\.dismiss) private var dismiss
    @State private var source = "local"
    @State private var link = ""
    @State private var selectingFile = false
    @State private var replacing = false
    @State private var preview: MacSkillImportPreview?
    @State private var error: String?
    @State private var epoch: UUID
    @State private var visible = false
    private var active: Bool { isActive && visible && epoch == model.epoch && !model.isSuspended }

    init(isActive: Bool, model: MacSkillsModel) {
        self.isActive = isActive; self.model = model
        _epoch = State(initialValue: model.epoch)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "skill-import", title: NSLocalizedString("使用说明", comment: ""),
                                         details: NSLocalizedString("Mac Skills 使用说明", comment: ""), documentID: "agent-skills", isActive: active)
                    Picker(NSLocalizedString("来源", comment: ""), selection: $source) {
                        Text(NSLocalizedString("从本地技能包导入", comment: "")).tag("local")
                        Text(NSLocalizedString("从 GitHub 导入", comment: "")).tag("github")
                        Text(NSLocalizedString("链接导入技能包", comment: "")).tag("url")
                    }
                    if source == "local" {
                        Button(NSLocalizedString("选择文件", comment: "")) { selectingFile = true }
                    } else {
                        TextField(NSLocalizedString("链接", comment: ""), text: $link)
                        Button(NSLocalizedString("预览", comment: "")) {
                            prepare(source == "github" ? .github(link) : .url(link))
                        }.disabled(link.isEmpty)
                    }
                }.disabled(!model.canWrite)
                if model.isPreparingImport {
                    Section {
                        ProgressView(NSLocalizedString("处理中", comment: ""))
                        Button(NSLocalizedString("取消", comment: "")) { model.cancelImport() }
                    }
                }
                if let preview {
                    Section {
                        LabeledContent(NSLocalizedString("名称", comment: ""), value: preview.result.skillName)
                        Text(String(format: NSLocalizedString("文件 (%d)", comment: ""), preview.fileCount))
                        LabeledContent(NSLocalizedString("文件大小", comment: ""), value: preview.size)
                        if preview.expectedVersion != nil {
                            Text(NSLocalizedString("同名技能已存在，导入将替换整个技能目录，并启用该技能。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                        }
                    } header: { Text(NSLocalizedString("导入预览", comment: "")) }
                }
                if model.isWorking { ProgressView(NSLocalizedString("处理中", comment: "")) }
                if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped)
            .disabled(!active)
            .navigationTitle(NSLocalizedString("Agent Skills", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) { model.cancelImport(); dismiss() }.disabled(model.isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("导入", comment: "")) {
                        if preview?.expectedVersion != nil { replacing = true } else { install() }
                    }.disabled(!active || !model.canWrite || preview == nil)
                }
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-skill-import-\(source)-\(epoch)"), title: NSLocalizedString("导入", comment: ""),
                documents: [GuideDocumentReference(id: "agent-skills", title: "Agent Skills")],
                isActive: active && model.canWrite && !selectingFile && !replacing,
                settings: guideSettings
            )
        }
        .frame(minWidth: 540, minHeight: 420)
        .interactiveDismissDisabled(model.isWorking)
        .onAppear { visible = true }
        .onDisappear { visible = false; model.cancelImport() }
        .onChange(of: model.epoch) { _, _ in model.cancelImport(); dismiss() }
        .onChange(of: source) { _, _ in preview = nil; error = nil }
        .onChange(of: link) { _, _ in preview = nil; error = nil }
        .fileImporter(isPresented: $selectingFile, allowedContentTypes: [.folder, .zip, .plainText, UTType(filenameExtension: "md") ?? .plainText]) { result in
            guard active else { return }
            switch result {
            case .success(let url): prepare(.file(url))
            case .failure(let error): self.error = error.localizedDescription
            }
        }
        .confirmationDialog(NSLocalizedString("导入", comment: ""), isPresented: $replacing) {
            Button(NSLocalizedString("导入", comment: ""), role: .destructive) { install() }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
        } message: { Text(NSLocalizedString("同名技能已存在，导入将替换整个技能目录，并启用该技能。", comment: "")) }
    }

    private var guideSettings: [GuidePageSetting] {
        var fields: [GuidePageSetting] = [
            .readOnly("manual_import_required", label: NSLocalizedString("导入", comment: ""), value: { .bool(true) }),
            .readOnly("prepared", label: NSLocalizedString("导入预览", comment: ""), value: { .bool(preview != nil) }),
            .readOnly("name", label: NSLocalizedString("名称", comment: ""), value: { .string(preview?.result.skillName ?? "") }),
            .readOnly("replaces_existing", label: NSLocalizedString("已有同名技能。", comment: ""), value: { .bool(preview?.expectedVersion != nil) }),
            .readOnly("file_count", label: NSLocalizedString("技能文件", comment: ""), value: { .int(preview?.fileCount ?? 0) }),
            .string("source", label: NSLocalizedString("来源", comment: ""), allowedValues: ["local", "github", "url"],
                    get: { source }, set: { source = $0; preview = nil })
        ]
        if source != "local" {
            // 链接可能含临时签名或访问令牌，现有链接不进入向导快照。
            fields.append(.writeOnlyString("url", label: NSLocalizedString("链接", comment: ""),
                                           isConfigured: { !link.isEmpty }, set: { link = $0; preview = nil }))
        }
        return fields
    }

    private func prepare(_ source: MacSkillImportSource) {
        guard active else { return }
        preview = nil; error = nil
        Task {
            guard active else { return }
            do {
                let result = try await model.prepareImport(source, expectedEpoch: epoch)
                if active { preview = result }
            } catch is CancellationError { }
            catch { if active { self.error = error.localizedDescription } }
        }
    }

    private func install() {
        guard active, let preview else { return }
        Task {
            guard active else { return }
            do {
                try await model.mutate(.install(preview.result, expectedVersion: preview.expectedVersion), expectedEpoch: epoch)
                if active { dismiss() }
            } catch { if active { self.error = error.localizedDescription } }
        }
    }
}
