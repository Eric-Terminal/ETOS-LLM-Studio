import ETOSCore
import SwiftUI

@MainActor
struct MacContextCompressionEntry: View {
    @ObservedObject var model: MacContextCompressionModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    var body: some View {
        Button { model.openOptions() } label: {
            Label(NSLocalizedString("压缩为续聊", comment: ""), systemImage: "rectangle.compress.vertical")
        }.disabled(!model.canCompress || !workspace.canModifyCurrentHistory)
    }
}

@MainActor
struct MacContextCompressionHost: ViewModifier {
    @ObservedObject var model: MacContextCompressionModel
    func body(content: Content) -> some View {
        content
            .sheet(item: $model.optionsSession) { MacContextCompressionView(model: model, session: $0) }
            .sheet(isPresented: $model.showsDetails) { MacContinuationDetailView(model: model) }
            .alert(NSLocalizedString("压缩为续聊", comment: ""), isPresented: Binding(
                get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
            )) { Button(NSLocalizedString("好的", comment: ""), role: .cancel) { } }
            message: { Text(model.errorMessage ?? "") }
            .onDisappear { model.cancel(); model.optionsSession = nil; model.showsDetails = false }
    }
}

@MainActor
private struct MacContextCompressionView: View {
    @ObservedObject var model: MacContextCompressionModel
    let session: ChatSession
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var visible = false
    @State private var initialized = false
    @State private var retainedRounds = ContextCompressionOptions.defaultRetainedRoundCount
    @State private var compressionModelID = ""
    @State private var focus = ""
    private let rounds = [0, 2, 4, 6, 10]
    private var available: Bool { model.canEdit && workspace.currentSession?.id == session.id }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "compression-options", title: NSLocalizedString("压缩为续聊", comment: ""),
                        details: NSLocalizedString("Mac 续聊压缩说明正文", comment: ""), documentID: "context-compression", isActive: available)
                    LabeledContent(NSLocalizedString("会话", comment: ""), value: session.name)
                }
                Section {
                    Picker(NSLocalizedString("保留最近原文", comment: ""), selection: $retainedRounds) {
                        ForEach(rounds, id: \.self) { Text(String(format: NSLocalizedString("%d 轮", comment: ""), $0)).tag($0) }
                    }
                    Picker(NSLocalizedString("压缩模型", comment: ""), selection: $compressionModelID) {
                        Text(NSLocalizedString("自动选择", comment: "")).tag("")
                        ForEach(workspace.sessionModelCatalog.rows) { Text($0.title).tag($0.id) }
                        if !compressionModelID.isEmpty && !workspace.sessionModelCatalog.availableIDs.contains(compressionModelID) {
                            Text(NSLocalizedString("已选模型不可用", comment: "")).tag(compressionModelID)
                        }
                    }
                } footer: {
                    Text(NSLocalizedString("最近轮次会保留原文，其余历史将一次性生成续聊摘要，原会话不会改变。", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section(NSLocalizedString("额外侧重点（可选）", comment: "")) {
                    TextEditor(text: $focus).frame(minHeight: 100)
                }
                Section {
                    if let error = model.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
                    if let progress = model.progress {
                        HStack { ProgressView().controlSize(.small); Text(progressTitle(progress)).font(.footnote).foregroundStyle(.secondary) }
                    }
                    if workspace.models.isEmpty {
                        Text(NSLocalizedString("请先激活一个聊天模型。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(NSLocalizedString("系统会创建并切换到一个新的独立会话；原会话和全部消息保持不变，之后仍可继续。", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped).disabled(!available)
            .navigationTitle(NSLocalizedString("压缩为续聊", comment: ""))
            .toolbar {
                Button(model.isWorking ? NSLocalizedString("停止", comment: "") : NSLocalizedString("取消", comment: "")) {
                    if model.isWorking { model.cancel() } else { dismiss() }
                }
                Button(NSLocalizedString("创建续聊会话", comment: "")) {
                    let instruction = focus.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.compress(sessionID: session.id, options: ContextCompressionOptions(retainedRoundCount: retainedRounds,
                        focusInstruction: instruction.isEmpty ? nil : instruction,
                        compressionModelIdentifier: compressionModelID.isEmpty ? nil : compressionModelID))
                }.disabled(!available || !model.canCompress || (!compressionModelID.isEmpty && !workspace.sessionModelCatalog.availableIDs.contains(compressionModelID)))
            }
            .modifier(MacGuideInspector())
            .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-compression-options-\(session.id)-\(model.revision)"),
                title: NSLocalizedString("压缩为续聊", comment: ""),
                documents: [GuideDocumentReference(id: "context-compression", title: "Context Compression")],
                isActive: visible && available,
                settings: [
                    .readOnly("source_session", label: NSLocalizedString("会话", comment: ""), value: { .string(session.id.uuidString) }),
                    .readOnly("requires_manual_creation", label: NSLocalizedString("创建续聊会话", comment: ""), value: { .bool(true) }),
                    .string("retained_rounds", label: NSLocalizedString("保留最近原文", comment: ""), allowedValues: ["0", "2", "4", "6", "10"],
                        get: { String(retainedRounds) }, set: { if let count = Int($0) { retainedRounds = count } }),
                    .string("model", label: NSLocalizedString("压缩模型", comment: ""), allowedValues: workspace.sessionModelCatalog.guideIDs,
                        get: { compressionModelID }, set: { compressionModelID = $0 }),
                    .string("focus", label: NSLocalizedString("额外侧重点（可选）", comment: ""), get: { focus }, set: { focus = $0 })
                ])
        }
        .frame(minWidth: 580, minHeight: 500)
        .interactiveDismissDisabled(model.isWorking)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task {
            guard !initialized else { return }
            initialized = true
            let id = session.preferredModelIdentifier ?? workspace.selectedModelID
            compressionModelID = id.flatMap { workspace.sessionModelCatalog.availableIDs.contains($0) ? $0 : nil } ?? ""
        }
    }

    private func progressTitle(_ progress: ContextCompressionProgress) -> String {
        switch progress.phase {
        case .preparing: NSLocalizedString("正在准备完整对话与附件…", comment: "")
        case .summarizing: NSLocalizedString("正在生成续聊摘要…", comment: "")
        case .saving: NSLocalizedString("正在保存并切换到新会话…", comment: "")
        }
    }
}
