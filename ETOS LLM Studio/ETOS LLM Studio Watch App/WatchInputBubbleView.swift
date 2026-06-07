// ============================================================================
// WatchInputBubbleView.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 watchOS 聊天输入栏、附件预览、模型切换与语音入口。
// ============================================================================

import SwiftUI
import ETOSCore

struct WatchInputBubbleView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject private var resourceUsageMonitor = LocalResourceUsageMonitor.shared

    let isLiquidGlassEnabled: Bool
    let inputControlHeight: CGFloat
    let inputFillColor: Color
    let inputStrokeColor: Color
    let inputPlaceholderText: String
    let inputBubbleVerticalPadding: CGFloat
    let onOpenSessionHistory: () -> Void
    let onHandleInputAction: (WatchChatInputActionState) -> Void
    let onRememberAttachmentSource: (String) -> Void
    let importSourceHistory: [String]
    let lastAttachmentSource: String
    @Binding var isRequestControlsPresented: Bool
    @Binding var isAttachmentImportPresented: Bool
    @Binding var attachmentSourceText: String
    @State private var resourceUsageTask: Task<Void, Never>?

    private var hasPendingAttachments: Bool {
        viewModel.pendingAudioAttachment != nil
            || !viewModel.pendingImageAttachments.isEmpty
            || !viewModel.pendingFileAttachments.isEmpty
    }

    private var hasAttachmentImportProgress: Bool {
        viewModel.attachmentImportProgress != nil || viewModel.attachmentImportInProgress
    }

    private var transparentInputField: some View {
        ZStack(alignment: .leading) {
            inputDisplayText
            TextField("", text: $viewModel.userInput.watchKeyboardNewlineBinding())
                .textFieldStyle(.plain)
                .opacity(0.01)
                .accessibilityLabel(NSLocalizedString("输入...", comment: ""))
        }
        .etFont(.body, sampleText: viewModel.userInput.isEmpty ? inputSampleText : viewModel.userInput)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: inputControlHeight, maxHeight: inputControlHeight, alignment: .leading)
        .layoutPriority(1)
    }

    private var inputSampleText: String {
        if LocalModelProviderBridge.isLocalRunnableModel(viewModel.selectedModel) {
            return resourceUsageMonitor.snapshot.displayText
        }
        return inputPlaceholderText
    }

    @ViewBuilder
    private var inputDisplayText: some View {
        if viewModel.userInput.isEmpty {
            if LocalModelProviderBridge.isLocalRunnableModel(viewModel.selectedModel) {
                MarqueeText(
                    content: resourceUsageMonitor.snapshot.displayText,
                    uiFont: .preferredFont(forTextStyle: .body),
                    speed: 28,
                    delay: 0.8,
                    spacing: 24
                )
                .etFont(.body, sampleText: resourceUsageMonitor.snapshot.displayText)
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(inputPlaceholderText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .allowsHitTesting(false)
                    .etFont(.body, sampleText: inputPlaceholderText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(viewModel.userInput)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .allowsHitTesting(false)
                .etFont(.body, sampleText: viewModel.userInput)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var pendingAttachmentPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress = viewModel.attachmentImportProgress {
                attachmentImportProgressRow(progress)
            }

            if !viewModel.pendingImageAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(viewModel.pendingImageAttachments) { attachment in
                            attachmentPreviewRow(
                                systemImage: "photo",
                                title: NSLocalizedString("图片文件", comment: ""),
                                fileName: attachment.fileName,
                                tint: .green,
                                onRemove: {
                                    viewModel.removePendingImageAttachment(attachment)
                                }
                            )
                            .frame(width: 140, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            if let audio = viewModel.pendingAudioAttachment {
                attachmentPreviewRow(
                    systemImage: "waveform",
                    title: NSLocalizedString("语音文件", comment: ""),
                    fileName: audio.fileName,
                    tint: .blue,
                    onRemove: {
                        viewModel.clearPendingAudioAttachment()
                    }
                )
            }

            ForEach(viewModel.pendingFileAttachments) { attachment in
                attachmentPreviewRow(
                    systemImage: "doc",
                    title: NSLocalizedString("文件", comment: ""),
                    fileName: attachment.fileName,
                    tint: .cyan,
                    onRemove: {
                        viewModel.removePendingFileAttachment(attachment)
                    }
                )
            }
        }
    }

    private func attachmentPreviewRow(
        systemImage: String,
        title: String,
        fileName: String,
        tint: Color,
        onRemove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .etFont(.system(size: 12))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .etFont(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(fileName)
                    .etFont(.system(size: 10))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .etFont(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(white: 0.2))
        .cornerRadius(8)
    }

    private func attachmentImportProgressRow(_ progress: WatchAttachmentImportProgress) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                    .etFont(.system(size: 12))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 1) {
                    Text(NSLocalizedString("正在下载附件", comment: "Watch attachment import progress title"))
                        .etFont(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(progress.sourceName)
                        .etFont(.system(size: 10))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }

                Spacer()

                if progress.isDeterminate {
                    Text(String(format: "%.0f%%", progress.fractionCompleted * 100))
                        .etFont(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.blue)
                } else {
                    ProgressView()
                }
            }

            if progress.isDeterminate {
                ProgressView(value: progress.fractionCompleted)
                    .progressViewStyle(.linear)
                Text(
                    String(
                        format: NSLocalizedString("已下载 %@ / %@", comment: "Watch attachment import downloaded bytes"),
                        StorageUtility.formatSize(progress.bytesReceived),
                        StorageUtility.formatSize(progress.totalBytes)
                    )
                )
                .etFont(.system(size: 9))
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(white: 0.2))
        .cornerRadius(8)
    }

    var body: some View {
        let hasTrimmedText = !viewModel.userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canSend = hasTrimmedText || hasPendingAttachments
        let inputActionState = WatchChatInputActionState.resolve(
            isSending: viewModel.isSendingMessage,
            hasSendableContent: canSend,
            canQuickRetry: viewModel.canQuickRetryLatestMessage,
            isSpeechInputEnabled: viewModel.enableSpeechInput
        )

        let coreBubble = Group {
            VStack(spacing: 6) {
                if hasPendingAttachments || hasAttachmentImportProgress {
                    pendingAttachmentPreview
                }

                if isLiquidGlassEnabled {
                    HStack(spacing: 10) {
                        if #available(watchOS 26.0, *) {
                            transparentInputField
                                .glassEffect(.clear, in: Capsule())

                            Button {
                                onHandleInputAction(inputActionState)
                            } label: {
                                Image(systemName: inputActionState.systemImageName)
                                    .etFont(.system(size: 18, weight: .medium))
                                    .frame(width: inputControlHeight, height: inputControlHeight)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.clear, in: Circle())
                            .disabled(inputActionState.isDisabled || viewModel.attachmentImportInProgress)
                        } else {
                            ZStack {
                                Capsule()
                                    .fill(inputFillColor)
                                    .overlay(
                                        Capsule()
                                            .stroke(inputStrokeColor, lineWidth: 0.6)
                                    )
                                transparentInputField
                            }

                            Button {
                                onHandleInputAction(inputActionState)
                            } label: {
                                Image(systemName: inputActionState.systemImageName)
                                    .etFont(.system(size: 18, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .frame(width: inputControlHeight, height: inputControlHeight)
                            .overlay(
                                Circle()
                                    .stroke(inputStrokeColor, lineWidth: 0.8)
                            )
                            .disabled(inputActionState.isDisabled || viewModel.attachmentImportInProgress)
                        }
                    }
                    .frame(height: inputControlHeight)
                } else {
                    HStack(spacing: 12) {
                        ZStack {
                            Capsule()
                                .fill(inputFillColor)
                                .overlay(
                                    Capsule()
                                        .stroke(inputStrokeColor, lineWidth: 0.6)
                                )
                            transparentInputField
                        }

                        Button {
                            onHandleInputAction(inputActionState)
                        } label: {
                            Image(systemName: inputActionState.systemImageName)
                                .etFont(.system(size: 18, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .frame(width: inputControlHeight, height: inputControlHeight)
                        .background(
                            Circle().fill(inputFillColor)
                        )
                        .overlay(
                            Circle()
                                .stroke(inputStrokeColor, lineWidth: 0.8)
                        )
                        .disabled(inputActionState.isDisabled || viewModel.attachmentImportInProgress)
                    }
                    .frame(height: inputControlHeight)
                    .padding(.horizontal, 10)
                    .background(viewModel.enableBackground ? AnyShapeStyle(.clear) : AnyShapeStyle(.ultraThinMaterial))
                    .cornerRadius(12)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, inputBubbleVerticalPadding)

        return coreBubble
            .onLongPressGesture(minimumDuration: 0.5) {
                if let model = viewModel.selectedModel,
                   !model.model.requestBodyControls.filter(\.isEnabled).isEmpty {
                    isRequestControlsPresented = true
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    attachmentSourceText = importSourceHistory.first ?? lastAttachmentSource
                    isAttachmentImportPresented = true
                } label: {
                    Image(systemName: "plus")
                        .etFont(.system(size: 16, weight: .semibold))
                        .frame(width: inputControlHeight, height: inputControlHeight)
                        .contentShape(Circle())
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel(NSLocalizedString("添加附件", comment: ""))
                .tint(.blue)
                .disabled(viewModel.attachmentImportInProgress)

                if !viewModel.userInput.isEmpty || hasPendingAttachments {
                    Button(role: .destructive) {
                        viewModel.clearUserInput()
                        viewModel.clearAllAttachments()
                    } label: {
                        Image(systemName: "trash")
                            .etFont(.system(size: 16, weight: .semibold))
                            .frame(width: inputControlHeight, height: inputControlHeight)
                            .contentShape(Circle())
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel(NSLocalizedString("清空输入", comment: ""))
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if let selectedModel = viewModel.selectedModel,
                   !selectedModel.model.requestBodyControls.filter(\.isEnabled).isEmpty {
                    Button {
                        isRequestControlsPresented = true
                    } label: {
                        Image(systemName: "slider.vertical.3")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: inputControlHeight, height: inputControlHeight)
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel(NSLocalizedString("请求控制", comment: ""))
                    .tint(.purple)
                }
                Button {
                    onOpenSessionHistory()
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: inputControlHeight, height: inputControlHeight)
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel(NSLocalizedString("历史会话", comment: ""))
                .tint(.blue)
            }
            .sheet(isPresented: $isRequestControlsPresented) {
                if let selectedModel = viewModel.selectedModel {
                    NavigationStack {
                        WatchQuickRequestControlsView(runnableModel: selectedModel)
                    }
                }
            }
            .sheet(isPresented: $isAttachmentImportPresented) {
                NavigationStack {
                    WatchImportSourceView(
                        source: $attachmentSourceText,
                        history: importSourceHistory,
                        isImporting: viewModel.attachmentImportInProgress,
                        title: NSLocalizedString("添加附件", comment: ""),
                        placeholder: NSLocalizedString("链接或文件路径", comment: ""),
                        progressTitle: NSLocalizedString("正在导入...", comment: ""),
                        confirmTitle: NSLocalizedString("导入", comment: ""),
                        onImport: {
                            let trimmedSource = attachmentSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
                            onRememberAttachmentSource(trimmedSource)
                            viewModel.importAttachment(from: trimmedSource)
                            isAttachmentImportPresented = false
                        },
                        onCancel: {
                            isAttachmentImportPresented = false
                        }
                    )
                }
            }
            .sheet(isPresented: Binding(
                get: { viewModel.isSpeechRecorderPresented },
                set: { viewModel.isSpeechRecorderPresented = $0 }
            )) {
                SpeechRecorderView(viewModel: viewModel)
            }
            .alert(NSLocalizedString("语音输入错误", comment: ""), isPresented: Binding(
                get: { viewModel.showSpeechErrorAlert },
                set: { viewModel.showSpeechErrorAlert = $0 }
            )) {
                Button(NSLocalizedString("好的", comment: ""), role: .cancel) { }
            } message: {
                Text(viewModel.speechErrorMessage ?? NSLocalizedString("发生未知错误，请稍后重试。", comment: ""))
            }
            .alert(NSLocalizedString("附件导入失败", comment: ""), isPresented: $viewModel.showAttachmentImportErrorAlert) {
                Button(NSLocalizedString("好的", comment: ""), role: .cancel) { }
            } message: {
                Text(viewModel.attachmentImportErrorMessage ?? NSLocalizedString("附件导入失败，请稍后重试。", comment: ""))
            }
            .alert(NSLocalizedString("记忆系统需要更新", comment: ""), isPresented: $viewModel.showDimensionMismatchAlert) {
                Button(NSLocalizedString("好的", comment: ""), role: .cancel) { }
            } message: {
                Text(viewModel.dimensionMismatchMessage)
            }
            .alert(
                Text(NSLocalizedString("记忆嵌入失败", comment: "Memory embedding failure alert title")),
                isPresented: $viewModel.showMemoryEmbeddingErrorAlert
            ) {
                Button(NSLocalizedString("好的", comment: "OK"), role: .cancel) { }
            } message: {
                Text(viewModel.memoryEmbeddingErrorMessage)
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
}
