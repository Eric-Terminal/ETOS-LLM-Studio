import AppKit
import ETOSCore
import SwiftUI
import UniformTypeIdentifiers

struct MacShortcutImportView: View {
    let isActive: Bool
    @ObservedObject var model: MacShortcutToolsModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var selectingFile = false
    @State private var preview: MacShortcutImportPreview?
    @State private var summary: ShortcutImportSummary?
    @State private var error: String?
    @State private var visible = false
    @State private var epoch: UUID
    private var active: Bool { isActive && visible && epoch == model.epoch && !model.isSuspended }

    init(isActive: Bool, model: MacShortcutToolsModel) {
        self.isActive = isActive; self.model = model
        _epoch = State(initialValue: model.epoch)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "shortcut-import", title: NSLocalizedString("使用说明", comment: ""),
                                         details: NSLocalizedString("Mac 快捷指令导入使用说明", comment: ""), documentID: "shortcut-tools", isActive: active)
                    Button(NSLocalizedString("从剪贴板导入清单", comment: "")) {
                        guard let text = NSPasteboard.general.string(forType: .string) else {
                            error = ShortcutToolError.clipboardEmpty.localizedDescription; return
                        }
                        prepare(.text(text))
                    }
                    Button(NSLocalizedString("从文件导入", comment: "")) { selectingFile = true }
                    TextEditor(text: $text).font(.system(.footnote, design: .monospaced)).frame(minHeight: 150)
                        .accessibilityLabel(NSLocalizedString("内容", comment: ""))
                    Button(NSLocalizedString("预览", comment: "")) { prepare(.text(text)) }.disabled(text.isEmpty)
                } footer: {
                    Text(NSLocalizedString("预览会读取分享链接并使用当前模型生成描述，不会运行快捷指令。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }.disabled(!model.canWrite)
                if model.isPreparing {
                    Section {
                        if let progress = model.progress, progress.total > 0 {
                            ProgressView(value: Double(progress.completed), total: Double(progress.total))
                            Text(String(format: NSLocalizedString("解析进度 %d / %d", comment: ""), progress.completed, progress.total))
                                .font(.caption).foregroundStyle(.secondary)
                            if let name = progress.currentName {
                                Text(String(format: NSLocalizedString("正在处理：%@", comment: ""), name)).font(.caption).foregroundStyle(.secondary)
                            }
                        } else { ProgressView(NSLocalizedString("处理中", comment: "")) }
                        Button(NSLocalizedString("取消", comment: "")) { model.cancelPreparation() }
                    }
                }
                if let preview {
                    Section {
                        LabeledContent(NSLocalizedString("新增", comment: ""), value: String(preview.source.tools.count))
                        LabeledContent(NSLocalizedString("跳过", comment: ""), value: String(preview.source.skippedCount))
                        LabeledContent(NSLocalizedString("无效", comment: ""), value: String(preview.source.invalidCount))
                        ForEach(preview.rows) { row in
                            VStack(alignment: .leading) {
                                Text(row.title)
                                Text(row.description).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        ForEach(preview.source.conflictNames, id: \.self) { name in Text(name).font(.caption).foregroundStyle(.secondary) }
                    } header: { Text(NSLocalizedString("导入预览", comment: "")) }
                }
                if let summary {
                    Section {
                        LabeledContent(NSLocalizedString("新增", comment: ""), value: String(summary.importedCount))
                        LabeledContent(NSLocalizedString("跳过", comment: ""), value: String(summary.skippedCount))
                        LabeledContent(NSLocalizedString("无效", comment: ""), value: String(summary.invalidCount))
                        ForEach(summary.conflictNames, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    } header: { Text(NSLocalizedString("最近导入结果", comment: "")) }
                }
                if model.isWorking { ProgressView(NSLocalizedString("处理中", comment: "")) }
                if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped)
            .disabled(!active)
            .navigationTitle(NSLocalizedString("导入", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("关闭", comment: "")) { model.cancelPreparation(); dismiss() }.disabled(model.isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("导入", comment: "")) { install() }
                        .disabled(!active || !model.canWrite || preview?.source.tools.isEmpty != false)
                }
            }
            .guidePageContext(
                descriptor: GuidePageDescriptor(
                    id: GuidePageID(rawValue: "mac-shortcut-import-\(epoch)"), title: NSLocalizedString("导入", comment: ""),
                    documents: [GuideDocumentReference(id: "shortcut-tools", title: "Shortcuts")]),
                isActive: active && model.canWrite && !selectingFile,
                // 原始清单可能包含令牌或任意扩展；向导只解释预览状态，不读取或改写清单。
                snapshot: { GuidePageSnapshot(fields: [
                    "has_manifest_draft": GuideSnapshotField(label: NSLocalizedString("内容", comment: ""), value: .bool(!text.isEmpty), access: .readOnly),
                    "requires_manual_preview_and_import": GuideSnapshotField(label: NSLocalizedString("导入", comment: ""), value: .bool(true), access: .readOnly),
                    "prepared_tools": GuideSnapshotField(label: NSLocalizedString("导入预览", comment: ""), value: preview?.guideRows ?? .array([]), access: .readOnly),
                    "imported_count": GuideSnapshotField(label: NSLocalizedString("新增", comment: ""), value: .int(summary?.importedCount ?? 0), access: .readOnly),
                    "skipped_count": GuideSnapshotField(label: NSLocalizedString("跳过", comment: ""), value: .int(summary?.skippedCount ?? preview?.source.skippedCount ?? 0), access: .readOnly),
                    "invalid_count": GuideSnapshotField(label: NSLocalizedString("无效", comment: ""), value: .int(summary?.invalidCount ?? preview?.source.invalidCount ?? 0), access: .readOnly)
                ]) }
            )
        }
        .frame(minWidth: 620, minHeight: 540)
        .interactiveDismissDisabled(model.isWorking)
        .onAppear { visible = true }
        .onDisappear { visible = false; model.cancelPreparation() }
        .onChange(of: model.epoch) { _, _ in dismiss() }
        .onChange(of: text) { _, _ in preview = nil; summary = nil; error = nil }
        .fileImporter(isPresented: $selectingFile, allowedContentTypes: [.json, .plainText]) { result in
            guard active else { return }
            switch result {
            case .success(let url): prepare(.file(url))
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }

    private func prepare(_ source: MacShortcutImportSource) {
        guard active else { return }
        preview = nil; summary = nil; error = nil
        Task {
            guard active else { return }
            do {
                let prepared = try await model.prepare(source, expectedEpoch: epoch)
                if active { preview = prepared }
            } catch is CancellationError { }
            catch { if active { self.error = error.localizedDescription } }
        }
    }

    private func install() {
        guard active, let preview else { return }
        Task {
            guard active else { return }
            do {
                let result = try await model.install(preview, expectedEpoch: epoch)
                if active { summary = result; self.preview = nil }
            } catch { if active { self.error = error.localizedDescription } }
        }
    }
}
