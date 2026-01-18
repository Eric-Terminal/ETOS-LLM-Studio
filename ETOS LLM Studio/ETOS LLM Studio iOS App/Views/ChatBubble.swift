// ============================================================================
// ChatBubble.swift
// ============================================================================
// 聊天气泡 (Telegram 风格)
// - 仿 Telegram 气泡形状与配色
// - 用户消息：蓝色
// - AI 消息：白色/灰色
// - 支持 Markdown 与推理展开
// - 支持语音消息播放
// ============================================================================

import SwiftUI
import Foundation
import MarkdownUI
import Shared
import UIKit
import AVFoundation
import Combine

// MARK: - Telegram 风格气泡形状

/// Telegram 风格的气泡形状（无尾巴）
struct TelegramBubbleShape: Shape {
    let isOutgoing: Bool  // 是否是发出的消息（用户消息）
    let cornerRadius: CGFloat
    
    init(isOutgoing: Bool, cornerRadius: CGFloat = 18) {
        self.isOutgoing = isOutgoing
        self.cornerRadius = cornerRadius
    }
    
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .path(in: rect)
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    @Binding var isReasoningExpanded: Bool
    @Binding var isToolCallsExpanded: Bool
    let enableMarkdown: Bool
    let enableBackground: Bool
    
    @StateObject private var audioPlayer = AudioPlayerManager()
    @State private var imagePreview: ImagePreviewPayload?
    @EnvironmentObject private var viewModel: ChatViewModel
    
    // Telegram 颜色
    private let telegramBlue = Color(red: 0.24, green: 0.56, blue: 0.95)
    private let telegramBlueDark = Color(red: 0.17, green: 0.45, blue: 0.82)
    
    private var isOutgoing: Bool {
        message.role == .user
    }
    
    private var isError: Bool {
        message.role == .error || (message.role == .assistant && message.content.hasPrefix("重试失败"))
    }
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer(minLength: 20)
            
            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                // 气泡内容
                VStack(alignment: .leading, spacing: 6) {
                    contentStack
                    
                    // 版本指示器（Telegram 风格：右下角）
                    if message.hasMultipleVersions {
                        HStack(spacing: 6) {
                            compactVersionIndicator
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    TelegramBubbleShape(isOutgoing: isOutgoing)
                        .fill(bubbleGradient)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 3, y: 1)
            }
            .frame(maxWidth: UIScreen.main.bounds.width * 0.88, alignment: isOutgoing ? .trailing : .leading)
            
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
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
    
    // MARK: - 紧凑版本指示器 (Telegram 风格)
    
    @ViewBuilder
    private var compactVersionIndicator: some View {
        HStack(spacing: 4) {
            Button {
                viewModel.switchToPreviousVersion(of: message)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(message.getCurrentVersionIndex() == 0)
            .opacity(message.getCurrentVersionIndex() > 0 ? 1 : 0.4)
            
            Text("\(message.getCurrentVersionIndex() + 1)/\(message.getAllVersions().count)")
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
            
            Button {
                viewModel.switchToNextVersion(of: message)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(message.getCurrentVersionIndex() >= message.getAllVersions().count - 1)
            .opacity(message.getCurrentVersionIndex() < message.getAllVersions().count - 1 ? 1 : 0.4)
        }
        .foregroundStyle(isOutgoing ? Color.white.opacity(0.8) : Color.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(isOutgoing ? Color.white.opacity(0.2) : Color.secondary.opacity(0.15))
        )
    }
    
    // MARK: - 气泡渐变背景
    
    private var bubbleGradient: some ShapeStyle {
        if isError {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color.red.opacity(0.85), Color.red.opacity(0.7)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        
        switch message.role {
        case .user:
            // Telegram 蓝色渐变
            return AnyShapeStyle(
                LinearGradient(
                    colors: [telegramBlue, telegramBlueDark],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .assistant, .system, .tool:
            // 接收消息：浅灰/白色
            if enableBackground {
                return AnyShapeStyle(Color(UIColor.secondarySystemBackground))
            } else {
                return AnyShapeStyle(Color(uiColor: .systemBackground))
            }
        case .error:
            return AnyShapeStyle(Color.red.opacity(0.15))
        @unknown default:
            return AnyShapeStyle(Color(UIColor.secondarySystemBackground))
        }
    }
    
    // MARK: - Content
    
    @ViewBuilder
    private var contentStack: some View {
        if let imageFileNames = message.imageFileNames, !imageFileNames.isEmpty {
            imageAttachmentsView(fileNames: imageFileNames)
        }
        
        // 思考过程 (Telegram 风格折叠)
        if let reasoning = message.reasoningContent,
           !reasoning.isEmpty {
            DisclosureGroup(isExpanded: $isReasoningExpanded) {
                Text(reasoning)
                    .font(.subheadline)
                    .foregroundStyle(isOutgoing ? Color.white.opacity(0.85) : Color.secondary)
                    .textSelection(.enabled)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 12))
                    Text("思考过程")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(isOutgoing ? Color.white.opacity(0.9) : Color.secondary)
            }
            .tint(isOutgoing ? .white : .secondary)
        }
        
        // 工具调用
        if let toolCalls = message.toolCalls,
           !toolCalls.isEmpty {
            DisclosureGroup(isExpanded: $isToolCallsExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(toolCalls, id: \.id) { call in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(call.toolName)
                                .font(.footnote.weight(.semibold))
                            if let result = call.result, !result.isEmpty {
                                Text(result)
                                    .font(.caption)
                                    .foregroundStyle(isOutgoing ? Color.white.opacity(0.7) : Color.secondary)
                            }
                        }
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isOutgoing ? Color.white.opacity(0.15) : Color.secondary.opacity(0.1))
                        )
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 12))
                    Text("使用工具")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(isOutgoing ? Color.white.opacity(0.9) : Color.secondary)
            }
            .tint(isOutgoing ? .white : .secondary)
        }
        
        // 消息正文
        if !message.content.isEmpty {
            if let audioFileName = message.audioFileName {
                audioPlayerView(fileName: audioFileName)
            } else {
                renderContent(message.content)
                    .font(.body)
                    .foregroundStyle(isOutgoing ? Color.white : Color.primary)
                    .textSelection(.enabled)
            }
        } else if message.role == .assistant {
            // 加载指示器
            HStack(spacing: 8) {
                TelegramTypingIndicator()
                Text("正在思考...")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }
        }
    }
    
    @ViewBuilder
    private func imageAttachmentsView(fileNames: [String]) -> some View {
        let columns = [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 4)]
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(fileNames, id: \.self) { fileName in
                if let image = loadImage(fileName: fileName) {
                    Button {
                        imagePreview = ImagePreviewPayload(image: image)
                    } label: {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(minWidth: 80, maxWidth: 140)
                            .frame(height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 100)
                        .overlay(
                            VStack(spacing: 4) {
                                Image(systemName: "photo")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.secondary)
                                Text("图片丢失")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        )
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
                .markdownTextStyle {
                    ForegroundColor(isOutgoing ? .white : .primary)
                }
        } else {
            Text(content)
        }
    }
    
    @ViewBuilder
    private func audioPlayerView(fileName: String) -> some View {
        let foregroundColor = isOutgoing ? Color.white : Color.primary
        let secondaryColor = isOutgoing ? Color.white.opacity(0.7) : Color.secondary
        
        HStack(spacing: 12) {
            // 播放按钮
            Button {
                audioPlayer.togglePlayback(fileName: fileName)
            } label: {
                ZStack {
                    Circle()
                        .fill(isOutgoing ? Color.white.opacity(0.2) : Color.secondary.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: audioPlayer.isPlaying && audioPlayer.currentFileName == fileName ? "stop.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(foregroundColor)
                }
            }
            .buttonStyle(.plain)
            
            VStack(alignment: .leading, spacing: 4) {
                // 波形动画 / 进度条
                TelegramWaveformView(
                    progress: audioPlayer.currentFileName == fileName ? audioPlayer.progress : 0,
                    isPlaying: audioPlayer.isPlaying && audioPlayer.currentFileName == fileName,
                    foregroundColor: foregroundColor,
                    backgroundColor: secondaryColor.opacity(0.4)
                )
                .frame(height: 20)
                
                // 时长
                if audioPlayer.currentFileName == fileName && audioPlayer.duration > 0 {
                    Text(audioPlayer.timeString)
                        .font(.caption2)
                        .foregroundStyle(secondaryColor)
                        .monospacedDigit()
                } else {
                    Text(fileName)
                        .font(.caption2)
                        .foregroundStyle(secondaryColor)
                        .lineLimit(1)
                }
            }
        }
        .frame(minWidth: 180)
    }
}

// MARK: - Telegram 输入指示器动画

struct TelegramTypingIndicator: View {
    @State private var animationPhase = 0
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .scaleEffect(animationPhase == index ? 1.2 : 0.8)
                    .opacity(animationPhase == index ? 1 : 0.5)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: false)) {
                animationPhase = 3
            }
        }
        .onReceive(Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()) { _ in
            animationPhase = (animationPhase + 1) % 3
        }
    }
}

// MARK: - Telegram 波形视图

struct TelegramWaveformView: View {
    let progress: Double
    let isPlaying: Bool
    let foregroundColor: Color
    let backgroundColor: Color
    
    private let barCount = 28
    private let heights: [CGFloat] = (0..<28).map { _ in CGFloat.random(in: 0.3...1.0) }
    
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    let barProgress = Double(index) / Double(barCount)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(barProgress <= progress ? foregroundColor : backgroundColor)
                        .frame(width: 2, height: geo.size.height * heights[index])
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
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
            print(String(format: NSLocalizedString("无法加载音频文件: %@", comment: ""), fileName))
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
            // 播放音频失败
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
