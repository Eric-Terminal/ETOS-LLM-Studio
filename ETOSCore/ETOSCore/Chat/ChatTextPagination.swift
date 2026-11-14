import Combine
import Foundation

/// 限制一次原生文本布局的输入量；只切分显示内容，不改写消息或工具结果。
public struct ChatTextPagination: Sendable {
    public static let maximumCharactersPerPage = 3_000
    public static let maximumLineBreaksPerPage = 80

    public struct Page: Sendable {
        public let text: String
        public let attributedText: AttributedString
    }

    public let pages: [Page]
    let sourceText: String

    /// 字符遍历与分配必须在后台进行，换行密集的输出也不能只依赖字符上限。
    public init(text: String) throws {
        self.sourceText = text
        var pages: [String] = []
        var start = text.startIndex
        var cursor = start
        var characters = 0
        var lineBreaks = 0
        try Task.checkCancellation()

        while cursor < text.endIndex {
            let character = text[cursor]
            characters += 1
            if character.isNewline { lineBreaks += 1 }
            text.formIndex(after: &cursor)

            if characters == Self.maximumCharactersPerPage
                || lineBreaks == Self.maximumLineBreaksPerPage {
                try Task.checkCancellation()
                pages.append(String(text[start..<cursor]))
                start = cursor
                characters = 0
                lineBreaks = 0
            }
        }

        try Task.checkCancellation()
        if start < text.endIndex { pages.append(String(text[start...])) }
        self.pages = (pages.isEmpty ? [""] : pages).map {
            Page(text: $0, attributedText: AttributedString($0))
        }
    }

    /// macOS 的工具结果已经带有用户字体和颜色规则，切页时保留原始属性范围。
    public init(attributedText: AttributedString) throws {
        let plain = try Self(text: String(attributedText.characters))
        self.sourceText = plain.sourceText
        var cursor = attributedText.startIndex
        var pages: [Page] = []
        for page in plain.pages {
            try Task.checkCancellation()
            let end = attributedText.characters.index(cursor, offsetBy: page.text.count)
            pages.append(Page(text: page.text, attributedText: AttributedString(attributedText[cursor..<end])))
            cursor = end
        }
        self.pages = pages
    }
}

enum ChatTextPaginationSource: Equatable, Sendable {
    case plain(String)
    case attributed(AttributedString)
}

@MainActor
public final class ChatTextPaginationModel: ObservableObject {
    @Published public private(set) var pagination: ChatTextPagination?
    @Published public private(set) var selectedPageIndex = 0
    private var preparedSource: String?
    private var preparationID = UUID()

    public init() {}

    public var currentPage: ChatTextPagination.Page? {
        pagination?.pages[selectedPageIndex]
    }

    public var pageCount: Int { pagination?.pages.count ?? 0 }

    public func selectPage(_ index: Int) {
        guard index >= 0, index < pageCount else { return }
        selectedPageIndex = index
    }

    public func prepare(text: String) async {
        await prepare(source: .plain(text))
    }

    public func prepare(attributedText: AttributedString) async {
        await prepare(source: .attributed(attributedText))
    }

    func prepare(source: ChatTextPaginationSource) async {
        guard !Task.isCancelled else { return }
        let requestID = UUID()
        preparationID = requestID

        let previousSource = preparedSource
        let worker = Task.detached(priority: .userInitiated) {
            let pagination: ChatTextPagination
            switch source {
            case .plain(let value):
                pagination = try ChatTextPagination(text: value)
            case .attributed(let value):
                pagination = try ChatTextPagination(attributedText: value)
            }
            let isAppend = previousSource.map { pagination.sourceText.hasPrefix($0) } ?? false
            return (pagination: pagination, isAppend: isAppend)
        }
        let prepared = try? await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        // 结果更新、消息切换或视图消失后，旧任务不能重新发布过期的文本。
        guard !Task.isCancelled, preparationID == requestID, let prepared else { return }
        // 流式增长时保留当前页和已显示的内容，避免每个 token 都先清空再触发一次布局。
        selectedPageIndex = prepared.isAppend ? min(selectedPageIndex, prepared.pagination.pages.count - 1) : 0
        preparedSource = prepared.pagination.sourceText
        pagination = prepared.pagination
    }
}
