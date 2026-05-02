// ============================================================================
// ChatView+AskInputAndComposerViews.swift
// ============================================================================
// iOS 聊天页的问答输入面板、消息输入栏与附件导入视图。
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
struct AskUserInputComposerPanel: View {
    let request: AppToolAskUserInputRequest
    let submitAction: ([AppToolAskUserInputQuestionAnswer]) -> Void
    let cancelAction: () -> Void

    @State var selectedOptionIDsByQuestion: [String: Set<String>] = [:]
    @State var otherTextByQuestion: [String: String] = [:]
    @State var currentQuestionIndex = 0
    @State var measuredQuestionContentHeight: CGFloat = 0

    var canSubmit: Bool {
        request.questions.allSatisfy { question in
            !question.required || isQuestionAnswered(question)
        }
    }

    var currentQuestion: AppToolAskUserInputQuestion? {
        guard request.questions.indices.contains(currentQuestionIndex) else { return nil }
        return request.questions[currentQuestionIndex]
    }

    var progressText: String {
        let total = max(request.questions.count, 1)
        let current = min(currentQuestionIndex + 1, total)
        return "\(current) / \(total)"
    }

    var questionContentMaxHeight: CGFloat {
        min(UIScreen.main.bounds.height * 0.42, 340)
    }

    var questionContentFrameHeight: CGFloat {
        let measured = measuredQuestionContentHeight
        guard measured > 1 else { return 180 }
        return min(max(measured + 4, 120), questionContentMaxHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            topBar

            if let question = currentQuestion {
                questionContent(for: question)
                navigationInputBar(for: question)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("暂无可填写问题", comment: ""))
                        .etFont(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 2)
        .onAppear {
            resetSelectionState()
        }
        .onChange(of: request) {
            resetSelectionState()
        }
        .onChange(of: currentQuestionIndex) {
            measuredQuestionContentHeight = 0
        }
    }

    var topBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Button(action: goToPreviousQuestion) {
                    Image(systemName: "chevron.left")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.bordered)
                .disabled(currentQuestionIndex == 0)
                .opacity(currentQuestionIndex == 0 ? 0.45 : 1)

                Spacer(minLength: 6)

                HStack(spacing: 8) {
                    Text(progressText)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                    Button(NSLocalizedString("取消", comment: ""), action: cancelAction)
                        .etFont(.footnote)
                        .buttonStyle(.bordered)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(request.title ?? NSLocalizedString("请补充信息", comment: ""))
                    .etFont(.headline)
                if let description = request.description, !description.isEmpty {
                    Text(description)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
            .padding(.leading, 2)
        }
    }

    func questionContent(for question: AppToolAskUserInputQuestion) -> some View {
        ScrollView {
            questionBlock(question)
                .padding(.vertical, 2)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: AskUserInputQuestionContentHeightPreferenceKey.self,
                            value: geometry.size.height
                        )
                    }
                )
        }
        .frame(height: questionContentFrameHeight, alignment: .top)
        .onPreferenceChange(AskUserInputQuestionContentHeightPreferenceKey.self) { newHeight in
            measuredQuestionContentHeight = newHeight
        }
    }

    @ViewBuilder
    func questionBlock(_ question: AppToolAskUserInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(question.question)
                    .etFont(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if question.required {
                    Text("*")
                        .foregroundStyle(.red)
                        .etFont(.subheadline.weight(.bold))
                }
            }

            ForEach(question.options) { option in
                Button {
                    toggleOption(question: question, optionID: option.id)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: optionIconName(question: question, optionID: option.id))
                            .foregroundStyle(.blue)
                            .frame(width: 20, alignment: .center)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                                .etFont(.subheadline)
                                .foregroundStyle(.primary)
                            if let description = option.description, !description.isEmpty {
                                Text(description)
                                    .etFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .disabled(
                    !AppToolAskUserInputAnswerPolicy.canSelectOption(
                        type: question.type,
                        customText: otherTextByQuestion[question.id]
                    )
                )
            }
        }
        .padding(.vertical, 2)
    }

    func navigationInputBar(for question: AppToolAskUserInputQuestion) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .foregroundStyle(.secondary)

            TextField(NSLocalizedString("请输入自定义偏好", comment: ""),
                text: Binding(
                    get: { otherTextByQuestion[question.id, default: ""] },
                    set: { newValue in
                        otherTextByQuestion[question.id] = newValue
                        if AppToolAskUserInputAnswerPolicy.shouldClearSelectedOptionsAfterTypingCustomText(
                            type: question.type,
                            customText: newValue
                        ) {
                            selectedOptionIDsByQuestion[question.id] = []
                        }
                    }
                ),
                axis: .vertical
            )
            .lineLimit(1...3)
            .textFieldStyle(.plain)

            Button(skipButtonTitle(for: question)) {
                handleSkipOrSubmit(for: question)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canContinue(from: question))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
    }

    func optionIconName(question: AppToolAskUserInputQuestion, optionID: String) -> String {
        let isSelected = selectedOptionIDsByQuestion[question.id, default: []].contains(optionID)
        switch question.type {
        case .singleSelect:
            return isSelected ? "largecircle.fill.circle" : "circle"
        case .multiSelect:
            return isSelected ? "checkmark.square.fill" : "square"
        }
    }

    func toggleOption(question: AppToolAskUserInputQuestion, optionID: String) {
        guard AppToolAskUserInputAnswerPolicy.canSelectOption(
            type: question.type,
            customText: otherTextByQuestion[question.id]
        ) else {
            return
        }
        switch question.type {
        case .singleSelect:
            let current = selectedOptionIDsByQuestion[question.id, default: []]
            if current.contains(optionID) {
                selectedOptionIDsByQuestion[question.id] = []
            } else {
                selectedOptionIDsByQuestion[question.id] = [optionID]
                autoAdvanceIfNeeded(afterSelecting: question)
            }
        case .multiSelect:
            var current = selectedOptionIDsByQuestion[question.id, default: []]
            if current.contains(optionID) {
                current.remove(optionID)
            } else {
                current.insert(optionID)
            }
            selectedOptionIDsByQuestion[question.id] = current
        }
    }

    func autoAdvanceIfNeeded(afterSelecting question: AppToolAskUserInputQuestion) {
        guard question.type == .singleSelect else { return }
        if isLastQuestion(question) {
            if canSubmit {
                submit()
            }
            return
        }
        guard canContinue(from: question) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            currentQuestionIndex = min(currentQuestionIndex + 1, request.questions.count - 1)
        }
    }

    func goToPreviousQuestion() {
        guard currentQuestionIndex > 0 else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            currentQuestionIndex -= 1
        }
    }

    func handleSkipOrSubmit(for question: AppToolAskUserInputQuestion) {
        guard canContinue(from: question) else { return }
        if isLastQuestion(question) {
            submit()
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            currentQuestionIndex = min(currentQuestionIndex + 1, request.questions.count - 1)
        }
    }

    func isQuestionAnswered(_ question: AppToolAskUserInputQuestion) -> Bool {
        let selected = selectedOptionIDsByQuestion[question.id] ?? []
        return AppToolAskUserInputAnswerPolicy.hasAnswer(
            selectedOptionIDs: selected,
            customText: otherTextByQuestion[question.id]
        )
    }

    func canContinue(from question: AppToolAskUserInputQuestion) -> Bool {
        if isLastQuestion(question) {
            return canSubmit
        }
        return true
    }

    func isLastQuestion(_ question: AppToolAskUserInputQuestion) -> Bool {
        request.questions.last?.id == question.id
    }

    func skipButtonTitle(for question: AppToolAskUserInputQuestion) -> String {
        if isLastQuestion(question) {
            return request.submitLabel
        }
        return isQuestionAnswered(question) ? NSLocalizedString("下一题", comment: "") : NSLocalizedString("跳过", comment: "")
    }

    func submit() {
        let answers = request.questions.map { question -> AppToolAskUserInputQuestionAnswer in
            let selectedIDs = question.options
                .map(\.id)
                .filter { selectedOptionIDsByQuestion[question.id, default: []].contains($0) }
            let selectedLabels = question.options
                .filter { selectedOptionIDsByQuestion[question.id, default: []].contains($0.id) }
                .map(\.label)
            let otherText = AppToolAskUserInputAnswerPolicy.normalizedCustomText(
                otherTextByQuestion[question.id]
            )

            return AppToolAskUserInputQuestionAnswer(
                questionID: question.id,
                question: question.question,
                type: question.type,
                selectedOptionIDs: selectedIDs,
                selectedOptionLabels: selectedLabels,
                otherText: otherText
            )
        }
        submitAction(answers)
    }

    func resetSelectionState() {
        selectedOptionIDsByQuestion = [:]
        otherTextByQuestion = [:]
        currentQuestionIndex = 0
        measuredQuestionContentHeight = 0
    }
}


// MARK: - Legacy Composer (kept for compatibility)

struct MessageComposerView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Binding var text: String
    let isSending: Bool
    let sendAction: () -> Void
    let focus: FocusState<Bool>.Binding
    
    @State var showAttachmentMenu = false
    @State var showImagePicker = false
    @State var showAudioRecorder = false
    @State var audioRecorderSheetDetent: PresentationDetent = .fraction(0.5)
    @State var audioRecorderEntryMode: AudioRecorderEntryMode = .attachment
    @State var showFileImporter = false
    @State var selectedPhotos: [PhotosPickerItem] = []
    
    var body: some View {
        VStack(spacing: 8) {
            // 附件预览区域
            if !viewModel.pendingImageAttachments.isEmpty || viewModel.pendingAudioAttachment != nil || !viewModel.pendingFileAttachments.isEmpty {
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
                
                // 输入框（拉长的药丸型）
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
                
                // 发送箭头（圆形）
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
    
    @ViewBuilder
    var attachmentPreviewBar: some View {
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
                                .etFont(.system(size: 18))
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .offset(x: 4, y: -4)
                    }
                }
                
                // 音频预览
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

                // 文件预览
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
            .padding(.horizontal)
            .padding(.vertical, 8)
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

    // file MIME type helper lives at file scope (resolvedFileMimeType)
}
