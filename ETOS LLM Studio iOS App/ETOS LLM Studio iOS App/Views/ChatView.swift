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
    @State private var navigationDestination: ChatNavigationDestination?
    @State private var editingMessage: ChatMessage?
    @State private var editingContent: String = ""
    @State private var messageInfo: MessageInfoPayload?
    @State private var showBranchOptions = false
    @State private var messageToBranch: ChatMessage?
    @FocusState private var composerFocused: Bool
    @AppStorage("chat.composer.draft") private var draftText: String = ""
    
    private let scrollBottomAnchorID = "chat-scroll-bottom"
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Z-Index 0: 背景壁纸层（穿透安全区）
                backgroundLayer
                    .ignoresSafeArea()
                
                // Z-Index 1: 消息列表（内容滚动到玻璃下）
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12, pinnedViews: []) {
                            // 顶部留白
                            Color.clear.frame(height: 60)
                            
                            modelSelectorBar
                            historyBanner
                            
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
                            
                            Color.clear
                                .frame(height: 1)
                                .id(scrollBottomAnchorID)
                        }
                        .padding(.horizontal, 16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .scrollIndicators(.hidden)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            composerFocused = false
                        }
                    )
                    .onChange(of: viewModel.messages.count) { _, _ in
                        guard !viewModel.messages.isEmpty else { return }
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
                            .padding(.bottom, 90)
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityLabel("滚动到底部")
                        }
                    }
                    // Telegram 风格：顶部模糊玻璃导航栏
                    .safeAreaInset(edge: .top) {
                        liquidGlassNavBar
                    }
                    // Telegram 风格：底部模糊玻璃输入栏
                    .safeAreaInset(edge: .bottom) {
                        liquidGlassInputBar
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .navigationDestination(item: $navigationDestination) { destination in
                switch destination {
                case .sessions:
                    SessionListView()
                case .settings:
                    SettingsView()
                }
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
    }
    
    // MARK: - Background
    
    private var backgroundLayer: some View {
        Group {
            if viewModel.enableBackground,
               let image = viewModel.currentBackgroundImageUIImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .blur(radius: viewModel.backgroundBlur)
                    .opacity(viewModel.backgroundOpacity)
                    .overlay(Color.black.opacity(0.1))
            } else {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            }
        }
    }
    
// MARK: - Components

    // MARK: - Telegram 风格：液态玻璃导航栏
    @ViewBuilder
    private var liquidGlassNavBar: some View {
        HStack {
            Text(viewModel.currentSession?.name ?? "新的对话")
                .font(.headline)
                .lineLimit(1)
            
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
                
                Divider()
                
                Button {
                    navigationDestination = .sessions
                } label: {
                    Label("会话列表", systemImage: "list.bullet")
                }
                
                Button {
                    navigationDestination = .settings
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("快速操作")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
    
    // MARK: - Telegram 风格：液态玻璃输入栏
    @ViewBuilder
    private var liquidGlassInputBar: some View {
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
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .onAppear {
            viewModel.userInput = draftText
        }
    }

    @ViewBuilder
    private var customHeader: some View {
        HStack {
            Text(viewModel.currentSession?.name ?? "新的对话")
                .font(.title2.bold())
                .lineLimit(1)
            
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
                
                Divider()
                
                Button {
                    navigationDestination = .sessions
                } label: {
                    Label("会话列表", systemImage: "list.bullet")
                }
                
                Button {
                    navigationDestination = .settings
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("快速操作")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 12)
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
                Label("向上加载 \(chunk) 条记录", systemImage: "arrow.uturn.left.circle")
            }
            .font(.footnote)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 12)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var modelSelectorBar: some View {
        if !viewModel.activatedModels.isEmpty {
            let selection = Binding<String?>(
                get: { viewModel.selectedModel?.id },
                set: { newValue in
                    guard let id = newValue,
                          let target = viewModel.activatedModels.first(where: { $0.id == id }) else { return }
                    viewModel.setSelectedModel(target)
                }
            )
            VStack(alignment: .leading, spacing: 8) {
                Text("当前模型")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("选择模型", selection: selection) {
                    Text("选择模型")
                        .tag(Optional<String>.none)
                    ForEach(viewModel.activatedModels, id: \.id) { runnable in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(runnable.model.displayName)
                            Text(runnable.provider.name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .tag(Optional<String>.some(runnable.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    Color(uiColor: .secondarySystemBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.top, 12)
            .padding(.bottom, 4)
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
        
        // 版本管理菜单项
        if message.hasMultipleVersions {
            Menu {
                ForEach(0..<message.getAllVersions().count, id: \.self) { index in
                    Button {
                        viewModel.switchToVersion(index, of: message)
                    } label: {
                        HStack {
                            Text("版本 \(index + 1)")
                            if index == message.getCurrentVersionIndex() {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("切换版本 (\(message.getCurrentVersionIndex() + 1)/\(message.getAllVersions().count))", systemImage: "clock.arrow.circlepath")
            }
            
            if message.getAllVersions().count > 1 {
                Button(role: .destructive) {
                    viewModel.deleteCurrentVersion(of: message)
                } label: {
                    Label("删除当前版本", systemImage: "trash")
                }
            }
            
            Divider()
        }
        
        Button(role: .destructive) {
            viewModel.deleteMessage(message)
        } label: {
            Label(message.hasMultipleVersions ? "删除所有版本" : "删除消息", systemImage: "trash.fill")
        }
        
        Divider()
        
        Button {
            UIPasteboard.general.string = message.content
        } label: {
            Label("复制内容", systemImage: "doc.on.doc")
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
}

// MARK: - Composer

private struct MessageComposerView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Binding var text: String
    let isSending: Bool
    let sendAction: () -> Void
    let focus: FocusState<Bool>.Binding
    
    @State private var showAttachmentMenu = false
    @State private var showImagePicker = false
    @State private var showAudioRecorder = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    
    var body: some View {
        VStack(spacing: 8) {
            // 附件预览区域
            if !viewModel.pendingImageAttachments.isEmpty || viewModel.pendingAudioAttachment != nil {
                attachmentPreviewBar
                    .padding(.horizontal, 12)
            }
            
            HStack(alignment: .center, spacing: 12) {
                // 加号按钮（圆形）
                if #available(iOS 26.0, *) {
                    Button {
                        showAttachmentMenu = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .glassEffect(.clear, in: Circle())
                    .confirmationDialog("添加附件", isPresented: $showAttachmentMenu) {
                        Button("选择图片") {
                            showImagePicker = true
                        }
                        Button("录制语音") {
                            showAudioRecorder = true
                        }
                    }
                } else {
                    Button {
                        showAttachmentMenu = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .confirmationDialog("添加附件", isPresented: $showAttachmentMenu) {
                        Button("选择图片") {
                            showImagePicker = true
                        }
                        Button("录制语音") {
                            showAudioRecorder = true
                        }
                    }
                }
                
                // 输入框（拉长的药丸型）
                if #available(iOS 26.0, *) {
                    HStack(spacing: 8) {
                        TextField("Message", text: $text, axis: .vertical)
                            .lineLimit(1...6)
                            .textFieldStyle(.plain)
                            .focused(focus)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .glassEffect(.clear, in: Capsule())
                } else {
                    HStack(spacing: 8) {
                        TextField("Message", text: $text, axis: .vertical)
                            .lineLimit(1...6)
                            .textFieldStyle(.plain)
                            .focused(focus)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .background(
                        Capsule()
                            .fill(Color(uiColor: .secondarySystemFill))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                    )
                }
                
                // 发送箭头（圆形）
                if #available(iOS 26.0, *) {
                    Button {
                        sendAction()
                    } label: {
                        Image(systemName: isSending ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .glassEffect(.clear, in: Circle())
                    .disabled(!viewModel.canSendMessage)
                } else {
                    Button {
                        sendAction()
                    } label: {
                        Image(systemName: isSending ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(!viewModel.canSendMessage)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
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
    }
    
    @ViewBuilder
    private var attachmentPreviewBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // 图片预览
                ForEach(viewModel.pendingImageAttachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        if let thumbnail = attachment.thumbnailImage {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
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
            // 录音启动失败
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
