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
import ETOSCore

/// Telegram 风格的消息输入框
struct TelegramMessageComposer: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var appConfig = AppConfigStore.shared
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
    @StateObject private var inlineSpeechRecorder = InlineSpeechRecorderController()
    @State private var inlineSpeechFinalizeTask: Task<Void, Never>?
    @State private var showInlineSpeechError = false
    @State private var inlineSpeechErrorMessage: String?

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
    private var composerReservedHeight: CGFloat {
        max(controlSize, compactInputHeight) + 16
    }
    private var estimatedCompactInputWidth: CGFloat {
        max(0, UIScreen.main.bounds.width - 16 * 2 - controlSize * 2 - 12 * 2)
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

            Color.clear
                .frame(height: composerReservedHeight)
                .overlay(alignment: .bottom) {
                    composerOverlayContent
                }
                .zIndex(1)
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
        .alert(NSLocalizedString("语音输入错误", comment: ""), isPresented: $showInlineSpeechError) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) { }
        } message: {
            Text(inlineSpeechErrorMessage ?? NSLocalizedString("发生未知错误，请稍后重试。", comment: ""))
        }
        .onDisappear {
            inlineSpeechFinalizeTask?.cancel()
            inlineSpeechFinalizeTask = nil
            inlineSpeechRecorder.cancel()
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

    private var composerOverlayContent: some View {
        // 固定占位交给外层 Color.clear，真实输入框在 overlay 中按自身高度展开。
        composerContent
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .bottom)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isExpandedComposer)
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: inlineSpeechRecorder.phase)
    }

    @ViewBuilder
    private var composerContent: some View {
        if inlineSpeechRecorder.phase.isActive {
            inlineSpeechComposer
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
        } else {
            composerInputRow
                .transition(.asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
        }
    }

    private var composerInputRow: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if !isExpandedComposer {
                attachmentMenuButton(size: controlSize)
            }

            inputFieldShell

            if !isExpandedComposer {
                actionControlButton(size: controlSize)
            }
        }
    }

    private var inputFieldShell: some View {
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
        .overlay(alignment: .bottomTrailing) {
            if isExpandedComposer {
                actionControlButton(size: expandedControlSize)
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
            }
        }
        .onPreferenceChange(InputWidthKey.self, perform: updateInputWidth)
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
                startInlineSpeechRecording()
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
                .padding(.leading, textHorizontalPadding)
                .padding(.trailing, expandedActionTrailingInset)

            if text.isEmpty {
                inputPlaceholder
                    .padding(.top, verticalPadding + textContainerInset)
                    .padding(.leading, textHorizontalPadding + textContainerInset)
                    .padding(.trailing, textHorizontalPadding + textContainerInset)
            }
        }
        .frame(minHeight: targetHeight, maxHeight: targetHeight)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isExpandedComposer)
    }

    @ViewBuilder
    private var inputPlaceholder: some View {
        Text(inputPlaceholderText)
            .etFont(.system(size: inputBasePointSize))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inputPlaceholderText: String {
        return NSLocalizedString("Message", comment: "聊天输入框占位文本")
    }

    private var expandedActionTrailingInset: CGFloat {
        textHorizontalPadding + (isExpandedComposer ? expandedControlSize + 16 : 0)
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

    private var inlineSpeechComposer: some View {
        InlineSpeechComposerBar(
            phase: inlineSpeechRecorder.phase,
            samples: inlineSpeechRecorder.waveformSamples,
            duration: inlineSpeechRecorder.recordingDuration,
            isPlayingPreview: inlineSpeechRecorder.isPlayingPreview,
            sendsAudioAttachment: viewModel.sendSpeechAsAudio,
            cancelAction: cancelInlineSpeechRecording,
            stopAction: stopInlineSpeechRecording,
            confirmAction: confirmInlineSpeechRecording,
            playbackAction: {
                inlineSpeechRecorder.togglePreviewPlayback()
            }
        )
        .frame(maxWidth: .infinity, minHeight: controlSize)
    }

    private func startInlineSpeechRecording() {
        inlineSpeechFinalizeTask?.cancel()
        inlineSpeechFinalizeTask = nil
        audioRecorderEntryMode = .speechInput
        inlineSpeechRecorder.prepareForRecording()
        focus.wrappedValue = false
        Task { @MainActor in
            do {
                try validateInlineSpeechInput()
                await Task.yield()
                try await inlineSpeechRecorder.start(format: viewModel.audioRecordingFormat)
            } catch {
                inlineSpeechErrorMessage = error.localizedDescription
                showInlineSpeechError = true
                inlineSpeechRecorder.cancel()
            }
        }
    }

    private func stopInlineSpeechRecording() {
        inlineSpeechRecorder.stopForPreview()
        if viewModel.sendSpeechAsAudio {
            scheduleInlineAudioAttachment()
        } else {
            transcribeInlineSpeechRecording()
        }
    }

    private func confirmInlineSpeechRecording() {
        inlineSpeechFinalizeTask?.cancel()
        inlineSpeechFinalizeTask = nil
        if viewModel.sendSpeechAsAudio {
            completeInlineAudioAttachment()
        } else {
            transcribeInlineSpeechRecording()
        }
    }

    private func cancelInlineSpeechRecording() {
        inlineSpeechFinalizeTask?.cancel()
        inlineSpeechFinalizeTask = nil
        inlineSpeechRecorder.cancel()
    }

    private func scheduleInlineAudioAttachment() {
        inlineSpeechFinalizeTask?.cancel()
        inlineSpeechFinalizeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            completeInlineAudioAttachment()
        }
    }

    private func completeInlineAudioAttachment() {
        do {
            if inlineSpeechRecorder.phase == .recording {
                inlineSpeechRecorder.stopForPreview()
            }
            let attachment = try inlineSpeechRecorder.makeAttachment(format: viewModel.audioRecordingFormat)
            viewModel.setAudioAttachment(attachment)
            inlineSpeechRecorder.cancel()
        } catch {
            inlineSpeechErrorMessage = error.localizedDescription
            showInlineSpeechError = true
            inlineSpeechRecorder.cancel()
        }
    }

    private func transcribeInlineSpeechRecording() {
        inlineSpeechFinalizeTask?.cancel()
        inlineSpeechFinalizeTask = nil
        inlineSpeechRecorder.beginTranscribing()
        Task { @MainActor in
            do {
                let model = try selectedInlineSpeechModel()
                let attachment = try inlineSpeechRecorder.makeAttachment(format: viewModel.audioRecordingFormat)
                let transcript: String
                if ChatService.isSystemSpeechRecognizerModel(model) {
                    transcript = try await SystemSpeechRecognizerService.transcribe(
                        audioData: attachment.data,
                        fileExtension: attachment.format
                    )
                } else {
                    transcript = try await viewModel.transcribeAudioAttachment(using: model, attachment: attachment)
                }
                let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedTranscript.isEmpty else {
                    throw NSError(
                        domain: "InlineSpeechRecorder",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("未识别到有效语音内容。", comment: "")]
                    )
                }
                appendTranscribedTextToComposer(trimmedTranscript)
                inlineSpeechRecorder.cancel()
            } catch {
                inlineSpeechErrorMessage = error.localizedDescription
                showInlineSpeechError = true
                inlineSpeechRecorder.cancel()
            }
        }
    }

    private func validateInlineSpeechInput() throws {
        guard viewModel.enableSpeechInput else {
            throw NSError(
                domain: "InlineSpeechRecorder",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("语言输入已被关闭。", comment: "")]
            )
        }
        guard viewModel.sendSpeechAsAudio || (viewModel.selectedSpeechModel ?? viewModel.speechModels.first) != nil else {
            throw NSError(
                domain: "InlineSpeechRecorder",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("请选择一个语音转文字模型。", comment: "")]
            )
        }
    }

    private func selectedInlineSpeechModel() throws -> RunnableModel {
        if let model = viewModel.selectedSpeechModel ?? viewModel.speechModels.first {
            return model
        }
        throw NSError(
            domain: "InlineSpeechRecorder",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("请选择一个语音转文字模型。", comment: "")]
        )
    }

    private func appendTranscribedTextToComposer(_ transcript: String) {
        viewModel.appendTranscribedText(transcript)
        text = viewModel.userInput
    }

    private func updateInputWidth(_ width: CGFloat) {
        if abs(width - inputAvailableWidth) > 0.5 {
            inputAvailableWidth = width
        }
        let compactWidthChanged = abs(width - compactInputWidth) > 0.5
        if !isExpandedComposer && compactWidthChanged {
            compactInputWidth = width
        }
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

        let baseWidth = compactInputWidth > 0
            ? compactInputWidth
            : (inputAvailableWidth > 0 ? inputAvailableWidth : estimatedCompactInputWidth)
        let availableWidth = baseWidth
            - textHorizontalPadding * 2
            - textContainerInset * 2
        let hasExplicitNewline = newValue.contains("\n")
        var shouldExpand = hasExplicitNewline

        if availableWidth > 0 {
            let lineCount = measuredTextLineCount(for: newValue, width: availableWidth)
            shouldExpand = hasExplicitNewline || lineCount > 1
        }

        if shouldExpand {
            let wasFocused = focus.wrappedValue
            guard !isExpandedComposer else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                isExpandedComposer = true
            }
            if wasFocused {
                focus.wrappedValue = true
            }
        } else if isExpandedComposer {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                isExpandedComposer = false
            }
        }
    }

    private func measuredTextLineCount(for value: String, width: CGFloat) -> Int {
        let textStorage = NSTextStorage(string: value, attributes: [.font: inputUIFont])
        let layoutManager = NSLayoutManager()
        layoutManager.usesFontLeading = true

        let textContainer = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        // 数实际行片段，避免单行字体 leading 被高度换算误判成两行。
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = .byWordWrapping

        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        var lineCount = 0
        layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: textContainer)) { _, _, _, _, _ in
            lineCount += 1
        }
        return max(lineCount, 1)
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
