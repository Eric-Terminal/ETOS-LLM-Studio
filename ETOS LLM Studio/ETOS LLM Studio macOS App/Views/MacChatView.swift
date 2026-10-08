import AppKit
import ETOSCore
import SwiftUI
import UniformTypeIdentifiers

struct MacChatView: View {
    @State private var viewportHeight: CGFloat = 0
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var importing = false
    @State private var importContext: UUID?
    @State private var isVisible = false
    @State private var followsLatest = true
    @State private var editingMessage: MacMessageEditTarget?
    @State private var rewritingMessage: MacMessageEditTarget?
    @State private var deletingMessage: MacMessageDeletionTarget?
    @State private var showsRequestControls = false
    @State private var showsBrowser = false
    @State private var linuxJobsTarget: MacLinuxJobsTarget?
    @State private var speechSource: MacSpeechInputSource?

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
                            MacMessageRow(row: row, viewportHeight: viewportHeight)
                                .contextMenu {
                                    Button(NSLocalizedString("复制", comment: "")) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(row.message.content, forType: .string)
                                    }
                                    MacReadAloudButton(model: workspace.tts, message: row.message,
                                        sessionID: workspace.currentSession?.id, isActive: workspace.canManageLocalModels)
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
                .background { MacChatBackgroundView(model: workspace.backgrounds) }
                .onScrollGeometryChange(for: CGFloat.self) { $0.visibleRect.height } action: { _, height in viewportHeight = height }
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
            MacTTSPlaybackView(model: workspace.tts, isActive: workspace.canManageLocalModels).padding(.horizontal)
            MacRoleplayScriptHost(runtime: workspace.roleplayRuntime).padding(.horizontal)
            if configuration.localModelPerformanceMonitorEnabled && workspace.selectedModelIsLocal && workspace.canManageLocalModels {
                MacLocalResourceUsageView()
            }
            if let mode = workspace.temporaryChatMemoryMode {
                Label(mode.isMemoryEnabled ? NSLocalizedString("允许使用记忆", comment: "") : NSLocalizedString("隔离记忆上下文", comment: ""), systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let model = workspace.activeQuestionnaireModel {
                MacQuestionnaireView(model: model)
            } else { composer.modifier(MacComposerAppearance()) }
        }
        .onAppear { isVisible = true; workspace.setRoleplayHostVisible(true) }
        .onDisappear { isVisible = false; importing = false; showsBrowser = false; linuxJobsTarget = nil; speechSource = nil; workspace.setRoleplayHostVisible(false) }
        .onChange(of: workspace.currentSession?.id) { _, _ in showsBrowser = false; linuxJobsTarget = nil; speechSource = nil }
        .onChange(of: workspace.linux.epoch) { _, _ in linuxJobsTarget = nil }
        .onChange(of: workspace.incomingDocuments.contextID) { _, _ in importing = false; importContext = nil }
        .dropDestination(for: URL.self) { urls, _ in
            guard isVisible, workspace.canManageLocalModels else { return false }
            return workspace.receiveDocuments(urls)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard isVisible, workspace.canManageLocalModels, importContext == workspace.incomingDocuments.contextID else { return }
            switch result {
            case .success(let urls): workspace.receiveDocuments(urls)
            case .failure(let error): workspace.errorMessage = error.localizedDescription
            }
        }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-chat-\(workspace.currentSession?.id.uuidString ?? "none")"),
            title: NSLocalizedString("对话", comment: ""),
            documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace"),
                        GuideDocumentReference(id: "local-models", title: "Local Models"), GuideDocumentReference(id: "tts", title: "Text to Speech")],
            isActive: isVisible && workspace.canManageLocalModels && !importing && editingMessage == nil
                && rewritingMessage == nil && deletingMessage == nil && !showsRequestControls && !showsBrowser && linuxJobsTarget == nil && speechSource == nil && !workspace.tts.isExportPanelOpen && !workspace.backgrounds.isPresentingMedia,
            settings: [
                .readOnly("attachment_count", label: NSLocalizedString("附件", comment: ""), value: { .int(workspace.attachments.count) }),
                .readOnly("has_audio_draft", label: NSLocalizedString("语音输入", comment: ""), value: { .bool(workspace.audioAttachment != nil) }),
                .readOnly("tts_playback_status", label: NSLocalizedString("语音输出", comment: ""), value: { .string(workspace.tts.player.playbackState.status.rawValue) }),
                .readOnly("importing_files", label: NSLocalizedString("处理中", comment: ""), value: { .bool(workspace.isImportingAttachments) }),
                .readOnly("imported_local_models", label: NSLocalizedString("本地模型", comment: ""), value: { .int(workspace.incomingDocuments.importedModelCount) }),
                .readOnly("requires_manual_send", label: NSLocalizedString("发送", comment: ""), value: { .bool(true) })
            ]
        )
        .sheet(item: $editingMessage) { target in
            MacMessageEditor(message: target.message, sessionID: target.sessionID)
        }
        .sheet(item: $rewritingMessage) { MacMessageRewriteView(target: $0) }
        .sheet(item: $speechSource) { MacSpeechRecorderView(model: workspace.speechInput, source: $0) }
        .sheet(isPresented: $showsRequestControls) { MacRequestRuntimeView(model: workspace.requestControls) }
        .sheet(item: $linuxJobsTarget) { target in
            NavigationStack {
                MacLinuxJobsView(isActive: isVisible && workspace.canManageLocalModels, runtime: workspace.linux, sessionID: target.sessionID)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("关闭", comment: "")) { linuxJobsTarget = nil } } }
            }.frame(minWidth: 620, minHeight: 480)
        }
        .sheet(isPresented: $showsBrowser) {
            NavigationStack {
                MacBrowserView(sessionID: workspace.currentSession?.id, isTemporary: workspace.temporaryChatMemoryMode != nil,
                               isActive: isVisible && workspace.canManageLocalModels, model: workspace.browser)
            }
        }
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

    private func openSpeechRecorder() {
        guard workspace.canManageLocalModels, let sessionID = workspace.currentSession?.id else { return }
        let model = configuration.sendSpeechAsAudio ? nil : workspace.speechInput.catalog.resolve(configuration.speechModelIdentifier)
        guard configuration.sendSpeechAsAudio || model != nil else {
            workspace.errorMessage = NSLocalizedString("请选择一个语音转文字模型。", comment: "")
            return
        }
        speechSource = MacSpeechInputSource(sessionID: sessionID, composerContextID: workspace.incomingDocuments.contextID,
            format: AudioRecordingFormat(rawValue: configuration.audioRecordingFormat) ?? .aac, model: model)
    }

    private func prepareDeletion(_ message: ChatMessage, kind: MessageHistoryDeletionKind) {
        guard let sessionID = workspace.currentSession?.id else { return }
        deletingMessage = MacMessageDeletionTarget(message: message, sessionID: sessionID, kind: kind)
    }

    private var composer: some View {
        VStack(alignment: .leading) {
            if let audio = workspace.audioAttachment {
                HStack(alignment: .top) {
                    MacAudioPreviewView(attachment: audio, isActive: isVisible && workspace.canManageLocalModels && speechSource == nil)
                    Button(NSLocalizedString("移除附件", comment: ""), role: .destructive) { workspace.removeAudioAttachment() }
                }.buttonStyle(.borderless)
            }
            if workspace.incomingDocuments.importedModelCount > 0 {
                Text(String(format: NSLocalizedString("已导入 %d 个本地模型，可在模型管理中查看。", comment: ""), workspace.incomingDocuments.importedModelCount))
                    .font(.footnote).foregroundStyle(.secondary)
            }
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
                Button {
                    importContext = workspace.incomingDocuments.contextID; importing = true
                } label: {
                    Label(NSLocalizedString("添加附件", comment: ""), systemImage: "paperclip")
                }
                .disabled(workspace.isImportingAttachments || !workspace.canManageLocalModels)
                if configuration.enableSpeechInput {
                    Button { openSpeechRecorder() } label: { Label(NSLocalizedString("语音输入", comment: ""), systemImage: "mic") }
                        .disabled(!workspace.canManageLocalModels || workspace.currentSession == nil)
                }
                if workspace.isImportingAttachments { ProgressView().controlSize(.small) }
                Button { showsRequestControls = true } label: {
                    Label(NSLocalizedString("聊天控制", comment: ""), systemImage: "slider.horizontal.3")
                }
                .disabled(workspace.effectiveModelName == nil || !workspace.canEditRequestControls)
                Button { showsBrowser = true } label: { Label(NSLocalizedString("浏览器", comment: ""), systemImage: "safari") }
                    .disabled(workspace.currentSession == nil || !workspace.canManageLocalModels || workspace.browser.isSuspended)
                Button {
                    if let sessionID = workspace.currentSession?.id { linuxJobsTarget = MacLinuxJobsTarget(sessionID: sessionID) }
                } label: { Label(NSLocalizedString("任务与终端", comment: ""), systemImage: "list.bullet.rectangle") }
                    .disabled(workspace.currentSession == nil || !workspace.canManageLocalModels || workspace.linux.isSuspended)
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

private struct MacLinuxJobsTarget: Identifiable {
    let id = UUID()
    let sessionID: UUID
}

private struct MacMessageRow: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    let row: MacMessagePresentation
    let viewportHeight: CGFloat
    @State private var showsFullContent = false
    @Environment(\.colorScheme) private var colorScheme
    private var outgoing: Bool { row.message.role == .user && row.message.authorKind == .user }
    private var textPalette: MacChatTextPalette {
        row.palette.text[.resolve(outgoing: outgoing, dark: colorScheme == .dark)] ?? .automatic
    }
    private var textColor: Color { textPalette.body ?? (row.message.role == .error ? .red : (outgoing ? .white : .primary)) }

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
                MacMessageReasoningView(activity: row.activity, reasoning: reasoning, viewportHeight: viewportHeight)
            }
            MacMessageWaitingView(activity: row.activity)
            if configuration.enableExperimentalToolResultDisplay, let widget = row.widget {
                MacToolWidgetView(widget: widget, messageID: row.id)
            } else {
                Group {
                    if let preview = row.userPreview, !showsFullContent {
                        MacMessageTextView(text: preview, fallback: textColor)
                    } else { MacMessageTextView(text: row.content, fallback: textColor) }
                }
                .foregroundStyle(textColor)
                if row.userPreview != nil {
                    Button(NSLocalizedString(showsFullContent ? "收起" : "查看完整内容", comment: "")) { showsFullContent.toggle() }
                        .buttonStyle(.link)
                }
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
        .foregroundStyle(outgoing ? Color.white : Color.primary)
        .tint(outgoing ? Color.white : Color.accentColor)
        .environment(\.macChatTextPalette, textPalette)
        .padding()
        .background { MacMessageBubbleBackground(outgoing: outgoing, isError: row.message.role == .error, palette: row.palette) }
        .onChange(of: row.content.id) { _, _ in showsFullContent = false }
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
