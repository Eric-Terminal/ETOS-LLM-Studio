import AppKit
import ETOSCore
import SwiftUI
import UniformTypeIdentifiers

struct MacChatView: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @State private var importing = false
    @State private var followsLatest = true
    @State private var editingMessage: ChatMessage?
    @State private var deletingMessage: ChatMessage?

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
                                    Button(NSLocalizedString("编辑", comment: "")) { editingMessage = row.message }
                                        .disabled(workspace.isGenerating)
                                    Button(NSLocalizedString("删除", comment: ""), role: .destructive) { deletingMessage = row.message }
                                        .disabled(workspace.isGenerating)
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
            if let model = workspace.activeQuestionnaireModel {
                MacQuestionnaireView(model: model)
            } else { composer }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await workspace.importAttachments(urls) }
            case .failure(let error): workspace.errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $editingMessage) { message in
            MacMessageEditor(message: message)
        }
        .confirmationDialog(NSLocalizedString("删除消息", comment: ""), isPresented: Binding(
            get: { deletingMessage != nil }, set: { if !$0 { deletingMessage = nil } }
        ), titleVisibility: .visible) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                if let deletingMessage { workspace.deleteMessage(deletingMessage) }
                deletingMessage = nil
            }
        }
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
    let row: MacMessagePresentation

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(row.roleTitle).font(.caption).foregroundStyle(.secondary)
                if row.message.isReceivingStream { ProgressView().controlSize(.mini) }
                Spacer()
            }
            if let reasoning = row.reasoning, !reasoning.isEmpty {
                DisclosureGroup(NSLocalizedString("思考过程", comment: "")) {
                    Text(reasoning).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if let widget = row.widget {
                MacToolWidgetView(widget: widget, messageID: row.id)
            } else {
                Text(row.content)
                    .textSelection(.enabled)
                    .foregroundStyle(row.message.role == .error ? Color.red : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
    @State private var content: String
    @State private var isSaving = false
    @State private var error: String?

    init(message: ChatMessage) { self.message = message; _content = State(initialValue: message.content) }

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
                        do { try await workspace.updateMessage(message, content: content); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
            }
        }
        .padding()
        .guidePageContext(
            descriptor: GuidePageDescriptor(
                id: GuidePageID(rawValue: "mac-message-editor-\(message.id)"),
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
        .frame(minWidth: 500, minHeight: 350)
    }
}
