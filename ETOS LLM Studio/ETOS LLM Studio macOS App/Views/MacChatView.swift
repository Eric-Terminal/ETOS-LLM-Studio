import AppKit
import ETOSCore
import SwiftUI
import UniformTypeIdentifiers

struct MacChatView: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @State private var importing = false
    @State private var followsLatest = true
    @State private var editingMessage: MacMessageEditTarget?
    @State private var rewritingMessage: MacMessageEditTarget?
    @State private var deletingMessage: MacMessageDeletionTarget?
    @State private var showsRequestControls = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        if workspace.messages.isEmpty {
                            ContentUnavailableView {
                                Label(NSLocalizedString("新的对话", comment: ""), systemImage: "bubble.left.and.bubble.right")
                            } description: {
                                Text(NSLocalizedString("选择模型后发送消息。", comment: ""))
                            }
                        }
                        ForEach(workspace.messages) { row in
                            MacMessageRow(row: row)
                                .contextMenu {
                                    Button(NSLocalizedString("复制", comment: "")) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(row.message.content, forType: .string)
                                    }
                                    Button(NSLocalizedString("编辑", comment: "")) {
                                        if let sessionID = workspace.currentSession?.id { editingMessage = MacMessageEditTarget(message: row.message, sessionID: sessionID) }
                                    }
                                        .disabled(!workspace.canModifyCurrentHistory)
                                    if row.message.role != .system {
                                        Button(NSLocalizedString("重新生成", comment: "")) { workspace.retryMessage(row.message) }
                                            .disabled(!workspace.canModifyCurrentHistory || workspace.effectiveModelName == nil)
                                    }
                                    if row.message.canPrefill && workspace.selectedModelSupportsPrefill {
                                        Button(NSLocalizedString("预填充续写", comment: "")) { workspace.retryMessage(row.message, prefill: true) }
                                            .disabled(!workspace.canModifyCurrentHistory)
                                    }
                                    Menu(NSLocalizedString("从此处创建分支", comment: "")) {
                                        Button(NSLocalizedString("仅复制消息历史", comment: "")) { workspace.branchSession(at: row.message, copyPrompts: false) }
                                        Button(NSLocalizedString("复制消息历史和提示词", comment: "")) { workspace.branchSession(at: row.message) }
                                    }
                                    .disabled(!workspace.canModifyCurrentHistory)
                                    if row.canRewrite {
                                        Button(NSLocalizedString("重写回复", comment: "")) {
                                            if let sessionID = workspace.currentSession?.id { rewritingMessage = MacMessageEditTarget(message: row.message, sessionID: sessionID) }
                                        }
                                        .disabled(!workspace.canModifyCurrentHistory || !workspace.selectedModelSupportsRewrite)
                                    }
                                    if !row.versionOptions.isEmpty {
                                        Button(NSLocalizedString("删除当前版本", comment: ""), role: .destructive) { prepareDeletion(row.message, kind: .currentVersion) }
                                            .disabled(!workspace.canModifyCurrentHistory)
                                        Button(NSLocalizedString("删除所有版本", comment: ""), role: .destructive) { prepareDeletion(row.message, kind: .allVersions) }
                                            .disabled(!workspace.canModifyCurrentHistory)
                                    }
                                    Button(NSLocalizedString("删除", comment: ""), role: .destructive) { prepareDeletion(row.message, kind: .message) }
                                        .disabled(!workspace.canModifyCurrentHistory)
                                }
                        }
                        Color.clear.frame(height: 1).id("latest-message")
                    }
                    .padding()
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height - geometry.visibleRect.maxY < 100
                } action: { _, nearEnd in followsLatest = nearEnd }
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, _ in
                    if followsLatest { proxy.scrollTo("latest-message", anchor: .bottom) }
                }
                .onChange(of: workspace.messages.count) { _, _ in
                    if followsLatest { proxy.scrollTo("latest-message", anchor: .bottom) }
                }
                .onChange(of: workspace.currentSession?.id) { _, _ in
                    followsLatest = true
                    proxy.scrollTo("latest-message", anchor: .bottom)
                }
            }
            Divider()
            MacRoleplayScriptHost(runtime: workspace.roleplayRuntime).padding(.horizontal)
            if let mode = workspace.temporaryChatMemoryMode {
                Label(mode.isMemoryEnabled ? NSLocalizedString("允许使用记忆", comment: "") : NSLocalizedString("隔离记忆上下文", comment: ""), systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let model = workspace.activeQuestionnaireModel {
                MacQuestionnaireView(model: model)
            } else { composer }
        }
        .onAppear { workspace.setRoleplayHostVisible(true) }
        .onDisappear { workspace.setRoleplayHostVisible(false) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await workspace.importAttachments(urls) }
            case .failure(let error): workspace.errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $editingMessage) { target in
            MacMessageEditor(message: target.message, sessionID: target.sessionID)
        }
        .sheet(item: $rewritingMessage) { MacMessageRewriteView(target: $0) }
        .sheet(isPresented: $showsRequestControls) { MacRequestRuntimeView(model: workspace.requestControls) }
        .confirmationDialog(NSLocalizedString("删除消息", comment: ""), isPresented: Binding(
            get: { deletingMessage != nil }, set: { if !$0 { deletingMessage = nil } }
        ), titleVisibility: .visible) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                if let deletingMessage { workspace.deleteMessage(deletingMessage) }
                deletingMessage = nil
            }
        } message: {
            switch deletingMessage?.kind {
            case .allVersions: Text(NSLocalizedString("删除后将无法恢复这条消息的所有版本。", comment: ""))
            case .currentVersion: Text(NSLocalizedString("删除后将无法恢复此版本的内容。", comment: ""))
            default: EmptyView()
            }
        }
        .guideSettingsPageContext(
            id: "mac-message-deletion", title: NSLocalizedString("删除消息", comment: ""),
            documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: deletingMessage != nil,
            settings: [
                .readOnly("session_id", label: NSLocalizedString("对话", comment: ""), value: { .string(deletingMessage?.sessionID.uuidString ?? "") }),
                .readOnly("operation", label: NSLocalizedString("删除", comment: ""), value: { .string(deletingMessage?.kind.rawValue ?? "") })
            ]
        )
    }

    private func prepareDeletion(_ message: ChatMessage, kind: MessageHistoryDeletionKind) {
        guard let sessionID = workspace.currentSession?.id else { return }
        deletingMessage = MacMessageDeletionTarget(message: message, sessionID: sessionID, kind: kind)
    }

    private var composer: some View {
        VStack(alignment: .leading) {
            if !workspace.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(workspace.attachments) { attachment in
                            HStack {
                                Label(attachment.fileName, systemImage: attachment.image == nil ? "doc" : "photo")
                                Button { workspace.removeAttachment(attachment.id) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .help(NSLocalizedString("移除附件", comment: ""))
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            TextEditor(text: $workspace.draft)
                .font(.body)
                .frame(minHeight: 60, maxHeight: 140)
                .accessibilityLabel(NSLocalizedString("消息", comment: ""))
            HStack {
                Button { importing = true } label: {
                    Label(NSLocalizedString("添加附件", comment: ""), systemImage: "paperclip")
                }
                .disabled(workspace.isImportingAttachments)
                if workspace.isImportingAttachments { ProgressView().controlSize(.small) }
                Button { showsRequestControls = true } label: {
                    Label(NSLocalizedString("聊天控制", comment: ""), systemImage: "slider.horizontal.3")
                }
                .disabled(workspace.effectiveModelName == nil || !workspace.canEditRequestControls)
                Spacer()
                if workspace.isGenerating || workspace.isPreparingSend {
                    Button { workspace.stop() } label: {
                        Label(NSLocalizedString("停止生成", comment: ""), systemImage: "stop.fill")
                    }
                } else {
                    Button { workspace.send() } label: {
                        Label(NSLocalizedString("发送", comment: ""), systemImage: "arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!workspace.canSend)
                }
            }
        }
        .padding()
    }
}

private struct MacMessageRow: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    let row: MacMessagePresentation

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(row.roleTitle).font(.caption).foregroundStyle(.secondary)
                if row.activity.isActive { ProgressView().controlSize(.mini) }
                Spacer()
                if !row.versionOptions.isEmpty {
                    Menu {
                        ForEach(row.versionOptions) { option in
                            Button { workspace.selectVersion(option.id, of: row.message) } label: {
                                if option.id == row.versionIndex { Label(option.title, systemImage: "checkmark") }
                                else { Text(option.title) }
                            }
                            .disabled(option.id == row.versionIndex)
                        }
                    } label: { Text(row.versionLabel) }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(!workspace.canModifyCurrentHistory)
                }
            }
            if row.activity.hasReasoning, let reasoning = row.reasoning {
                MacMessageReasoningView(activity: row.activity, reasoning: reasoning)
            }
            MacMessageWaitingView(activity: row.activity)
            if let widget = row.widget {
                MacToolWidgetView(widget: widget, messageID: row.id)
            } else {
                Text(row.content)
                    .textSelection(.enabled)
                    .foregroundStyle(row.message.role == .error ? Color.red : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(row.roleplayDocuments) { document in
                    MacRoleplayHTMLView(document: document, runtime: workspace.roleplayRuntime)
                }
            }
            ForEach(row.toolCalls, id: \.id) { tool in
                DisclosureGroup(tool.toolName) {
                    Text(tool.arguments).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            ForEach(row.attachments) { attachment in
                if attachment.isImage {
                    MacAttachmentImage(url: attachment.url)
                }
                Button {
                    NSWorkspace.shared.open(attachment.url)
                } label: {
                    Label(attachment.url.lastPathComponent, systemImage: attachment.isImage ? "photo" : "doc")
                }
                .buttonStyle(.link)
            }
        }
        .padding(.vertical)
    }
}

private struct MacAttachmentImage: View {
    let url: URL
    @State private var image: NSImage?
    @State private var didFinishLoading = false
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 320)
            } else if didFinishLoading {
                Label(NSLocalizedString("无法加载图片", comment: ""), systemImage: "photo.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary)
            } else { ProgressView().controlSize(.small) }
        }
        .task(id: url) {
            didFinishLoading = false
            image = nil
            let result = await DisplayImageLoader.shared.image(
                at: url, target: DisplayImageTarget(size: CGSize(width: 600, height: 320), scale: 2, fillsBounds: false)
            )
            guard !Task.isCancelled else { return }
            image = result?.image
            didFinishLoading = true
        }
    }
}

private struct MacMessageEditor: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    let message: ChatMessage
    let sessionID: UUID
    @State private var content: String
    @State private var isSaving = false
    @State private var error: String?

    init(message: ChatMessage, sessionID: UUID) {
        self.message = message
        self.sessionID = sessionID
        _content = State(initialValue: message.content)
    }

    var body: some View {
        VStack {
            Text(NSLocalizedString("编辑消息", comment: "")).font(.headline)
            TextEditor(text: $content).font(.body)
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            HStack {
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) { dismiss() }
                Spacer()
                Button(NSLocalizedString("保存", comment: "")) {
                    isSaving = true
                    Task {
                        defer { isSaving = false }
                        do { try await workspace.updateMessage(message, content: content, sessionID: sessionID); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
            }
        }
        .padding()
        .disabled(isSaving || workspace.isRestoringData)
        .guidePageContext(
            descriptor: GuidePageDescriptor(
                id: GuidePageID(rawValue: "mac-message-editor-\(sessionID)-\(message.id)"),
                title: NSLocalizedString("编辑消息", comment: ""),
                documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")]
            ),
            snapshot: { GuidePageSnapshot(fields: [
                "content": GuideSnapshotField(label: NSLocalizedString("消息", comment: ""), value: .string(GuideSnapshotField.hiddenValue), access: .writeOnly),
                "editing_mode": GuideSnapshotField(label: NSLocalizedString("编辑方式", comment: ""), value: .string("manual_draft_until_save"), access: .readOnly),
                "saving": GuideSnapshotField(label: NSLocalizedString("保存中", comment: ""), value: .bool(isSaving), access: .readOnly)
            ]) }
        )
        .modifier(MacGuideInspector())
        .interactiveDismissDisabled(isSaving)
        .frame(minWidth: 500, minHeight: 350)
    }
}
