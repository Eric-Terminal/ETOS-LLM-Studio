// ============================================================================
// ChatView.swift
// ============================================================================
// 聊天主界面 (iOS)
// - 显示消息列表、底部固定输入框
// - 支持长按消息调出操作菜单
// - 使用系统风格的留白与材质，贴合 Apple Design
// ============================================================================

import SwiftUI
import MarkdownUI
import Shared
import UIKit
import PhotosUI
import AVFoundation

struct ChatView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var showScrollToBottom = false
    @State private var editingMessage: ChatMessage?
    @State private var editingContent: String = ""
    @State private var messageInfo: MessageInfoPayload?
    @State private var showBranchOptions = false
    @State private var messageToBranch: ChatMessage?
    @FocusState private var composerFocused: Bool
    @AppStorage("chat.composer.draft") private var draftText: String = ""
    
    private let scrollBottomAnchorID = "chat-scroll-bottom"
    
    var body: some View {
        ZStack {
            backgroundLayer
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        sessionHeader
                        ForEach(viewModel.messages) { message in
                            ChatBubble(
                                message: message,
                                isReasoningExpanded: Binding(
                                    get: { viewModel.reasoningExpandedState[message.id, default: false] },
                                    set: { viewModel.reasoningExpandedState[message.id] = $0 }
                                ),
                                isToolCallsExpanded: Binding(
                                    get: { viewModel.toolCallsExpandedState[message.id, default: false] },
                                    set: { viewModel.toolCallsExpandedState[message.id] = $0 }
                                ),
                                enableMarkdown: viewModel.enableMarkdown,
                                enableBackground: viewModel.enableBackground
                            )
                            .id(message.id)
                            .contextMenu {
                                contextMenu(for: message)
                            }
                            .onAppear {
                                if message.id == viewModel.messages.last?.id {
                                    showScrollToBottom = false
                                }
                            }
                            .onDisappear {
                                if message.id == viewModel.messages.last?.id {
                                    showScrollToBottom = true
                                }
                            }
                        }
                    }
                    
                    Color.clear
                        .frame(height: 1)
                        .id(scrollBottomAnchorID)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 140)
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        composerFocused = false
                    }
                )
                .onChange(of: viewModel.messages.count) { _, _ in
                    guard !viewModel.messages.isEmpty else { return }
                    guard !showScrollToBottom else { return }
                    scrollToBottom(proxy: proxy)
                }
                .overlay(alignment: .bottomTrailing) {
                    if showScrollToBottom {
                        Button {
                            scrollToBottom(proxy: proxy)
                        } label: {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 22, weight: .medium))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.tint)
                                .padding(10)
                                .background(.regularMaterial, in: Circle())
                        }
                        .padding(.trailing, 20)
                        .padding(.bottom, 140)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel("滚动到底部")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            MessageComposerView(
                text: Binding(
                    get: { draftText },
                    set: { newValue in
                        draftText = newValue
                        viewModel.userInput = newValue
                    }
                ),
                isSending: viewModel.isSendingMessage,
                sendAction: {
                    guard viewModel.canSendMessage else { return }
                    viewModel.sendMessage()
                    draftText = ""
                },
                focus: $composerFocused
            )
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .background(.ultraThinMaterial)
        }
        .onAppear {
            viewModel.userInput = draftText
        }
        .sheet(item: $editingMessage) { message in
            NavigationStack {
                EditMessageSheet(
                    originalMessage: message,
                    text: $editingContent
                ) { newContent in
                    viewModel.commitEditedMessage(message, content: newContent)
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $messageInfo) { info in
            MessageInfoSheet(payload: info)
        }
        .confirmationDialog("创建分支选项", isPresented: $showBranchOptions, titleVisibility: .visible) {
            Button("仅复制消息历史") {
                if let message = messageToBranch {
                    let newSession = viewModel.branchSessionFromMessage(upToMessage: message, copyPrompts: false)
                    viewModel.setCurrentSession(newSession)
                }
                messageToBranch = nil
            }
            Button("复制消息历史和提示词") {
                if let message = messageToBranch {
                    let newSession = viewModel.branchSessionFromMessage(upToMessage: message, copyPrompts: true)
                    viewModel.setCurrentSession(newSession)
                }
                messageToBranch = nil
            }
            Button("取消", role: .cancel) {
                messageToBranch = nil
            }
        } message: {
            if let message = messageToBranch, let index = viewModel.allMessagesForSession.firstIndex(where: { $0.id == message.id }) {
                Text("将从第 \(index + 1) 条消息处创建新的分支会话。")
            }
        }
    }
    
    // MARK: - Background
    
    private var backgroundLayer: some View {
        ZStack {
            Group {
                if viewModel.enableBackground,
                   let image = viewModel.currentBackgroundImageUIImage {
                    GeometryReader { geo in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .blur(radius: viewModel.backgroundBlur)
                            .opacity(viewModel.backgroundOpacity)
                            .overlay(Color.black.opacity(0.08))
                    }
                    .ignoresSafeArea()
                } else {
                    Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                }
            }
            
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.12),
                    Color.purple.opacity(0.08),
                    Color.blue.opacity(0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }
    
// MARK: - Components
    
    private var sessionHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(viewModel.currentSession?.name ?? "新的对话")
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                    Text(headerSubtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()

                Menu {
                    Button {
                        viewModel.createNewSession()
                    } label: {
                        Label("开始新会话", systemImage: "plus.message")
                    }
                    
                    Button {
                        composerFocused = true
                    } label: {
                        Label("快速输入", systemImage: "keyboard")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(10)
                        .background(.thinMaterial, in: Circle())
                }
                .accessibilityLabel("聊天操作菜单")
            }
            
            modelSelectorCard
            
            historyBanner
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.24),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .opacity(viewModel.enableBackground ? 0.5 : 1)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08))
        )
        .shadow(color: Color.black.opacity(0.06), radius: 14, y: 10)
        .padding(.top, 12)
    }
    
    private var headerSubtitle: String {
        let modelName = viewModel.selectedModel?.model.displayName ?? "未选择模型"
        let visibleCount = viewModel.messages.count
        let totalCount = viewModel.allMessagesForSession.count
        let countText = totalCount == 0 ? "等待开始" : "已显示 \(visibleCount)/\(totalCount) 条"
        return "\(modelName) | \(countText)"
    }

    @ViewBuilder
    private var historyBanner: some View {
        let remaining = viewModel.allMessagesForSession.count - viewModel.messages.count
        if remaining > 0 && !viewModel.isHistoryFullyLoaded {
            let chunk = min(remaining, viewModel.historyLoadChunkSize)
            Button {
                withAnimation {
                    viewModel.loadMoreHistoryChunk()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.left.circle")
                    Text("向上加载 \(chunk) 条记录")
                }
            }
            .font(.footnote.weight(.semibold))
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground).opacity(0.8))
            )
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var modelSelectorCard: some View {
        if !viewModel.activatedModels.isEmpty {
            let selection = Binding<String?>(
                get: { viewModel.selectedModel?.id },
                set: { newValue in
                    guard let id = newValue,
                          let target = viewModel.activatedModels.first(where: { $0.id == id }) else { return }
                    viewModel.setSelectedModel(target)
                }
            )
            
            Menu {
                Picker("选择模型", selection: selection) {
                    Text("选择模型")
                        .tag(Optional<String>.none)
                    ForEach(viewModel.activatedModels, id: \.id) { runnable in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(runnable.model.displayName)
                            Text(runnable.provider.name)
                                .font(.caption2)
                        }
                        .tag(Optional<String>.some(runnable.id))
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.2))
                            .frame(width: 36, height: 36)
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前模型")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(viewModel.selectedModel?.model.displayName ?? "选择模型")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let providerName = viewModel.selectedModel?.provider.name {
                            Text(providerName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground).opacity(0.9))
                )
            }
        }
    }
    
    @ViewBuilder
    private func contextMenu(for message: ChatMessage) -> some View {
        // 有音频或图片附件的消息不显示编辑按钮
        let hasAttachments = message.audioFileName != nil || (message.imageFileNames?.isEmpty == false)
        
        if !hasAttachments {
            Button {
                editingMessage = message
                editingContent = message.content
            } label: {
                Label("编辑", systemImage: "pencil")
            }
        }
        
        if viewModel.canRetry(message: message) {
            Button {
                viewModel.retryMessage(message)
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
            }
        }
        
        Button {
            messageToBranch = message
            showBranchOptions = true
        } label: {
            Label("从此处创建分支", systemImage: "arrow.triangle.branch")
        }
        
        Divider()
        
        Button(role: .destructive) {
            viewModel.deleteMessage(message)
        } label: {
            Label("删除消息", systemImage: "trash")
        }
        
        Divider()
        
        Button {
            UIPasteboard.general.string = message.content
        } label: {
            Label("复制内容", systemImage: "doc.on.doc")
        }

        Button {
            UIPasteboard.general.string = plainText(fromMarkdown: message.content)
        } label: {
            Label("复制为纯文本", systemImage: "doc.plaintext")
        }

        Button {
            UIPasteboard.general.string = message.content
        } label: {
            Label("复制为 Markdown", systemImage: "doc.richtext")
        }
        
        if let index = viewModel.allMessagesForSession.firstIndex(where: { $0.id == message.id }) {
            Button {
                messageInfo = MessageInfoPayload(
                    message: message,
                    displayIndex: index + 1,
                    totalCount: viewModel.allMessagesForSession.count
                )
            } label: {
                Label("查看消息信息", systemImage: "info.circle")
            }
        }
    }
}

// MARK: - Helpers

private extension ChatView {
    func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        let action = {
            proxy.scrollTo(scrollBottomAnchorID, anchor: .bottom)
        }
        if animated {
            withAnimation(.easeOut(duration: 0.25)) {
                action()
            }
        } else {
            action()
        }
    }

    func plainText(fromMarkdown markdown: String) -> String {
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        ) {
            return String(attributed.characters)
        }
        return markdown
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: ">", with: "")
    }
}

// MARK: - Composer

private struct MessageComposerView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Binding var text: String
    let isSending: Bool
    let sendAction: () -> Void
    let focus: FocusState<Bool>.Binding
    
    @State private var showImagePicker = false
    @State private var showAudioRecorder = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var imagePreview: ImagePreviewPayload?
    
    private var sendButtonColor: Color {
        viewModel.canSendMessage ? Color.accentColor : Color.secondary.opacity(0.5)
    }
    
    private var sendIconName: String {
        isSending ? "paperplane.circle.fill" : "paperplane.fill"
    }
    
    var body: some View {
        VStack(spacing: 12) {
            if !viewModel.pendingImageAttachments.isEmpty || viewModel.pendingAudioAttachment != nil {
                attachmentPreviewBar
            }
            
            HStack(alignment: .center, spacing: 12) {
                Menu {
                    Button {
                        showImagePicker = true
                    } label: {
                        Label("选择图片", systemImage: "photo")
                    }
                    
                    Button {
                        showAudioRecorder = true
                    } label: {
                        Label("录制语音", systemImage: "mic")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(12)
                        .background(
                            Circle()
                                .fill(Color.accentColor.opacity(0.12))
                        )
                }
                
                TextField("输入...", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
                    .focused(focus)
                    .submitLabel(.send)
                    .onSubmit {
                        guard viewModel.canSendMessage else { return }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        sendAction()
                    }
                
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    sendAction()
                } label: {
                    Image(systemName: sendIconName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(
                            Circle()
                                .fill(sendButtonColor)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canSendMessage)
                .help("发送当前消息")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(uiColor: .systemBackground).opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.08))
                )
        )
        .shadow(color: Color.black.opacity(0.08), radius: 18, y: 10)
        .photosPicker(isPresented: $showImagePicker, selection: $selectedPhotos, maxSelectionCount: 4, matching: .images)
        .onChange(of: selectedPhotos) { _, newItems in
            Task {
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run {
                            viewModel.addImageAttachment(image)
                        }
                    }
                }
                selectedPhotos = []
            }
        }
        .sheet(isPresented: $showAudioRecorder) {
            AudioRecorderSheet { attachment in
                viewModel.setAudioAttachment(attachment)
            }
        }
        .sheet(item: $imagePreview) { payload in
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: payload.image)
                    .resizable()
                    .scaledToFit()
                    .padding(24)
            }
        }
    }
    
    @ViewBuilder
    private var attachmentPreviewBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // 图片预览
                ForEach(viewModel.pendingImageAttachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        if let thumbnail = attachment.thumbnailImage {
                            Button {
                                if let fullImage = attachment.fullImage {
                                    imagePreview = ImagePreviewPayload(image: fullImage)
                                } else {
                                    imagePreview = ImagePreviewPayload(image: thumbnail)
                                }
                            } label: {
                                Image(uiImage: thumbnail)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                        
                        Button {
                            viewModel.removePendingImageAttachment(attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .offset(x: 4, y: -4)
                    }
                }
                
                // 音频预览
                if let audio = viewModel.pendingAudioAttachment {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.system(size: 16))
                            .foregroundStyle(.tint)
                        
                        Text(audio.fileName)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(maxWidth: 80)
                        
                        Button {
                            viewModel.clearPendingAudioAttachment()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private struct ImagePreviewPayload: Identifiable {
        let id = UUID()
        let image: UIImage
    }
}
// MARK: - Audio Recorder Sheet

private struct AudioRecorderSheet: View {
    let onComplete: (AudioAttachment) -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var isRecording = false
    @State private var recordingDuration: TimeInterval = 0
    @State private var audioRecorder: AVAudioRecorder?
    @State private var recordingURL: URL?
    @State private var timer: Timer?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 30) {
                Spacer()
                
                // 录音时长显示
                Text(formatDuration(recordingDuration))
                    .font(.system(size: 48, weight: .light, design: .monospaced))
                    .foregroundStyle(isRecording ? .red : .primary)
                
                // 录音按钮
                Button {
                    if isRecording {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(isRecording ? Color.red : Color.accentColor)
                            .frame(width: 80, height: 80)
                        
                        Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white)
                    }
                }
                
                if isRecording {
                    Text("正在录音...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("点击开始录音")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
            }
            .navigationTitle("录制语音")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        cancelRecording()
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        finishRecording()
                    }
                    .disabled(recordingURL == nil || isRecording)
                }
            }
        }
        .onDisappear {
            cancelRecording()
        }
    }
    
    private func startRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
            
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64000
            ]
            
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.prepareToRecord()
            audioRecorder?.record()
            
            recordingURL = url
            isRecording = true
            recordingDuration = 0
            
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                recordingDuration += 0.1
            }
        } catch {
            print("录音启动失败: \(error.localizedDescription)")
        }
    }
    
    private func stopRecording() {
        timer?.invalidate()
        timer = nil
        audioRecorder?.stop()
        isRecording = false
    }
    
    private func cancelRecording() {
        stopRecording()
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
    }
    
    private func finishRecording() {
        stopRecording()
        guard let url = recordingURL,
              let data = try? Data(contentsOf: url) else {
            dismiss()
            return
        }
        
        let attachment = AudioAttachment(
            data: data,
            mimeType: "audio/m4a",
            format: "m4a",
            fileName: url.lastPathComponent
        )
        
        try? FileManager.default.removeItem(at: url)
        onComplete(attachment)
        dismiss()
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let tenths = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
    }
}

// MARK: - Edit Sheet

private struct EditMessageSheet: View {
    let originalMessage: ChatMessage
    @Binding var text: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        Form {
            Section("原始内容") {
                Text(originalMessage.content)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            
            Section("编辑后") {
                TextEditor(text: $text)
                    .frame(minHeight: 160)
            }
        }
        .navigationTitle("编辑消息")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    onSave(text)
                    dismiss()
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

// MARK: - Message Info

/// 用于承载消息信息弹窗的数据结构，避免直接暴露ChatMessage本身。
private struct MessageInfoPayload: Identifiable {
    let id = UUID()
    let message: ChatMessage
    let displayIndex: Int
    let totalCount: Int
}

/// 消息详情弹窗，展示消息的唯一标识与位置索引。
private struct MessageInfoSheet: View {
    let payload: MessageInfoPayload
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("基础信息") {
                    LabeledContent("角色") {
                        Text(roleDescription(payload.message.role))
                    }
                    LabeledContent("列表位置") {
                        Text("第 \(payload.displayIndex) / \(payload.totalCount) 条")
                    }
                }
                
                Section("唯一标识") {
                    Text(payload.message.id.uuidString)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("消息信息")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
    
    /// 将消息角色转换为易读的中文描述
        private func roleDescription(_ role: MessageRole) -> String {
            switch role {
            case .system:
                return "系统"
            case .user:
                return "用户"
            case .assistant:
                return "助手"
            case .tool:
                return "工具"
            case .error:
                return "错误"
            @unknown default:
                return "未知"
            }
        }
    }
