// ============================================================================
// ChatViewTelegramMessageComposer.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 ChatView 中 Telegram 风格的新输入栏组件。
// ============================================================================

import SwiftUI
import Foundation
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import Shared

/// Telegram 风格的消息输入框
struct TelegramMessageComposer: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var appConfig = AppConfigStore.shared
    @ObservedObject private var resourceUsageMonitor = LocalResourceUsageMonitor.shared
    @Binding var text: String
    let isSending: Bool
    let sendAction: () -> Void
    let stopAction: () -> Void
    let focus: FocusState<Bool>.Binding

    @State private var showImagePicker = false
    @State private var showCamera = false
    @State private var showAudioRecorder = false
    @State private var audioRecorderSheetDetent: PresentationDetent = .fraction(0.5)
    @State private var audioRecorderEntryMode: AudioRecorderEntryMode = .attachment
    @State private var showAudioImporter = false
    @State private var showFileImporter = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isExpandedComposer = false
    @State private var inputAvailableWidth: CGFloat = 0
    @State private var compactInputWidth: CGFloat = 0
    @State private var resourceUsageTask: Task<Void, Never>?

    private let controlSize: CGFloat = 40
    private let expandedControlSize: CGFloat = 34
    private var effectiveFontScale: CGFloat {
        CGFloat(FontLibrary.effectiveFontScale(appConfig.fontCustomScale, isCustomFontEnabled: appConfig.fontUseCustomFonts))
    }
    private let inputBasePointSize: CGFloat = 16
    private var measuredInputPointSize: CGFloat {
        CGFloat(FontLibrary.scaledPointSize(Double(inputBasePointSize), scale: appConfig.fontCustomScale, isCustomFontEnabled: appConfig.fontUseCustomFonts))
    }
    private var inputUIFont: UIFont {
        .systemFont(ofSize: measuredInputPointSize)
    }
    private var compactInputHeight: CGFloat {
        max(44, inputUIFont.lineHeight + compactTextVerticalPadding * 2 + textContainerInset * 2)
    }
    private var expandedInputHeight: CGFloat {
        let rawHeight = UIScreen.main.bounds.height * 0.3
        return max(160 * effectiveFontScale, min(rawHeight, 360 * effectiveFontScale))
    }
    private let textContainerInset: CGFloat = 8
    private let textHorizontalPadding: CGFloat = 10
    private var compactTextVerticalPadding: CGFloat {
        max(4, 4 * effectiveFontScale)
    }
    private var expandedTextVerticalPadding: CGFloat {
        max(6, 6 * effectiveFontScale)
    }
    private var isLiquidGlassEnabled: Bool {
        if #available(iOS 26.0, *) {
            return viewModel.enableLiquidGlass
        }
        return false
    }
    private var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }
    private var composerCornerRadius: CGFloat {
        isExpandedComposer ? 18 : compactInputHeight / 2
    }
    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || viewModel.pendingAudioAttachment != nil
            || !viewModel.pendingImageAttachments.isEmpty
            || !viewModel.pendingFileAttachments.isEmpty
    }
    private var canQuickRetry: Bool {
        viewModel.canQuickRetryLatestMessage
    }

    var body: some View {
        VStack(spacing: 8) {
            if !viewModel.pendingImageAttachments.isEmpty || viewModel.pendingAudioAttachment != nil || !viewModel.pendingFileAttachments.isEmpty {
                telegramAttachmentPreview
                    .padding(.horizontal, 16)
            }

            HStack(alignment: .bottom, spacing: 12) {
                if !isExpandedComposer {
                    attachmentMenuButton(size: controlSize)
                }

                HStack(alignment: .bottom, spacing: 8) {
                    inputEditor
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: controlSize)
                .background(glassRoundedBackground(cornerRadius: composerCornerRadius))
                .overlay {
                    GeometryReader { proxy in
                        Color.clear
                            .preference(key: InputWidthKey.self, value: proxy.size.width)
                    }
                }
                .onPreferenceChange(InputWidthKey.self) { width in
                    if abs(width - inputAvailableWidth) > 0.5 {
                        inputAvailableWidth = width
                    }
                    if !isExpandedComposer, abs(width - compactInputWidth) > 0.5 {
                        compactInputWidth = width
                    }
                }

                if !isExpandedComposer {
                    actionControlButton(size: controlSize)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isExpandedComposer)
        }
        .padding(.bottom, 6)
        .photosPicker(isPresented: $showImagePicker, selection: $selectedPhotos, matching: .images)
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
        .onChange(of: text) { _, newValue in
            handleAutoExpand(for: newValue)
        }
        .onChange(of: inputAvailableWidth) { _, _ in
            handleAutoExpand(for: text)
        }
        .onChange(of: showAudioRecorder) { _, presented in
            if presented {
                audioRecorderSheetDetent = .fraction(0.5)
            }
        }
        .onChange(of: focus.wrappedValue) { _, isFocused in
            if isFocused {
                handleAutoExpand(for: text)
            } else if isExpandedComposer {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    isExpandedComposer = false
                }
            }
        }
        .onAppear {
            updateResourceUsageSampling()
        }
        .onChange(of: viewModel.selectedModel?.id) { _, _ in
            updateResourceUsageSampling()
        }
        .onDisappear {
            stopResourceUsageSampling()
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraImagePicker(isPresented: $showCamera) { image in
                if let image {
                    viewModel.addImageAttachment(image)
                }
            }
        }
        .sheet(isPresented: $showAudioRecorder) {
            AudioRecorderSheet(
                format: viewModel.audioRecordingFormat,
                mode: recorderMode,
                transcribeRemotely: { model, attachment in
                    try await viewModel.transcribeAudioAttachment(using: model, attachment: attachment)
                },
                onCompleteAudio: { attachment in
                    viewModel.setAudioAttachment(attachment)
                },
                onCompleteTranscript: { transcript in
                    appendTranscribedTextToComposer(transcript)
                }
            )
            .presentationDetents([.fraction(0.5), .large], selection: $audioRecorderSheetDetent)
            .presentationDragIndicator(.visible)
        }
        .fileImporter(
            isPresented: $showAudioImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importAudioAttachment(from: url)
            case .failure(let error):
                print(String(format: NSLocalizedString("无法加载音频文件: %@", comment: ""), error.localizedDescription))
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    importFileAttachment(from: url)
                }
            case .failure(let error):
                print(String(format: NSLocalizedString("无法加载文件: %@", comment: ""), error.localizedDescription))
            }
        }
    }

    private func attachmentMenuButton(size: CGFloat) -> some View {
        Menu {
            Button {
                showImagePicker = true
            } label: {
                Label(NSLocalizedString("选择图片", comment: ""), systemImage: "photo")
            }

            Button {
                showCamera = true
            } label: {
                Label(NSLocalizedString("拍照", comment: ""), systemImage: "camera")
            }
            .disabled(!isCameraAvailable)

            Button {
                audioRecorderEntryMode = .attachment
                showAudioRecorder = true
            } label: {
                Label(NSLocalizedString("录制语音", comment: ""), systemImage: "waveform")
            }

            Button {
                showAudioImporter = true
            } label: {
                Label(NSLocalizedString("从录音备忘录上传", comment: ""), systemImage: "music.note.list")
            }

            Button {
                showFileImporter = true
            } label: {
                Label(NSLocalizedString("选择文件", comment: ""), systemImage: "doc")
            }
        } label: {
            Image(systemName: "paperclip")
                .etFont(.system(size: max(14, size * 0.45), weight: .semibold))
                .foregroundColor(TelegramColors.attachButtonColor)
                .frame(width: size, height: size)
                .background(glassCircleBackground)
        }
        .buttonStyle(.plain)
    }

    private func actionControlButton(size: CGFloat) -> some View {
        Button {
            if isSending {
                stopAction()
            } else if hasContent {
                sendAction()
            } else if canQuickRetry {
                viewModel.quickRetryLatestMessage()
            } else if viewModel.enableSpeechInput {
                audioRecorderEntryMode = .speechInput
                showAudioRecorder = true
            } else {
                focus.wrappedValue = true
            }
        } label: {
            Image(systemName: actionIconName)
                .etFont(.system(size: max(14, size * 0.45), weight: .semibold))
                .foregroundColor(actionForegroundColor)
                .frame(width: size, height: size)
                .background(actionBackground)
        }
        .buttonStyle(.plain)
        .disabled(!isSending && hasContent && !viewModel.canSendMessage)
    }

    @ViewBuilder
    private var inputEditor: some View {
        let targetHeight = isExpandedComposer ? expandedInputHeight : compactInputHeight
        let verticalPadding = isExpandedComposer ? expandedTextVerticalPadding : compactTextVerticalPadding

        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .etFont(.system(size: inputBasePointSize))
                .focused(focus)
                .scrollContentBackground(.hidden)
                .scrollDisabled(!isExpandedComposer)
                .padding(.vertical, verticalPadding)
                .padding(.horizontal, textHorizontalPadding)

            if text.isEmpty {
                Text(inputPlaceholderText)
                    .etFont(.system(size: inputBasePointSize))
                    .foregroundColor(.secondary)
                    .padding(.top, verticalPadding + textContainerInset)
                    .padding(.leading, textHorizontalPadding + textContainerInset)
            }
        }
        .frame(minHeight: targetHeight, maxHeight: targetHeight)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isExpandedComposer)
    }

    private var inputPlaceholderText: String {
        if LocalModelProviderBridge.isLocalRunnableModel(viewModel.selectedModel) {
            return resourceUsageMonitor.snapshot.displayText
        }
        return NSLocalizedString("Message", comment: "聊天输入框占位文本")
    }

    private var recorderMode: AudioRecorderSheet.Mode {
        guard audioRecorderEntryMode == .speechInput, viewModel.enableSpeechInput else {
            return .audioAttachment
        }
        guard !viewModel.sendSpeechAsAudio else {
            return .audioAttachment
        }
        if let model = viewModel.selectedSpeechModel ?? viewModel.speechModels.first {
            return .speechToText(model: model)
        }
        return .audioAttachment
    }

    private func appendTranscribedTextToComposer(_ transcript: String) {
        viewModel.appendTranscribedText(transcript)
        text = viewModel.userInput
    }

    private func handleAutoExpand(for newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if isExpandedComposer {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    isExpandedComposer = false
                }
            }
            return
        }

        let hasExplicitNewline = newValue.contains("\n")
        var shouldExpand = hasExplicitNewline

        if !shouldExpand {
            let baseWidth = compactInputWidth > 0 ? compactInputWidth : inputAvailableWidth
            let availableWidth = baseWidth
                - textHorizontalPadding * 2
                - textContainerInset * 2
            if availableWidth > 0 {
                let boundingRect = (newValue as NSString).boundingRect(
                    with: CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: inputUIFont],
                    context: nil
                )
                let lineCount = max(1, Int(ceil(boundingRect.height / inputUIFont.lineHeight)))
                shouldExpand = lineCount > 1
            }
        }

        if shouldExpand {
            guard focus.wrappedValue else { return }
            guard !isExpandedComposer else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                isExpandedComposer = true
            }
            focus.wrappedValue = true
        } else if isExpandedComposer {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                isExpandedComposer = false
            }
        }
    }

    private func updateResourceUsageSampling() {
        guard LocalModelProviderBridge.isLocalRunnableModel(viewModel.selectedModel) else {
            stopResourceUsageSampling()
            return
        }
        guard resourceUsageTask == nil else { return }
        resourceUsageTask = Task { @MainActor in
            while !Task.isCancelled {
                resourceUsageMonitor.refresh()
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func stopResourceUsageSampling() {
        resourceUsageTask?.cancel()
        resourceUsageTask = nil
    }

    private struct InputWidthKey: PreferenceKey {
        static var defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    private var actionIconName: String {
        if isSending {
            return "stop.fill"
        }
        if hasContent {
            return "arrow.up"
        }
        if canQuickRetry {
            return "arrow.clockwise"
        }
        if viewModel.enableSpeechInput {
            return "mic.fill"
        }
        return "arrow.up"
    }

    private var actionForegroundColor: Color {
        if isSending {
            return .white
        }
        if hasContent {
            return viewModel.canSendMessage ? .white : Color.primary.opacity(0.55)
        }
        if canQuickRetry {
            return .white
        }
        return TelegramColors.attachButtonColor
    }

    @ViewBuilder
    private var actionBackground: some View {
        if isSending {
            actionCircleBackground(fill: Color.red.opacity(0.85))
        } else if hasContent {
            let fillColor = viewModel.canSendMessage
                ? TelegramColors.sendButtonColor
                : Color.primary.opacity(0.12)
            actionCircleBackground(fill: fillColor)
        } else if canQuickRetry {
            actionCircleBackground(fill: TelegramColors.sendButtonColor)
        } else {
            glassCircleBackground
        }
    }

    @ViewBuilder
    private func actionCircleBackground(fill: Color) -> some View {
        if isLiquidGlassEnabled {
            if #available(iOS 26.0, *) {
                Circle()
                    .fill(Color.clear)
                    .glassEffect(.clear, in: Circle())
                    .overlay(
                        Circle()
                            .fill(fill.opacity(0.82))
                    )
                    .overlay(
                        Circle()
                            .stroke(glassStrokeColor, lineWidth: 0.5)
                    )
                    .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
            } else {
                Circle()
                    .fill(fill)
                    .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
            }
        } else {
            Circle()
                .fill(fill)
                .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
        }
    }

    private var glassCircleBackground: some View {
        Group {
            if isLiquidGlassEnabled {
                if #available(iOS 26.0, *) {
                    Circle()
                        .fill(Color.clear)
                        .glassEffect(.clear, in: Circle())
                        .overlay(
                            Circle()
                                .fill(glassOverlayColor)
                        )
                        .overlay(
                            Circle()
                                .stroke(glassStrokeColor, lineWidth: 0.5)
                        )
                        .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                } else {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle()
                                .fill(glassOverlayColor)
                        )
                        .overlay(
                            Circle()
                                .stroke(glassStrokeColor, lineWidth: 0.5)
                        )
                        .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                }
            } else {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle()
                            .fill(glassOverlayColor)
                    )
                    .overlay(
                        Circle()
                            .stroke(glassStrokeColor, lineWidth: 0.5)
                    )
                    .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
            }
        }
    }

    func glassRoundedBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return Group {
            if isLiquidGlassEnabled {
                if #available(iOS 26.0, *) {
                    shape
                        .fill(Color.clear)
                        .glassEffect(.clear, in: shape)
                        .overlay(
                            shape
                                .fill(glassOverlayColor)
                        )
                        .overlay(
                            shape
                                .stroke(glassStrokeColor, lineWidth: 0.5)
                        )
                        .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                } else {
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay(
                            shape
                                .fill(glassOverlayColor)
                        )
                        .overlay(
                            shape
                                .stroke(glassStrokeColor, lineWidth: 0.5)
                        )
                        .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                }
            } else {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(
                        shape
                            .fill(glassOverlayColor)
                    )
                    .overlay(
                        shape
                            .stroke(glassStrokeColor, lineWidth: 0.5)
                    )
                    .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
            }
        }
    }

    private var glassOverlayColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.24) : Color.white.opacity(0.2)
    }

    private var glassStrokeColor: Color {
        Color.white.opacity(colorScheme == .dark ? 0.18 : 0.28)
    }

    private var glassShadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1)
    }
}
