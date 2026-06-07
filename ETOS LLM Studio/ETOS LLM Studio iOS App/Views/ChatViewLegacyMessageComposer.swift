// ============================================================================
// ChatViewLegacyMessageComposer.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 ChatView 中旧版兼容消息输入栏组件。
// ============================================================================

import SwiftUI
import Foundation
import PhotosUI
import UIKit
import ETOSCore

struct MessageComposerView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Binding var text: String
    let isSending: Bool
    let sendAction: () -> Void
    let focus: FocusState<Bool>.Binding

    @State private var showAttachmentMenu = false
    @State private var showImagePicker = false
    @State private var showAudioRecorder = false
    @State private var audioRecorderSheetDetent: PresentationDetent = .fraction(0.5)
    @State private var audioRecorderEntryMode: AudioRecorderEntryMode = .attachment
    @State private var showFileImporter = false
    @State private var selectedPhotos: [PhotosPickerItem] = []

    var body: some View {
        VStack(spacing: 8) {
            if !viewModel.pendingImageAttachments.isEmpty || viewModel.pendingAudioAttachment != nil || !viewModel.pendingFileAttachments.isEmpty {
                attachmentPreviewBar
                    .padding(.horizontal, 12)
            }

            HStack(alignment: .center, spacing: 12) {
                if #available(iOS 26.0, *) {
                    Button {
                        showAttachmentMenu = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .etFont(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .glassEffect(.clear, in: Circle())
                    .confirmationDialog(NSLocalizedString("添加附件", comment: ""), isPresented: $showAttachmentMenu) {
                        Button(NSLocalizedString("选择图片", comment: "")) {
                            showImagePicker = true
                        }
                        Button(NSLocalizedString("录制语音", comment: "")) {
                            audioRecorderEntryMode = .attachment
                            showAudioRecorder = true
                        }
                        Button(NSLocalizedString("选择文件", comment: "")) {
                            showFileImporter = true
                        }
                    }
                } else {
                    Button {
                        showAttachmentMenu = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .etFont(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .confirmationDialog(NSLocalizedString("添加附件", comment: ""), isPresented: $showAttachmentMenu) {
                        Button(NSLocalizedString("选择图片", comment: "")) {
                            showImagePicker = true
                        }
                        Button(NSLocalizedString("录制语音", comment: "")) {
                            audioRecorderEntryMode = .attachment
                            showAudioRecorder = true
                        }
                        Button(NSLocalizedString("选择文件", comment: "")) {
                            showFileImporter = true
                        }
                    }
                }

                if #available(iOS 26.0, *) {
                    HStack(spacing: 8) {
                        TextField(NSLocalizedString("Message", comment: "聊天输入框占位文本"), text: $text, axis: .vertical)
                            .lineLimit(1...6)
                            .textFieldStyle(.plain)
                            .focused(focus)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .glassEffect(.clear, in: Capsule())
                } else {
                    HStack(spacing: 8) {
                        TextField(NSLocalizedString("Message", comment: "聊天输入框占位文本"), text: $text, axis: .vertical)
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

                if #available(iOS 26.0, *) {
                    Button {
                        sendAction()
                    } label: {
                        Image(systemName: isSending ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .etFont(.system(size: 28))
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
                            .etFont(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(!viewModel.canSendMessage)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
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
        .onChange(of: showAudioRecorder) { _, presented in
            if presented {
                audioRecorderSheetDetent = .fraction(0.5)
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

    @ViewBuilder
    private var attachmentPreviewBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.pendingImageAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(viewModel.pendingImageAttachments) { attachment in
                            ZStack(alignment: .topTrailing) {
                                if let thumbnail = attachment.thumbnailImage {
                                    Image(uiImage: thumbnail)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 60, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                } else {
                                    ZStack {
                                        Color(uiColor: .secondarySystemBackground)
                                        Image(systemName: "photo")
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }

                                Button {
                                    viewModel.removePendingImageAttachment(attachment)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .etFont(.system(size: 18))
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(height: 68)
            }

            if let audio = viewModel.pendingAudioAttachment {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .etFont(.system(size: 16))
                        .foregroundStyle(.tint)

                    Text(audio.fileName)
                        .etFont(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: 80)

                    Button {
                        viewModel.clearPendingAudioAttachment()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .etFont(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            ForEach(viewModel.pendingFileAttachments) { attachment in
                HStack(spacing: 6) {
                    Image(systemName: "doc")
                        .etFont(.system(size: 16))
                        .foregroundStyle(.tint)

                    Text(attachment.fileName)
                        .etFont(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: 120)

                    Button {
                        viewModel.removePendingFileAttachment(attachment)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .etFont(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func importFileAttachment(from url: URL) {
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
}
