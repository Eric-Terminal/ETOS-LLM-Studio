// ============================================================================
// ChatBubble.swift
// ============================================================================
// ETOS LLM Studio Watch App 聊天气泡视图 (已重构)
//
// 功能特性:
// - 根据角色（用户/AI/错误）显示不同样式的气泡
// - 支持 Markdown 渲染
// - 思考过程的展开/折叠状态由外部传入的绑定控制
// - 支持语音消息播放
// ============================================================================

import SwiftUI
import MarkdownUI
import Shared
import AVFoundation
import Combine

/// 聊天消息气泡组件
struct ChatBubble: View {
    
    // MARK: - 属性与绑定
    
    let message: ChatMessage
    @Binding var isReasoningExpanded: Bool
    @Binding var isToolCallsExpanded: Bool
    
    let enableMarkdown: Bool
    let enableBackground: Bool
    let enableLiquidGlass: Bool
    
    @StateObject private var audioPlayer = WatchAudioPlayerManager()

    // MARK: - 视图主体
    
    var body: some View {
        HStack {
            // 重构: 使用 MessageRole 枚举进行判断
            switch message.role {
            case .user:
                Spacer()
                userBubble
            case .error:
                errorBubble
                Spacer()
            case .assistant, .system, .tool: // system 和 tool 也使用 assistant 样式
                assistantBubble
                Spacer()
            @unknown default:
                // 为未来可能增加的 role 类型提供一个默认的回退，防止编译错误
                Spacer()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
    
    // MARK: - 气泡视图
    
    @ViewBuilder
    private var userBubble: some View {
        let content = Group {
            // 如果是语音消息，显示播放控件
            if let audioFileName = message.audioFileName {
                audioPlayerView(fileName: audioFileName, isUser: true)
            } else {
                renderContent(message.content)
            }
        }
            .padding(10)
            .foregroundColor(.white)

        if enableLiquidGlass {
            if #available(watchOS 26.0, *) {
                content
                    .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 12))
                    .background(Color.blue.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                userBubbleFallback(content)
            }
        } else {
            userBubbleFallback(content)
        }
    }
    
    @ViewBuilder
    private var errorBubble: some View {
        let content = Text(message.content)
            .padding(10)
            .foregroundColor(.white)

        if enableLiquidGlass {
            if #available(watchOS 26.0, *) {
                content
                    .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 12))
                    .background(Color.red.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                errorBubbleFallback(content)
            }
        } else {
            errorBubbleFallback(content)
        }
    }
    
    @ViewBuilder
    private var assistantBubble: some View {
        let content = VStack(alignment: .leading, spacing: 8) {
            
            let hasReasoning = message.reasoningContent != nil && !message.reasoningContent!.isEmpty
            let hasToolCalls = message.toolCalls != nil && !message.toolCalls!.isEmpty
            
            // 思考过程区域
            if let reasoning = message.reasoningContent, !reasoning.isEmpty {
                reasoningView(reasoning)
            }
            
            // 工具调用区域
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                // 如果思考过程和工具调用同时存在，添加一个分隔线
                if hasReasoning {
                    Divider().background(Color.gray.opacity(0.5))
                }
                toolCallsView(toolCalls)
            }
            
            // 如果有附加信息（思考或工具），且有实际内容，则添加主分隔线
            if (hasReasoning || hasToolCalls) && !message.content.isEmpty {
                Divider().background(Color.gray)
            }
            
            // 消息内容区域
            if !message.content.isEmpty {
                renderContent(message.content)
            }
            
            // 加载指示器
            if shouldShowThinkingIndicator {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text(currentThinkingText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)

        Group {
            if enableLiquidGlass {
                if #available(watchOS 26.0, *) {
                    content.glassEffect(.clear, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    assistantBubbleFallback(content)
                }
            } else {
                assistantBubbleFallback(content)
            }
        }
        .contentShape(Rectangle())
    }
    
    // MARK: - 辅助视图
    
    @ViewBuilder
    private func renderContent(_ content: String) -> some View {
        if enableMarkdown {
            Markdown(content)
        } else {
            Text(content)
        }
    }
    
    @ViewBuilder
    private func audioPlayerView(fileName: String, isUser: Bool) -> some View {
        let foregroundColor = isUser ? Color.white : Color.primary
        let secondaryColor = isUser ? Color.white.opacity(0.7) : Color.secondary
        let isCurrentFile = audioPlayer.currentFileName == fileName
        
        VStack(alignment: .leading, spacing: 4) {
            // 播放按钮 + 文件名
            HStack(spacing: 6) {
                Button {
                    audioPlayer.togglePlayback(fileName: fileName)
                } label: {
                    Image(systemName: audioPlayer.isPlaying && isCurrentFile ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(foregroundColor)
                }
                .buttonStyle(.plain)
                
                Text(fileName)
                    .font(.system(size: 9))
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
            }
            
            // 进度条 + 时间
            if isCurrentFile && audioPlayer.duration > 0 {
                ProgressView(value: audioPlayer.progress)
                    .progressViewStyle(.linear)
                    .tint(foregroundColor)
                
                HStack {
                    Text(formatTime(audioPlayer.currentTime))
                    Spacer()
                    Text(formatTime(audioPlayer.duration))
                }
                .font(.system(size: 9))
                .foregroundStyle(secondaryColor)
            }
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    @ViewBuilder
    private func reasoningView(_ reasoning: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: {
                withAnimation {
                    isReasoningExpanded.toggle()
                }
            }) {
                HStack {
                    Text("思考过程")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Spacer()
                    Image(systemName: isReasoningExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            if isReasoningExpanded {
                Text(reasoning)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.bottom, isReasoningExpanded ? 5 : 0)
    }
    
    @ViewBuilder
    private func toolCallsView(_ toolCalls: [InternalToolCall]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: {
                withAnimation {
                    isToolCallsExpanded.toggle()
                }
            }) {
                HStack {
                    Text("使用工具")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Spacer()
                    Image(systemName: isToolCallsExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            if isToolCallsExpanded {
                ForEach(toolCalls, id: \.id) { toolCall in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "wrench.and.screwdriver.fill")
                            Text(toolCall.toolName)
                        }
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        if let result = toolCall.result, !result.isEmpty {
                            Text(result)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.leading, 4)
                }
            }
        }
        .padding(.bottom, isToolCallsExpanded ? 5 : 0)
    }
    
    // MARK: - 回退样式
    
    @ViewBuilder
    private func userBubbleFallback<Content: View>(_ content: Content) -> some View {
        content
            .background(enableBackground ? Color.blue.opacity(0.7) : Color.blue)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    @ViewBuilder
    private func errorBubbleFallback<Content: View>(_ content: Content) -> some View {
        content
            .background(enableBackground ? Color.red.opacity(0.7) : Color.red)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    @ViewBuilder
    private func assistantBubbleFallback<Content: View>(_ content: Content) -> some View {
        content
            .background(enableBackground ? Color.black.opacity(0.3) : Color(white: 0.3))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 思考提示相关

private extension ChatBubble {
    
    var shouldShowThinkingIndicator: Bool {
        message.role == .assistant && message.content.isEmpty && (message.reasoningContent ?? "").isEmpty
    }
    
    var currentThinkingText: String {
        guard shouldShowThinkingIndicator else { return "" }
        return "正在思考..."
    }
}

// MARK: - Watch Audio Player Manager

class WatchAudioPlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var currentFileName: String?
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    
    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }
    
    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?
    
    func togglePlayback(fileName: String) {
        if isPlaying && currentFileName == fileName {
            stop()
        } else {
            play(fileName: fileName)
        }
    }
    
    func play(fileName: String) {
        stop()
        
        guard let data = Persistence.loadAudio(fileName: fileName) else {
            print("❌ 无法加载音频文件: \(fileName)")
            return
        }
        
        do {
            // 使用 .ambient 类别，会遵循系统静音设置
            // 静音模式下不会发出声音，避免尴尬
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            
            duration = audioPlayer?.duration ?? 0
            currentTime = 0
            
            audioPlayer?.play()
            
            currentFileName = fileName
            isPlaying = true
            
            startProgressTimer()
        } catch {
            print("❌ 播放音频失败: \(error.localizedDescription)")
        }
    }
    
    func stop() {
        stopProgressTimer()
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        currentTime = 0
    }
    
    private func startProgressTimer() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.audioPlayer else { return }
            DispatchQueue.main.async {
                self.currentTime = player.currentTime
            }
        }
    }
    
    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
    
    // AVAudioPlayerDelegate
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.stopProgressTimer()
            self.isPlaying = false
            self.currentTime = self.duration
        }
    }
    
    deinit {
        stop()
    }
}
