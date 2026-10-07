import ETOSCore
import SwiftUI

struct MacMessageRewriteView: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: MacMessageRewriteModel
    @State private var isSubmitting = false

    init(target: MacMessageEditTarget) { _model = StateObject(wrappedValue: MacMessageRewriteModel(target: target)) }

    var body: some View {
        NavigationStack {
            Form {
                if model.isPreparing { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
                Section {
                    Toggle(NSLocalizedString("重写选区", comment: ""), isOn: $model.selectionOnly)
                    if let document = model.document {
                        MacSelectableMessageText(documentID: model.documentID, text: document.plainText) { [weak model] range in
                            model?.updateSelection(range)
                        }
                        .frame(minHeight: 180)
                    }
                    if model.selectionOnly, let selection = model.selection {
                        Text(selection.displayText).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
                    }
                } header: { Text(NSLocalizedString("原文预览", comment: "")) }
                footer: {
                    Text(NSLocalizedString("开启选区重写后，在原文中拖动选择需要修改的文字。重写只替换对应的原文片段，其他内容保持原样。", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    TextEditor(text: $model.instruction).frame(minHeight: 100)
                } header: { Text(NSLocalizedString("重写要求", comment: "")) }
                footer: {
                    Text(model.selectionOnly
                         ? NSLocalizedString("AI 只会生成选区的替换内容，全文会保存为新版本；原版本仍可随时切回。", comment: "")
                         : NSLocalizedString("会发送当前回复、重写要求以及你勾选的其他版本，不会附带历史上下文。", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !model.selectionOnly, !model.references.isEmpty {
                    Section {
                        ForEach(model.references) { row in
                            Toggle(isOn: Binding(get: { model.selectedReferenceIDs.contains(row.id) }, set: { model.toggleReference(row.id, enabled: $0) })) {
                                VStack(alignment: .leading) {
                                    Text(String(format: NSLocalizedString("版本 %d", comment: ""), row.id))
                                    Text(row.preview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                }
                            }
                        }
                    } header: { Text(NSLocalizedString("参考其他版本", comment: "")) }
                }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .disabled(isSubmitting || workspace.isRestoringData)
            .navigationTitle(NSLocalizedString("重写回复", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("重写", comment: "")) { submit() }
                        .disabled(model.isPreparing || model.document == nil || model.instruction.isEmpty || isSubmitting
                                  || model.isPreparingSelection || (model.selectionOnly && model.selection == nil)
                                  || !workspace.canModifyCurrentHistory || !workspace.selectedModelSupportsRewrite)
                }
            }
            .guidePageContext(
                descriptor: GuidePageDescriptor(id: GuidePageID(rawValue: "mac-rewrite-\(model.target.id)"),
                                                title: NSLocalizedString("重写回复", comment: ""),
                                                documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")]),
                snapshot: { GuidePageSnapshot(fields: [
                    "original": .init(label: NSLocalizedString("原文预览", comment: ""), value: .string(GuideSnapshotField.hiddenValue), access: .writeOnly),
                    "instruction": .init(label: NSLocalizedString("重写要求", comment: ""), value: .string(GuideSnapshotField.hiddenValue), access: .writeOnly),
                    "selection_only": .init(label: NSLocalizedString("重写选区", comment: ""), value: .bool(model.selectionOnly), access: .readOnly),
                    "has_selection": .init(label: NSLocalizedString("选中内容", comment: ""), value: .bool(model.selection != nil), access: .readOnly),
                    "reference_count": .init(label: NSLocalizedString("参考其他版本", comment: ""), value: .int(model.selectionOnly ? 0 : model.selectedReferenceIDs.count), access: .readOnly),
                    "manual_submission": .init(label: NSLocalizedString("重写", comment: ""), value: .bool(true), access: .readOnly)
                ]) }
            )
        }
        .modifier(MacGuideInspector())
        .interactiveDismissDisabled(isSubmitting)
        .frame(minWidth: 580, minHeight: 580)
        .task { await model.load(using: workspace.service) }
    }

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                let request = try await model.prepareRequest()
                guard workspace.rewriteMessage(request) else { throw MessageToolCallEditingError.messageChanged }
                dismiss()
            } catch { model.error = error.localizedDescription }
        }
    }
}
