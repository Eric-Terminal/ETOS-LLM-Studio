import AppKit
import ETOSCore
import SwiftUI
import UniformTypeIdentifiers

struct MacTranscriptExportTarget: Identifiable {
    let session: ChatSession
    var upToMessageID: UUID? = nil
    let id = UUID()
}

private struct MacExportMessageRow: Identifiable, Sendable {
    let id: UUID
    let text: String
}

struct MacTranscriptExportView: View {
    let target: MacTranscriptExportTarget
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var format = ChatTranscriptExportFormat.markdown
    @State private var includeReasoning = true
    @State private var includeSystem = true
    @State private var selectMessages = false
    @State private var selected = Set<UUID>()
    @State private var messages: [ChatMessage] = []
    @State private var rows: [MacExportMessageRow] = []
    @State private var context: ConversationContinuationContext?
    @State private var ready = false
    @State private var exporting = false
    @State private var error: String?
    @State private var operation: Task<Void, Never>?
    @State private var panel: NSSavePanel?
    private var available: Bool { workspace.canManageLocalModels && workspace.currentSession?.id == target.session.id }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "transcript-export", title: NSLocalizedString("使用说明", comment: ""),
                        details: NSLocalizedString("Mac 对话导出使用说明", value: "Export the whole conversation, the history up to a message, or selected messages. Choose PDF, Markdown, TXT, or a PNG image. Export uses a snapshot; the saved file may contain private messages and attachments. PNG excludes system prompts. Select a destination to save the file.", comment: ""),
                        documentID: "macos-workspace", isActive: available)
                    Picker(NSLocalizedString("格式", comment: ""), selection: $format) {
                        ForEach(ChatTranscriptExportFormat.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Toggle(NSLocalizedString("包含思考过程", comment: ""), isOn: $includeReasoning)
                    Toggle(NSLocalizedString("包含系统提示词", comment: ""), isOn: $includeSystem).disabled(format == .png)
                    Toggle(NSLocalizedString("选择消息", comment: ""), isOn: $selectMessages)
                }
                if selectMessages {
                    Section(NSLocalizedString("消息", comment: "")) {
                        ForEach(rows) { row in
                            Toggle(row.text, isOn: Binding(get: { selected.contains(row.id) }, set: {
                                if $0 { selected.insert(row.id) } else { selected.remove(row.id) }
                            }))
                        }
                    }
                }
                if !ready || exporting { ProgressView() }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped).disabled(exporting || !available)
            .navigationTitle(NSLocalizedString("导出对话", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { operation?.cancel(); panel?.cancel(nil); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("导出", comment: "")) { export() }
                        .disabled(!ready || exporting || !available || (selectMessages && selected.isEmpty))
                }
            }
            .task {
                guard available, let service = workspace.service else { return }
                let continuation = workspace.contextCompression.presentation?.context
                let prepared = await Task.detached(priority: .utility) {
                    let all = service.messagesSnapshot(for: target.session.id)
                    let end = target.upToMessageID.flatMap { id in all.firstIndex { $0.id == id } }
                    let scoped = end.map { Array(all[...$0]) } ?? all
                    return (all, scoped.map { MacExportMessageRow(id: $0.id, text: String($0.content.prefix(120))) })
                }.value
                guard !Task.isCancelled, available else { return }
                messages = prepared.0; rows = prepared.1; context = continuation; ready = true
            }
            .onChange(of: available) { _, active in if !active { operation?.cancel(); panel?.cancel(nil); dismiss() } }
            .onDisappear { operation?.cancel(); panel?.cancel(nil) }
            .guideSettingsPageContext(id: "mac-transcript-export", title: NSLocalizedString("导出对话", comment: ""),
                documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")], isActive: available && panel == nil,
                settings: [
                    .string("format", label: NSLocalizedString("格式", comment: ""), allowedValues: ["pdf", "markdown", "text", "png"], get: { format.rawValue }, set: { format = ChatTranscriptExportFormat(rawValue: $0) ?? .markdown }),
                    .bool("include_reasoning", label: NSLocalizedString("包含思考过程", comment: ""), get: { includeReasoning }, set: { includeReasoning = $0 }),
                    .bool("include_system_prompt", label: NSLocalizedString("包含系统提示词", comment: ""), get: { includeSystem }, set: { includeSystem = $0 }),
                    .bool("select_messages", label: NSLocalizedString("选择消息", comment: ""), get: { selectMessages }, set: { selectMessages = $0 }),
                    .readOnly("selection_count", label: NSLocalizedString("消息", comment: ""), value: { .int(selected.count) }),
                    .readOnly("up_to_message", label: NSLocalizedString("导出", comment: ""), value: { .bool(target.upToMessageID != nil) })
                ])
        }
        .frame(minWidth: 540, minHeight: 480).modifier(MacGuideInspector())
        .interactiveDismissDisabled(exporting)
    }

    private func export() {
        guard ready, available, !exporting else { return }
        let format = format, messages = messages, context = context
        let reasoning = includeReasoning, system = includeSystem, selection = selectMessages ? selected : nil
        var style = ChatTranscriptImageStyle()
        style.prefersDarkAppearance = colorScheme == .dark
        let imageStyle = style
        exporting = true; error = nil
        operation = Task {
            defer { exporting = false; panel = nil }
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    try ChatTranscriptExportService().export(session: target.session, messages: messages, format: format,
                        includeReasoning: reasoning, includeSystemPrompt: system, continuationContext: context,
                        upToMessageID: target.upToMessageID, selectedMessageIDs: selection, imageStyle: imageStyle)
                }.value
                guard !Task.isCancelled, available else { return }
                let save = NSSavePanel(); panel = save
                save.nameFieldStringValue = output.suggestedFileName
                if let type = UTType(filenameExtension: format.fileExtension) { save.allowedContentTypes = [type] }
                let response = await withCheckedContinuation { continuation in save.begin { continuation.resume(returning: $0) } }
                guard response == .OK, let url = save.url, !Task.isCancelled, available else { return }
                try await Task.detached(priority: .utility) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    try output.data.write(to: url, options: .atomic)
                }.value
                if !Task.isCancelled { dismiss() }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
