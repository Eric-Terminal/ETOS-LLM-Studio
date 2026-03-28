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
    @State private var prepareError: String?

    private let exportService = ChatTranscriptExportService()

    var body: some View {
        List {
            Section {
                Text(scopeDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(ChatTranscriptExportFormat.allCases, id: \.self) { format in
                Section(format.displayName) {
                    if let url = fileURLs[format] {
                        if #available(watchOS 9.0, *) {
                            ShareLink(item: url) {
                                Label("导出为\(format.displayName)", systemImage: iconName(for: format))
                            }
                        } else {
                            Text("当前系统暂不支持直接分享导出文件。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("正在生成 \(format.displayName) 文件…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let prepareError, !prepareError.isEmpty {
                Section("导出错误") {
                    Text(prepareError)
                        .font(.caption)
                        .foregroundStyle(.red)

                    Button("重新生成") {
                        prepareFiles()
                    }
                }
            }
        }
        .navigationTitle("导出")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
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
            return "将导出前 \(count) 条消息（包含目标消息与其上文）。"
        }
        return "将导出当前会话全部 \(count) 条消息。"
    }

    private func prepareFiles() {
        var nextURLs: [ChatTranscriptExportFormat: URL] = [:]

        do {
            for format in ChatTranscriptExportFormat.allCases {
                let output = try exportService.export(
                    session: session,
                    messages: messages,
                    format: format,
                    upToMessageID: upToMessageID
                )

                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString)-\(output.suggestedFileName)")
                try output.data.write(to: url, options: .atomic)
                nextURLs[format] = url
            }

            fileURLs = nextURLs
            prepareError = nil
        } catch {
            fileURLs = [:]
            prepareError = error.localizedDescription
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
