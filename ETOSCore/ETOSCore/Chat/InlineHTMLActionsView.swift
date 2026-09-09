import SwiftUI
#if os(iOS)
import UIKit
#endif

/// 平台只负责提供网页预览与复制目的地，四种操作共用同一份页面内容。
public struct InlineHTMLActionsView<Preview: View>: View {
    private let content: InlineHTMLContent
    private let onCopy: ((String) -> Void)?
    private let preview: Preview
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var copied = false
    @State private var exportURL: URL?
    @State private var showsCode = false

    public init(content: InlineHTMLContent, onCopy: ((String) -> Void)? = nil, @ViewBuilder preview: () -> Preview) {
        self.content = content
        self.onCopy = onCopy
        self.preview = preview()
    }

    public var body: some View {
        Form {
            preview
            Section {
                Button {
                    perform {
                        guard let capture = content.capturePNG else { throw InlineHTMLExportError.notReady }
                        let data = try await capture()
                        try await export(data: data, fileExtension: "png")
                    }
                } label: {
                    Label(NSLocalizedString("下载当前渲染 PNG", comment: ""), systemImage: "photo")
                }
                Button {
                    copy(content.code)
                } label: {
                    Label(NSLocalizedString("复制代码", comment: ""), systemImage: "doc.on.doc")
                }
                Button {
                    perform {
                        let html = content.html
                        let data = await Task.detached(priority: .userInitiated) { Data(html.utf8) }.value
                        try await export(data: data, fileExtension: "html")
                    }
                } label: {
                    Label(NSLocalizedString("下载 HTML", comment: ""), systemImage: "square.and.arrow.down")
                }
                Button {
                    perform {
                        guard let readText = content.readText else { throw InlineHTMLExportError.notReady }
                        copy(try await readText())
                    }
                } label: {
                    Label(NSLocalizedString("复制页面纯文本", comment: ""), systemImage: "text.alignleft")
                }
            } footer: {
                Text(NSLocalizedString("PNG 保存当前画面；HTML 保留代码与样式，外部资源仍需联网，App 内的工具交互无法在外部运行。", comment: ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .disabled(isWorking)

            if isWorking { ProgressView() }
            if copied {
                Text(NSLocalizedString("已复制", comment: ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let exportURL {
                Section {
                    ShareLink(item: exportURL) {
                        Label(NSLocalizedString("保存或分享文件", comment: ""), systemImage: "square.and.arrow.up")
                    }
                }
            }
            Section {
                #if os(watchOS)
                Button(NSLocalizedString("代码", comment: "")) { showsCode.toggle() }
                    .buttonStyle(.plain)
                if showsCode {
                    Text(content.code)
                        .font(.footnote.monospaced())
                }
                #else
                DisclosureGroup(NSLocalizedString("代码", comment: "")) {
                    Text(content.code)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
                #endif
            }
            #if os(watchOS)
            Section {
                Text(NSLocalizedString("手表上的复制会将内容填入聊天输入框。", comment: ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            #endif
        }
        .navigationTitle(NSLocalizedString("内联内容", comment: ""))
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "inline-html-\(content.id)"),
            title: NSLocalizedString("内联内容", comment: ""),
            documents: [GuideDocumentReference(id: "inline-html-actions", title: NSLocalizedString("内联内容", comment: ""))],
            settings: [
                .readOnly("working", label: NSLocalizedString("导出", comment: ""), value: { .bool(isWorking) }),
                .readOnly("file_ready", label: NSLocalizedString("保存或分享文件", comment: ""), value: { .bool(exportURL != nil) })
            ]
        )
        .alert(NSLocalizedString("操作失败", comment: ""), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button(NSLocalizedString("确定", comment: ""), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        copied = false
        Task {
            defer { isWorking = false }
            do { try await operation() } catch { errorMessage = error.localizedDescription }
        }
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        onCopy?(text)
        #endif
        copied = true
    }

    private func export(data: Data, fileExtension: String) async throws {
        let url = try await Task.detached(priority: .userInitiated) {
            try InlineHTMLExportSupport.write(data: data, fileExtension: fileExtension)
        }.value
        exportURL = url
    }
}
