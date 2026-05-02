// ============================================================================
// ChatView+TelegramComposerLayout.swift
// ============================================================================
// iOS Telegram 风格输入栏的布局、焦点、发送按钮与菜单控件。
// ============================================================================

import SwiftUI
import Foundation
import MarkdownUI
import Shared
import UIKit
import PhotosUI
import Photos
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Telegram 主题颜色
extension TelegramMessageComposer {
    var effectiveFontScale: CGFloat {
        CGFloat(FontLibrary.effectiveFontScale(customFontScale, isCustomFontEnabled: isCustomFontEnabled))
    }
    var measuredInputPointSize: CGFloat {
        CGFloat(FontLibrary.scaledPointSize(Double(inputBasePointSize), scale: customFontScale, isCustomFontEnabled: isCustomFontEnabled))
    }
    var inputUIFont: UIFont {
        .systemFont(ofSize: measuredInputPointSize)
    }
    var compactInputHeight: CGFloat {
        max(44, inputUIFont.lineHeight + compactTextVerticalPadding * 2 + textContainerInset * 2)
    }
    var expandedInputHeight: CGFloat {
        let rawHeight = UIScreen.main.bounds.height * 0.3
        return max(160 * effectiveFontScale, min(rawHeight, 360 * effectiveFontScale))
    }
    var compactTextVerticalPadding: CGFloat {
        max(4, 4 * effectiveFontScale)
    }
    var expandedTextVerticalPadding: CGFloat {
        max(6, 6 * effectiveFontScale)
    }
    var isLiquidGlassEnabled: Bool {
        if #available(iOS 26.0, *) {
            return viewModel.enableLiquidGlass
        }
        return false
    }
    var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }
    var composerCornerRadius: CGFloat {
        isExpandedComposer ? 18 : compactInputHeight / 2
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // 附件预览区域
            if !viewModel.pendingImageAttachments.isEmpty || viewModel.pendingAudioAttachment != nil || !viewModel.pendingFileAttachments.isEmpty {
                telegramAttachmentPreview
                    .padding(.horizontal, 16)
            }
            
            // 主输入栏
            HStack(alignment: .bottom, spacing: 12) {
                if !isExpandedComposer {
                    attachmentMenuButton(size: controlSize)
                }
                
                // 输入框容器
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
                
                // 麦克风 / 发送 / 停止按钮
                if !isExpandedComposer {
                    actionControlButton(size: controlSize)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isExpandedComposer)

        }
        .padding(.bottom, 6)
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

    func attachmentMenuButton(size: CGFloat) -> some View {
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

    func actionControlButton(size: CGFloat) -> some View {
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
    var inputEditor: some View {
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
                Text(NSLocalizedString("Message", comment: "聊天输入框占位文本"))
                    .etFont(.system(size: inputBasePointSize))
                    .foregroundColor(.secondary)
                    .padding(.top, verticalPadding + textContainerInset)
                    .padding(.leading, textHorizontalPadding + textContainerInset)
            }
        }
        .frame(minHeight: targetHeight, maxHeight: targetHeight)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isExpandedComposer)
    }

    var recorderMode: AudioRecorderSheet.Mode {
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

    func appendTranscribedTextToComposer(_ transcript: String) {
        viewModel.appendTranscribedText(transcript)
        text = viewModel.userInput
    }

    func handleAutoExpand(for newValue: String) {
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

    struct InputWidthKey: PreferenceKey {
        static var defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }
    
    /// Telegram 风格附件预览
    @ViewBuilder
    var telegramAttachmentPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // 图片预览
                ForEach(viewModel.pendingImageAttachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        if let thumbnail = attachment.thumbnailImage {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        
                        Button {
                            viewModel.removePendingImageAttachment(attachment)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.black.opacity(0.5))
                                    .frame(width: 22, height: 22)
                                Image(systemName: "xmark")
                                    .etFont(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .offset(x: 6, y: -6)
                    }
                }
                
                // 音频预览
                if let audio = viewModel.pendingAudioAttachment {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .etFont(.system(size: 18))
                            .foregroundColor(TelegramColors.attachButtonColor)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString("语音消息", comment: ""))
                                .etFont(.system(size: 13, weight: .medium))
                            Text(audio.fileName)
                                .etFont(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        
                        Button {
                            viewModel.clearPendingAudioAttachment()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .etFont(.system(size: 18))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
                }

                // 文件预览
                ForEach(viewModel.pendingFileAttachments) { attachment in
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                            .etFont(.system(size: 18))
                            .foregroundColor(TelegramColors.attachButtonColor)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString("文件", comment: ""))
                                .etFont(.system(size: 13, weight: .medium))
                            Text(attachment.fileName)
                                .etFont(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        
                        Button {
                            viewModel.removePendingFileAttachment(attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .etFont(.system(size: 18))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            glassRoundedBackground(cornerRadius: 18)
        )
    }

    var hasContent: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = viewModel.pendingAudioAttachment != nil || !viewModel.pendingImageAttachments.isEmpty || !viewModel.pendingFileAttachments.isEmpty
        return hasText || hasAttachments
    }

    var canQuickRetry: Bool {
        !hasContent && viewModel.canQuickRetryLatestMessage
    }

    func importAudioAttachment(from url: URL) {
        Task.detached {
            let needsAccess = url.startAccessingSecurityScopedResource()
            defer {
                if needsAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: url)
                let attachment = await AudioAttachment(
                    data: data,
                    mimeType: audioMimeType(for: url),
                    format: audioFormat(for: url),
                    fileName: url.lastPathComponent
                )
                await MainActor.run {
                    viewModel.setAudioAttachment(attachment)
                }
            } catch {
                print(String(format: NSLocalizedString("无法加载音频文件: %@", comment: ""), error.localizedDescription))
            }
        }
    }

    func importFileAttachment(from url: URL) {
        let mimeType = resolvedFileMimeType(for: url)
        Task.detached {
            let needsAccess = url.startAccessingSecurityScopedResource()
            defer {
                if needsAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: url)
                let attachment = FileAttachment(
                    data: data,
                    mimeType: mimeType,
                    fileName: url.lastPathComponent
                )
                await MainActor.run {
                    viewModel.addFileAttachment(attachment)
                }
            } catch {
                print(String(format: NSLocalizedString("无法加载文件: %@", comment: ""), error.localizedDescription))
            }
        }
    }

    func fileMimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        return "application/octet-stream"
    }

    func audioMimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        return ext.isEmpty ? "audio/m4a" : "audio/\(ext)"
    }

    func audioFormat(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? AudioRecordingFormat.aac.fileExtension : ext
    }
    
    var actionIconName: String {
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
    
    var actionForegroundColor: Color {
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
    var actionBackground: some View {
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
    func actionCircleBackground(fill: Color) -> some View {
        if isLiquidGlassEnabled {
            if #available(iOS 26.0, *) {
                Circle()
                    .fill(fill)
                    .glassEffect(.clear, in: Circle())
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

    var glassCircleBackground: some View {
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
    
    var glassCapsuleBackground: some View {
        Group {
            if isLiquidGlassEnabled {
                if #available(iOS 26.0, *) {
                    Capsule()
                        .fill(Color.clear)
                        .glassEffect(.clear, in: Capsule())
                        .overlay(
                            Capsule()
                                .fill(glassOverlayColor)
                        )
                        .overlay(
                            Capsule()
                                .stroke(glassStrokeColor, lineWidth: 0.5)
                        )
                        .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                } else {
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Capsule()
                                .fill(glassOverlayColor)
                        )
                        .overlay(
                            Capsule()
                                .stroke(glassStrokeColor, lineWidth: 0.5)
                        )
                        .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                }
            } else {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .fill(glassOverlayColor)
                    )
                    .overlay(
                        Capsule()
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
}
