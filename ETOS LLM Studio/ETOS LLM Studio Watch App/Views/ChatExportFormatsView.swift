// ============================================================================
// ChatExportFormatsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 会话导出格式选择视图
// - 支持导出 PDF / Markdown / TXT
// - 支持完整会话导出与“截至指定消息”导出
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct ChatExportFormatsView: View {
    let session: ChatSession?
    let messages: [ChatMessage]
    let upToMessageID: UUID?

    @State private var fileURLs: [ChatTranscriptExportFormat: URL] = [:]
    @State private var suggestedFileNames: [ChatTranscriptExportFormat: String] = [:]
    @State private var prepareError: String?
    @State private var includeReasoning: Bool = true
    @State private var uploadURLText: String = ""
    @State private var uploadingFormat: ChatTranscriptExportFormat?
    @State private var uploadMessage: String?
    @State private var uploadError: String?

    private let exportService = ChatTranscriptExportService()

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
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text(NSLocalizedString("上传进度", comment: ""))
                                    .etFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Button {
                                upload(format: format, fileURL: url)
                            } label: {
                                Label(NSLocalizedString("上传到地址", comment: ""), systemImage: iconName(for: format))
                            }
                            .disabled(uploadingFormat != nil)
                        }
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
    }

    private var scopeDescription: String {
        let count: Int
        if let upToMessageID, let index = messages.firstIndex(where: { $0.id == upToMessageID }) {
            count = index + 1
        } else {
            count = messages.count
        }
        if upToMessageID != nil {
            return String(format: NSLocalizedString("将导出前 %d 条消息（包含目标消息与其上文）。", comment: ""), count)
        }
        return String(format: NSLocalizedString("将导出当前会话全部 %d 条消息。", comment: ""), count)
    }

    private func prepareFiles() {
        var nextURLs: [ChatTranscriptExportFormat: URL] = [:]
        var nextFileNames: [ChatTranscriptExportFormat: String] = [:]

        do {
            for format in ChatTranscriptExportFormat.allCases {
                let output = try exportService.export(
                    session: session,
                    messages: messages,
                    format: format,
                    includeReasoning: includeReasoning,
                    upToMessageID: upToMessageID
                )

                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString)-\(output.suggestedFileName)")
                try output.data.write(to: url, options: .atomic)
                nextURLs[format] = url
                nextFileNames[format] = output.suggestedFileName
            }

            fileURLs = nextURLs
            suggestedFileNames = nextFileNames
            prepareError = nil
            uploadMessage = nil
            uploadError = nil
        } catch {
            fileURLs = [:]
            suggestedFileNames = [:]
            prepareError = error.localizedDescription
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

                let (data, response) = try await NetworkSessionConfiguration.shared.upload(for: request, fromFile: fileURL)

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
                    return
                }

                uploadMessage = String(format: NSLocalizedString("上传成功（HTTP %d）", comment: ""), httpResponse.statusCode)
                uploadError = nil
            } catch {
                uploadMessage = nil
                uploadError = error.localizedDescription
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
        }
    }
}
