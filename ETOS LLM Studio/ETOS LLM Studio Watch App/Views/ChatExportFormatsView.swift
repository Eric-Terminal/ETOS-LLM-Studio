// ============================================================================
// ChatExportFormatsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 会话导出格式选择视图
// - 支持导出 PDF / Markdown / TXT / PNG 聊天长图
// - 支持完整会话、“截至指定消息”与任意多选消息导出
// ============================================================================

import SwiftUI
import Foundation
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
    @State private var uploadURLText: String = ""
    @State private var uploadingFormat: ChatTranscriptExportFormat?
    @State private var uploadProgress: SyncPackageUploadProgress?
    @State private var uploadMessage: String?
    @State private var uploadError: String?
    @State private var prepareTask: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var appConfig = AppConfigStore.shared
    @ObservedObject private var appearanceProfileManager = ChatAppearanceProfileManager.shared

    var body: some View {
        List {
            Section {
                Text(scopeDescription)
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("导出范围", comment: "")) {
                Picker(NSLocalizedString("思考内容", comment: ""), selection: $includeReasoning) {
                    Text(NSLocalizedString("包含思考", comment: "")).tag(true)
                    Text(NSLocalizedString("不包含思考", comment: "")).tag(false)
                }
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
        .onDisappear {
            prepareTask?.cancel()
            prepareTask = nil
        }
    }

    private var scopeDescription: String {
        let count: Int
        if let selectedMessageIDs {
            count = selectedMessageIDs.count
        } else if let upToMessageID, let index = messages.firstIndex(where: { $0.id == upToMessageID }) {
            count = index + 1
        } else {
            count = messages.count
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
        let upToMessageID = upToMessageID
        let selectedMessageIDs = selectedMessageIDs
        let imageStyle = transcriptImageStyle
        let worker = Task.detached(priority: .userInitiated) {
            var nextURLs: [ChatTranscriptExportFormat: URL] = [:]
            var nextFileNames: [ChatTranscriptExportFormat: String] = [:]
            var nextErrors: [ChatTranscriptExportFormat: String] = [:]
            let exportService = ChatTranscriptExportService()

            for format in ChatTranscriptExportFormat.allCases {
                try Task.checkCancellation()
                do {
                    let output = try exportService.export(
                        session: session,
                        messages: messages,
                        format: format,
                        includeReasoning: includeReasoning,
                        upToMessageID: upToMessageID,
                        selectedMessageIDs: selectedMessageIDs,
                        imageStyle: imageStyle
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
            return PreparedChatExportFiles(
                fileURLs: nextURLs,
                suggestedFileNames: nextFileNames,
                formatErrors: nextErrors
            )
        }

        prepareTask = Task { @MainActor in
            do {
                let prepared = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
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

    private var transcriptImageStyle: ChatTranscriptImageStyle {
        let profile = appearanceProfileManager.activeProfile
        let isDark = colorScheme == .dark
        let userText = isDark ? profile.userDarkText : profile.userLightText
        let assistantText = isDark ? profile.assistantDarkText : profile.assistantLightText
        let backgroundURL: URL?
        if appConfig.enableBackground, !appConfig.currentBackgroundImage.isEmpty {
            backgroundURL = ConfigLoader.getBackgroundsDirectory()
                .appendingPathComponent(appConfig.currentBackgroundImage)
        } else {
            backgroundURL = nil
        }
        return ChatTranscriptImageStyle(
            prefersDarkAppearance: isDark,
            backgroundMediaURL: backgroundURL,
            backgroundOpacity: appConfig.backgroundOpacity,
            backgroundBlurRadius: appConfig.backgroundBlur,
            backgroundContentMode: appConfig.backgroundContentMode == "fit" ? .fit : .fill,
            usesCustomBackground: appConfig.enableBackground,
            userBubbleHex: profile.userBubble.isEnabled ? profile.userBubble.hex : nil,
            assistantBubbleHex: profile.assistantBubble.isEnabled ? profile.assistantBubble.hex : nil,
            userTextHex: userText.isEnabled ? userText.hex : nil,
            assistantTextHex: assistantText.isEnabled ? assistantText.hex : nil,
            usesNoBubbleStyle: appConfig.enableNoBubbleUI,
            inputPlaceholder: NSLocalizedString("Message", comment: "聊天长图输入框占位文本"),
            untitledConversationName: NSLocalizedString("新的对话", comment: "聊天长图未命名会话标题")
        )
    }

    private func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}

private struct PreparedChatExportFiles: Sendable {
    let fileURLs: [ChatTranscriptExportFormat: URL]
    let suggestedFileNames: [ChatTranscriptExportFormat: String]
    let formatErrors: [ChatTranscriptExportFormat: String]
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
