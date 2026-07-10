// ============================================================================
// ChatExportFormatsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 会话导出格式选择视图
// - 支持导出 PDF / Markdown / TXT / PNG 聊天长图
// - 支持完整会话、“截至指定消息”与任意多选消息导出
// ============================================================================

import SwiftUI
import Foundation
import WatchKit
import ETOSCore

struct ChatExportFormatsView: View {
    let session: ChatSession?
    let messages: [ChatMessage]
    let upToMessageID: UUID?
    var selectedMessageIDs: Set<UUID>? = nil

    @State private var fileURLs: [ChatTranscriptExportFormat: URL] = [:]
    @State private var suggestedFileNames: [ChatTranscriptExportFormat: String] = [:]
    @State private var formatErrors: [ChatTranscriptExportFormat: String] = [:]
    @State private var prepareError: String?
    @State private var includeReasoning: Bool = true
    @State private var includeSystemPrompt: Bool = true
    @State private var uploadURLText: String = ""
    @State private var uploadingFormat: ChatTranscriptExportFormat?
    @State private var uploadProgress: SyncPackageUploadProgress?
    @State private var uploadMessage: String?
    @State private var uploadError: String?
    @State private var prepareTask: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var appConfig = AppConfigStore.shared

    var body: some View {
        List {
            Section {
                Text(scopeDescription)
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(NSLocalizedString("思考内容", comment: ""), selection: $includeReasoning) {
                    Text(NSLocalizedString("包含思考", comment: "")).tag(true)
                    Text(NSLocalizedString("不包含思考", comment: "")).tag(false)
                }
                Toggle(NSLocalizedString("包含系统提示词", comment: ""), isOn: $includeSystemPrompt)
            } header: {
                Text(NSLocalizedString("导出范围", comment: ""))
            } footer: {
                Text(NSLocalizedString("PNG 仅导出聊天界面可见内容，不会包含系统提示词。", comment: "Chat image export system prompt privacy note"))
            }

            Section(NSLocalizedString("上传到地址", comment: "")) {
                TextField(NSLocalizedString("上传到地址", comment: ""), text: $uploadURLText.watchKeyboardNewlineBinding())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if let uploadMessage, !uploadMessage.isEmpty {
                    Text(uploadMessage)
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                }

                if let uploadError, !uploadError.isEmpty {
                    Text(uploadError)
                        .etFont(.caption)
                        .foregroundStyle(.red)
                }
            }

            ForEach(ChatTranscriptExportFormat.allCases, id: \.self) { format in
                Section(format.displayName) {
                    if let url = fileURLs[format] {
                        if uploadingFormat == format {
                            ChatExportUploadProgressView(progress: uploadProgress)
                        } else {
                            Button {
                                upload(format: format, fileURL: url)
                            } label: {
                                Label(NSLocalizedString("上传到地址", comment: ""), systemImage: iconName(for: format))
                            }
                            .disabled(uploadingFormat != nil)
                        }
                    } else if let formatError = formatErrors[format] {
                        Text(formatError)
                            .etFont(.caption)
                            .foregroundStyle(.red)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.mini)
                            Text(String(format: NSLocalizedString("正在生成 %@ 文件…", comment: ""), format.displayName))
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let prepareError, !prepareError.isEmpty {
                Section(NSLocalizedString("导出错误", comment: "")) {
                    Text(prepareError)
                        .etFont(.caption)
                        .foregroundStyle(.red)

                    Button(NSLocalizedString("重新生成", comment: "")) {
                        prepareFiles()
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("导出", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            prepareFiles()
        }
        .onChange(of: includeReasoning) { _, _ in
            prepareFiles()
        }
        .onChange(of: includeSystemPrompt) { _, _ in
            prepareFiles()
        }
        .onDisappear {
            prepareTask?.cancel()
            prepareTask = nil
        }
    }

    private var scopeDescription: String {
        let visibleMessages = ChatResponseAttemptSupport.visibleMessages(from: messages)
        let count: Int
        if let selectedMessageIDs {
            count = selectedMessageIDs.count
        } else if let upToMessageID,
                  let index = visibleMessages.firstIndex(where: { $0.id == upToMessageID }) {
            count = index + 1
        } else {
            count = visibleMessages.count
        }
        if selectedMessageIDs != nil {
            return String(format: NSLocalizedString("将导出所选的 %d 条消息。", comment: "Selected messages export description"), count)
        }
        if upToMessageID != nil {
            return String(format: NSLocalizedString("将导出前 %d 条消息（包含目标消息与其上文）。", comment: ""), count)
        }
        return String(format: NSLocalizedString("将导出当前会话全部 %d 条消息。", comment: ""), count)
    }

    private func prepareFiles() {
        prepareTask?.cancel()
        fileURLs = [:]
        suggestedFileNames = [:]
        formatErrors = [:]
        prepareError = nil

        let session = session
        let messages = messages
        let includeReasoning = includeReasoning
        let includeSystemPrompt = includeSystemPrompt
        let upToMessageID = upToMessageID
        let selectedMessageIDs = selectedMessageIDs
        let imageConfiguration = transcriptImageConfiguration
        let worker = Task.detached(priority: .userInitiated) {
            var nextURLs: [ChatTranscriptExportFormat: URL] = [:]
            var nextFileNames: [ChatTranscriptExportFormat: String] = [:]
            var nextErrors: [ChatTranscriptExportFormat: String] = [:]
            var preparedImageExport: ChatTranscriptPreparedImageExport?
            let exportService = ChatTranscriptExportService()
            let providers = ConfigLoader.loadProviders()
            let visibleMessages = ChatResponseAttemptSupport.visibleMessages(from: messages)

            for format in ChatTranscriptExportFormat.allCases {
                guard format != .png else { continue }
                try Task.checkCancellation()
                do {
                    let output = try exportService.export(
                        session: session,
                        messages: visibleMessages,
                        format: format,
                        includeReasoning: includeReasoning,
                        includeSystemPrompt: includeSystemPrompt,
                        upToMessageID: upToMessageID,
                        selectedMessageIDs: selectedMessageIDs
                    )
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(UUID().uuidString)-\(output.suggestedFileName)")
                    try output.data.write(to: url, options: .atomic)
                    nextURLs[format] = url
                    nextFileNames[format] = output.suggestedFileName
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    nextErrors[format] = error.localizedDescription
                }
            }

            do {
                preparedImageExport = try exportService.prepareImageExport(
                    session: session,
                    messages: messages,
                    includeReasoning: includeReasoning,
                    upToMessageID: upToMessageID,
                    selectedMessageIDs: selectedMessageIDs
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                nextErrors[.png] = error.localizedDescription
            }
            return PreparedChatExportFiles(
                fileURLs: nextURLs,
                suggestedFileNames: nextFileNames,
                formatErrors: nextErrors,
                preparedImageExport: preparedImageExport,
                providers: providers
            )
        }

        prepareTask = Task { @MainActor in
            do {
                var prepared = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()

                if let preparedImageExport = prepared.preparedImageExport {
                    do {
                        let output = try await WatchChatTranscriptImageRenderer.render(
                            preparedExport: preparedImageExport,
                            sourceMessages: messages,
                            includeReasoning: includeReasoning,
                            configuration: imageConfiguration,
                            providers: prepared.providers
                        )
                        let url = try await writeTemporaryExport(output)
                        prepared.fileURLs[.png] = url
                        prepared.suggestedFileNames[.png] = output.suggestedFileName
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        prepared.formatErrors[.png] = error.localizedDescription
                    }
                }

                fileURLs = prepared.fileURLs
                suggestedFileNames = prepared.suggestedFileNames
                formatErrors = prepared.formatErrors
                prepareError = ChatTranscriptExportFormat.allCases
                    .compactMap { prepared.formatErrors[$0] }
                    .first
                uploadMessage = nil
                uploadError = nil
            } catch is CancellationError {
                return
            } catch {
                fileURLs = [:]
                suggestedFileNames = [:]
                formatErrors = [:]
                prepareError = error.localizedDescription
            }
        }
    }

    private func writeTemporaryExport(_ output: ChatTranscriptExportOutput) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(output.suggestedFileName)")
            try output.data.write(to: url, options: .atomic)
            return url
        }.value
    }

    private func upload(format: ChatTranscriptExportFormat, fileURL: URL) {
        let trimmed = uploadURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            uploadError = NSLocalizedString("请先输入上传地址。", comment: "")
            uploadMessage = nil
            return
        }

        guard let endpoint = URL(string: trimmed),
              let scheme = endpoint.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            uploadError = NSLocalizedString("上传地址格式无效，请输入完整的 http/https URL。", comment: "")
            uploadMessage = nil
            return
        }

        uploadingFormat = format
        uploadProgress = SyncPackageUploadProgress(bytesSent: 0, totalBytes: fileSize(at: fileURL))
        uploadError = nil
        uploadMessage = nil

        Task {
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = NetworkSessionConfiguration.minimumRequestTimeout
                request.setValue(contentType(for: format), forHTTPHeaderField: "Content-Type")
                request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
                request.setValue(suggestedFileNames[format] ?? fileURL.lastPathComponent, forHTTPHeaderField: "X-ETOS-Export-FileName")
                request.setValue(format.fileExtension, forHTTPHeaderField: "X-ETOS-Export-Format")

                let delegate = ChatExportUploadProgressDelegate(
                    totalBytes: fileSize(at: fileURL),
                    progress: { progress in
                        Task { @MainActor in
                            uploadProgress = progress
                        }
                    }
                )
                let (data, response) = try await delegate.upload(request: request, fileURL: fileURL)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    let preview = String(data: data.prefix(300), encoding: .utf8) ?? ""
                    if preview.isEmpty {
                        uploadError = String(format: NSLocalizedString("上传失败：HTTP %d。", comment: ""), httpResponse.statusCode)
                    } else {
                        uploadError = String(format: NSLocalizedString("上传失败：HTTP %d，响应：%@", comment: ""), httpResponse.statusCode, preview)
                    }
                    uploadMessage = nil
                    uploadingFormat = nil
                    uploadProgress = nil
                    return
                }

                let completedBytes = fileSize(at: fileURL)
                uploadProgress = SyncPackageUploadProgress(bytesSent: completedBytes, totalBytes: completedBytes)
                uploadMessage = String(format: NSLocalizedString("上传成功（HTTP %d）", comment: ""), httpResponse.statusCode)
                uploadError = nil
            } catch {
                uploadMessage = nil
                uploadError = error.localizedDescription
                uploadProgress = nil
            }

            uploadingFormat = nil
        }
    }

    private func contentType(for format: ChatTranscriptExportFormat) -> String {
        switch format {
        case .pdf:
            return "application/pdf"
        case .markdown:
            return "text/markdown; charset=utf-8"
        case .text:
            return "text/plain; charset=utf-8"
        case .png:
            return "image/png"
        }
    }

    private func iconName(for format: ChatTranscriptExportFormat) -> String {
        switch format {
        case .pdf:
            return "doc.richtext"
        case .markdown:
            return "number.square"
        case .text:
            return "doc.plaintext"
        case .png:
            return "photo"
        }
    }

    private var transcriptImageConfiguration: WatchChatTranscriptImageConfiguration {
        let bounds = WKInterfaceDevice.current().screenBounds
        let currentBackground = appConfig.currentBackgroundImage
        let backgroundURL: URL?
        if appConfig.enableBackground,
           !currentBackground.isEmpty,
           !ConfigLoader.isVideoBackgroundFile(currentBackground) {
            backgroundURL = ConfigLoader.getBackgroundsDirectory()
                .appendingPathComponent(currentBackground)
        } else {
            backgroundURL = nil
        }

        let enableLiquidGlass: Bool
        if #available(watchOS 26.0, *) {
            enableLiquidGlass = appConfig.enableLiquidGlass
        } else {
            enableLiquidGlass = false
        }
        let fontScale = FontLibrary.effectiveFontScale(
            appConfig.fontCustomScale,
            isCustomFontEnabled: appConfig.fontUseCustomFonts
        )

        return WatchChatTranscriptImageConfiguration(
            title: session?.name ?? NSLocalizedString("新对话", comment: ""),
            inputPlaceholder: NSLocalizedString("输入...", comment: "Default input placeholder on watch"),
            prefersDarkAppearance: colorScheme == .dark,
            appLanguage: appConfig.appLanguage,
            backgroundImageURL: backgroundURL,
            backgroundOpacity: WatchBackgroundOpacitySetting.normalized(appConfig.backgroundOpacity),
            backgroundBlurRadius: max(0, appConfig.backgroundBlur),
            backgroundContentMode: appConfig.backgroundContentMode == "fit" ? .fit : .fill,
            enableBackground: appConfig.enableBackground,
            enableMarkdown: appConfig.enableMarkdown,
            enableLiquidGlass: enableLiquidGlass,
            enableNoBubbleUI: appConfig.enableNoBubbleUI,
            enableAdvancedRenderer: appConfig.enableAdvancedRenderer,
            enableSpeechInput: appConfig.enableSpeechInput,
            allowsMessageMerging: selectedMessageIDs == nil,
            inputControlHeight: max(38, 38 * CGFloat(fontScale)),
            canvasWidth: max(bounds.width, 1),
            backgroundTileHeight: max(bounds.height, 1),
            displayScale: max(WKInterfaceDevice.current().screenScale, 1)
        )
    }

    private func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}

private struct PreparedChatExportFiles: @unchecked Sendable {
    var fileURLs: [ChatTranscriptExportFormat: URL]
    var suggestedFileNames: [ChatTranscriptExportFormat: String]
    var formatErrors: [ChatTranscriptExportFormat: String]
    let preparedImageExport: ChatTranscriptPreparedImageExport?
    let providers: [Provider]
}

private struct ChatExportUploadProgressView: View {
    let progress: SyncPackageUploadProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(NSLocalizedString("上传进度", comment: ""))
                Spacer()
                if let progress, progress.totalBytes > 0 {
                    Text(String(format: "%d%%", progress.displayPercentage))
                        .monospacedDigit()
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .etFont(.caption)

            if let progress, progress.totalBytes > 0 {
                ProgressView(value: progress.fractionCompleted)
                    .progressViewStyle(.linear)
                Text(
                    String(
                        format: NSLocalizedString("已上传 %@ / %@", comment: ""),
                        StorageUtility.formatTransferSize(progress.bytesSent),
                        StorageUtility.formatTransferSize(progress.totalBytes)
                    )
                )
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private final class ChatExportUploadProgressDelegate: NSObject, URLSessionDataDelegate {
    private let totalBytes: Int64
    private let progress: @Sendable (SyncPackageUploadProgress) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var responseData = Data()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?

    init(totalBytes: Int64, progress: @escaping @Sendable (SyncPackageUploadProgress) -> Void) {
        self.totalBytes = totalBytes
        self.progress = progress
    }

    func upload(request: URLRequest, fileURL: URL) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            let session = URLSession(
                configuration: NetworkSessionConfiguration.makeConfiguration(),
                delegate: self,
                delegateQueue: nil
            )
            self.session = session
            lock.unlock()

            session.uploadTask(with: request, fromFile: fileURL).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let expectedBytes = totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : totalBytes
        progress(SyncPackageUploadProgress(bytesSent: totalBytesSent, totalBytes: expectedBytes))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }

        guard let response = task.response else {
            finish(.failure(URLError(.badServerResponse)))
            return
        }

        finish(.success((responseData, response)))
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()

        guard let continuation else { return }
        session?.finishTasksAndInvalidate()

        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
