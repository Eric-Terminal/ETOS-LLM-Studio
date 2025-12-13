// ============================================================================
// ChatBubble.swift
// ============================================================================
// 聊天气泡 (iOS 样式)
// - 根据消息角色切换配色
// - 支持 Markdown 与推理展开
// - 为工具调用提供可折叠区域
// - 支持语音消息播放
// ============================================================================

import SwiftUI
import MarkdownUI
import Shared
import UIKit
import AVFoundation
import Combine

struct ChatBubble: View {
    let message: ChatMessage
    @Binding var isReasoningExpanded: Bool
    @Binding var isToolCallsExpanded: Bool
    let enableMarkdown: Bool
    let enableBackground: Bool
    
    @StateObject private var audioPlayer = AudioPlayerManager()
    @State private var imagePreview: ImagePreviewPayload?
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.role == .assistant || message.role == .system || message.role == .tool {
                roleBadge
            }
            
            VStack(alignment: .leading, spacing: 8) {
                contentStack
            }
            .padding(14)
            .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(bubbleStrokeColor, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 12, y: 8)
            
            if message.role == .user {
                roleBadge
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
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
    
    // MARK: - Content
    
    @ViewBuilder
    private var contentStack: some View {
        if let imageFileNames = message.imageFileNames, !imageFileNames.isEmpty {
            imageAttachmentsView(fileNames: imageFileNames)
        }
        
        if let reasoning = message.reasoningContent,
           !reasoning.isEmpty {
            DisclosureGroup(isExpanded: $isReasoningExpanded) {
                Text(reasoning)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } label: {
                Label("思考过程", systemImage: "brain.head.profile")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        
        if let toolCalls = message.toolCalls,
           !toolCalls.isEmpty {
            DisclosureGroup(isExpanded: $isToolCallsExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(toolCalls, id: \.id) { call in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(call.toolName)
                                .font(.footnote.weight(.semibold))
                            if let result = call.result, !result.isEmpty {
                                Text(result)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            } label: {
                Label("使用工具", systemImage: "wrench.and.screwdriver")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        
        if !message.content.isEmpty {
            // 如果是语音消息，显示播放控件
            if let audioFileName = message.audioFileName {
                audioPlayerView(fileName: audioFileName)
            } else {
                renderContent(message.content)
                    .font(.body)
                    .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                    .textSelection(.enabled)
            }
        } else if message.role == .assistant {
            HStack(spacing: 6) {
                ProgressView()
                Text("正在思考…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    @ViewBuilder
    private func imageAttachmentsView(fileNames: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(fileNames, id: \.self) { fileName in
                    if let image = loadImage(fileName: fileName) {
                        Button {
                            imagePreview = ImagePreviewPayload(image: image)
                        } label: {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 140, height: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                            .frame(width: 140, height: 140)
                            .overlay(
                                VStack(spacing: 6) {
                                    Image(systemName: "photo")
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Text("图片丢失")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            )
                    }
                }
            }
        }
    }
    
    private func loadImage(fileName: String) -> UIImage? {
        guard let data = Persistence.loadImage(fileName: fileName) else { return nil }
        return UIImage(data: data)
    }
    
    @ViewBuilder
    private func renderContent(_ content: String) -> some View {
        if enableMarkdown {
            Markdown(content)
                .padding(.top, message.reasoningContent == nil ? 0 : 4)
        } else {
            Text(content)
        }
    }
    
    @ViewBuilder
    private func audioPlayerView(fileName: String) -> some View {
        let isUser = message.role == .user
        let foregroundColor = isUser ? Color.white : Color.primary
        let secondaryColor = isUser ? Color.white.opacity(0.7) : Color.secondary
        
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    audioPlayer.togglePlayback(fileName: fileName)
                } label: {
                    Image(systemName: audioPlayer.isPlaying && audioPlayer.currentFileName == fileName ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(foregroundColor)
                }
                .buttonStyle(.plain)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileName)
                        .font(.caption)
                        .foregroundStyle(secondaryColor)
                        .lineLimit(1)
                    
                    if audioPlayer.currentFileName == fileName && audioPlayer.duration > 0 {
                        // 进度条
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(secondaryColor.opacity(0.3))
                                    .frame(height: 4)
                                Capsule()
                                    .fill(foregroundColor)
                                    .frame(width: geo.size.width * audioPlayer.progress, height: 4)
                            }
                        }
                        .frame(height: 4)
                        
                        Text(audioPlayer.timeString)
                            .font(.caption2)
                            .foregroundStyle(secondaryColor)
                            .monospacedDigit()
                    }
                }
            }
        }
    }
    
    // MARK: - Badge & Background
    
    private var bubbleBackground: some ShapeStyle {
        switch message.role {
        case .user:
            return enableBackground ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.accentColor)
        case .error:
            return AnyShapeStyle(Color.red.opacity(0.15))
        case .assistant, .system, .tool:
            return enableBackground ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color(UIColor.secondarySystemBackground))
        @unknown default:
            return enableBackground ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color(UIColor.secondarySystemBackground))
        }
    }
    
    private var bubbleStrokeColor: Color {
        switch message.role {
        case .user:
            return Color.white.opacity(0.35)
        case .assistant, .system, .tool:
            return Color.black.opacity(0.05)
        case .error:
            return Color.red.opacity(0.2)
        @unknown default:
            return Color.black.opacity(0.05)
        }
    }
    
    private var roleBadge: some View {
        let symbol: String
        let color: Color
        
        switch message.role {
        case .user:
            symbol = "person.fill"
            color = .accentColor
        case .assistant:
            symbol = "sparkles"
            color = .purple
        case .system:
            symbol = "gear"
            color = .indigo
        case .tool:
            symbol = "wrench.adjustable"
            color = .orange
        case .error:
            symbol = "exclamationmark.triangle.fill"
            color = .red
        @unknown default:
            symbol = "questionmark.circle"
            color = .gray
        }
        
        return Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(color)
            .padding(10)
            .background(
                Circle()
                    .fill(Color(uiColor: .systemBackground).opacity(0.92))
                    .overlay(
                        Circle()
                            .stroke(color.opacity(message.role == .user ? 0.35 : 0.2), lineWidth: 1)
                    )
            )
            .shadow(color: color.opacity(0.2), radius: 8, y: 4)
    }
    
    // MARK: - Image Attachments
    
    @ViewBuilder
    private func imageAttachmentsView(fileNames: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(fileNames, id: \.self) { fileName in
                    if let image = loadImage(fileName: fileName) {
                        Button {
                            imagePreview = image
                        } label: {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 120, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.secondary.opacity(0.1))
                            .frame(width: 120, height: 120)
                            .overlay(
                                VStack(spacing: 4) {
                                    Image(systemName: "photo")
                                        .font(.title2)
                                    Text("图片丢失")
                                        .font(.caption2)
                                }
                                .foregroundStyle(.secondary)
                            )
                    }
                }
            }
        }
    }
    
    private func loadImage(fileName: String) -> UIImage? {
        guard let data = Persistence.loadImage(fileName: fileName) else { return nil }
        return UIImage(data: data)
    }
}

// MARK: - Image Preview Wrapper

struct ImagePreviewWrapper: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct ImagePreviewPayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

// MARK: - Audio Player Manager

class AudioPlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var progress: Double = 0
    @Published var currentFileName: String?
    @Published var duration: TimeInterval = 0
    
    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    
    var timeString: String {
        guard let player = audioPlayer else { return "0:00" }
        let current = Int(player.currentTime)
        let total = Int(player.duration)
        return String(format: "%d:%02d / %d:%02d", current / 60, current % 60, total / 60, total % 60)
    }
    
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
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            
            currentFileName = fileName
            duration = audioPlayer?.duration ?? 0
            isPlaying = true
            
            startTimer()
        } catch {
            print("❌ 播放音频失败: \(error.localizedDescription)")
        }
    }
    
    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        progress = 0
        stopTimer()
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let player = self.audioPlayer else { return }
            self.progress = player.currentTime / player.duration
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    // AVAudioPlayerDelegate
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.progress = 0
            self.stopTimer()
        }
    }
    
    deinit {
        stop()
    }
}
