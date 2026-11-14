import SwiftUI

/// 各平台保留自己的文本样式和滚动容器，共享后台分页与单页布局边界。
@MainActor
public struct ETPagedTextContent<Content: View, ExportContent: View>: View {
    private let source: ChatTextPaginationSource
    private let content: (ChatTextPagination.Page) -> Content
    private let exportContent: () -> ExportContent
    @Environment(\.etFontExportPreparation) private var exportPreparation
    @StateObject private var model = ChatTextPaginationModel()

    public init(text: String, @ViewBuilder content: @escaping (String) -> Content,
                @ViewBuilder exportContent: @escaping () -> ExportContent) {
        self.source = .plain(text)
        self.content = { content($0.text) }
        self.exportContent = exportContent
    }

    public init(attributedText: AttributedString, @ViewBuilder content: @escaping (AttributedString) -> Content,
                @ViewBuilder exportContent: @escaping () -> ExportContent) {
        self.source = .attributed(attributedText)
        self.content = { content($0.attributedText) }
        self.exportContent = exportContent
    }

    public var body: some View {
        Group {
            if exportPreparation != nil {
                // 离屏导出不运行 task，也没有翻页交互，必须保留原有的完整内容。
                exportContent()
            } else {
                paginatedContent
            }
        }
    }

    private var paginatedContent: some View {
        VStack(alignment: .leading) {
            if let page = model.currentPage {
                content(page)
                    // 翻页后重新测量当前页并回到页首，不能沿用上一页的滚动偏移。
                    .id(model.selectedPageIndex)

                if model.pageCount > 1 {
                    HStack {
                        Button {
                            model.selectPage(model.selectedPageIndex - 1)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(model.selectedPageIndex == 0)
                        .accessibilityLabel(NSLocalizedString("上一页", value: "Previous page", comment: ""))

                        Text(String(format: NSLocalizedString("第 %d / %d 页", value: "Page %d / %d", comment: ""),
                                    model.selectedPageIndex + 1, model.pageCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)

                        Button {
                            model.selectPage(model.selectedPageIndex + 1)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(model.selectedPageIndex + 1 == model.pageCount)
                        .accessibilityLabel(NSLocalizedString("下一页", value: "Next page", comment: ""))
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                // 首帧也不能回退为全文 Text，否则系统快照仍可能触发完整排版。
                ProgressView()
                    .accessibilityLabel(NSLocalizedString("正在加载", value: "Loading", comment: ""))
            }
        }
        .task(id: source) {
            await model.prepare(source: source)
        }
    }
}

public extension ETPagedTextContent where ExportContent == Content {
    init(text: String, @ViewBuilder content: @escaping (String) -> Content) {
        self.init(text: text, content: content, exportContent: { content(text) })
    }

    init(attributedText: AttributedString, @ViewBuilder content: @escaping (AttributedString) -> Content) {
        self.init(attributedText: attributedText, content: content, exportContent: { content(attributedText) })
    }
}
