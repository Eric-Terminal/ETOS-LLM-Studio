import Combine
import SwiftUI

/// nil 明确表示系统字体，不能让 Markdown 的粗体、斜体继续继承正文家族。
public struct ETMarkdownFontNames: Equatable, Sendable {
    public let body: String?
    public let emphasis: String?
    public let strong: String?
    public let code: String?

    static var current: Self {
        Self(
            body: FontLibrary.resolvedPostScriptName(for: .body),
            emphasis: FontLibrary.resolvedPostScriptName(for: .emphasis),
            strong: FontLibrary.resolvedPostScriptName(for: .strong),
            code: FontLibrary.resolvedPostScriptName(for: .code)
        )
    }

    static func resolve(sampleText: String) -> Self {
        Self(
            body: FontLibrary.resolvePostScriptName(for: .body, sampleText: sampleText),
            emphasis: FontLibrary.resolvePostScriptName(for: .emphasis, sampleText: sampleText),
            strong: FontLibrary.resolvePostScriptName(for: .strong, sampleText: sampleText),
            code: FontLibrary.resolvePostScriptName(for: .code, sampleText: sampleText)
        )
    }
}

struct ETMarkdownFontRequest: Equatable, Sendable {
    let sampleText: String
    let revision: String
}

@MainActor
final class ETPreparedMarkdownFontState: ObservableObject, ETExportFontPreparing {
    var request: ETMarkdownFontRequest?
    private var preparedRequest: ETMarkdownFontRequest?
    @Published private var names: ETMarkdownFontNames?

    var needsPreparation: Bool { request != preparedRequest }
    var displayNames: ETMarkdownFontNames {
        preparedRequest == request ? names ?? .current : .current
    }

    func prepare() async throws -> Bool {
        guard let request, request != preparedRequest else { return false }
        let task = Task.detached(priority: .userInitiated) {
            ETMarkdownFontNames.resolve(sampleText: request.sampleText)
        }
        let resolved = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard self.request == request else { return false }
        preparedRequest = request
        names = resolved
        return true
    }
}

@MainActor
private struct PreparedMarkdownFonts: @preconcurrency DynamicProperty {
    @Environment(\.etFontExportPreparation) private var exportPreparation
    @StateObject private var state = ETPreparedMarkdownFontState()
    let sampleText: String

    init(sampleText: String) {
        self.sampleText = sampleText
    }

    var value: ETPreparedMarkdownFontState { state }
    var isExporting: Bool { exportPreparation != nil }

    mutating func update() {
        state.request = ETMarkdownFontRequest(sampleText: sampleText, revision: FontLibrary.adapterCacheToken())
        exportPreparation?.register(state)
    }
}

/// 首帧使用内存路由，字形覆盖检查留在后台；导出则显式等待相同的准备过程。
@MainActor
public struct ETMarkdownFontPreparation<Content: View>: View {
    private var prepared: PreparedMarkdownFonts
    private let content: (ETMarkdownFontNames) -> Content
    @State private var revision = FontLibrary.adapterCacheToken()

    public init(sampleText: String, @ViewBuilder content: @escaping (ETMarkdownFontNames) -> Content) {
        self.prepared = PreparedMarkdownFonts(sampleText: sampleText)
        self.content = content
    }

    public var body: some View {
        content(prepared.value.displayNames)
            .task(id: ETMarkdownFontRequest(sampleText: prepared.sampleText, revision: revision)) {
                guard !prepared.isExporting else { return }
                _ = try? await prepared.value.prepare()
            }
            .onReceive(NotificationCenter.default.publisher(for: .syncFontsUpdated).receive(on: DispatchQueue.main)) { _ in
                revision = FontLibrary.adapterCacheToken()
            }
    }
}
