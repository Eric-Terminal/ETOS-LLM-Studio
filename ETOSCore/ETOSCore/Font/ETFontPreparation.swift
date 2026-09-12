import Combine
import SwiftUI

/// 只携带文字解析需要的值，不能把含视图状态的 EnvironmentValues 跨 actor 传递。
struct ETFontPreparationRequest: Equatable, Sendable {
    let descriptor: ETFont?
    let sampleText: String?
    let text: Text?
    let locale: Locale
    let calendar: Calendar
    let timeZone: TimeZone
    let sizeCategory: ContentSizeCategory
    let revision: String
    var scaledBasePointSize: CGFloat? = nil
}

@MainActor
final class ETPreparedFontState: ObservableObject {
    @Published private(set) var font: Font?
    var request: ETFontPreparationRequest?
    private var preparedRequest: ETFontPreparationRequest?

    var needsPreparation: Bool { request != preparedRequest }

    @discardableResult
    func prepare() async throws -> Bool {
        guard let request, request != preparedRequest else { return false }
        let resolved = await ETFontResolver.shared.font(for: request)
        try Task.checkCancellation()
        guard self.request == request else { return false }
        preparedRequest = request
        font = resolved
        return true
    }
}

/// 离屏布局只登记实际用到的请求；截图前显式等待，避免依赖 ImageRenderer 不运行的 task。
@MainActor
public final class ETFontExportPreparation {
    private var pending: [ObjectIdentifier: ETPreparedFontState] = [:]

    public init() {}

    func register(_ state: ETPreparedFontState) {
        guard state.needsPreparation else { return }
        pending[ObjectIdentifier(state)] = state
    }

    /// 返回是否更新过字体；调用方使用同一棵视图重新测量，直到没有新请求。
    @discardableResult
    public func preparePendingFonts() async throws -> Bool {
        var changed = false
        while !pending.isEmpty {
            let states = Array(pending.values)
            pending.removeAll(keepingCapacity: true)
            for state in states {
                changed = try await state.prepare() || changed
            }
        }
        return changed
    }
}

@MainActor
private struct PreparedETFont: @preconcurrency DynamicProperty {
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.etFontExportPreparation) private var exportPreparation
    @StateObject private var state = ETPreparedFontState()
    @ScaledMetric private var scaledBasePointSize: CGFloat
    let descriptor: ETFont?
    let sampleText: String?
    let text: Text?

    init(descriptor: ETFont?, sampleText: String?, text: Text?) {
        self.descriptor = descriptor
        self.sampleText = sampleText
        self.text = text
        _scaledBasePointSize = ScaledMetric(wrappedValue: descriptor?.basePointSize ?? 17, relativeTo: descriptor?.textStyle ?? .body)
    }

    var value: ETPreparedFontState { state }
    var isExporting: Bool { exportPreparation != nil }

    mutating func update() {
        state.request = ETFontPreparationRequest(
            descriptor: descriptor,
            sampleText: sampleText,
            text: text,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone,
            sizeCategory: sizeCategory,
            revision: FontLibrary.adapterCacheToken(),
            scaledBasePointSize: scaledBasePointSize
        )
        // 登记在属性更新阶段完成；body 不解析文字、不查询字形，也不创建 CoreText 字体。
        exportPreparation?.register(state)
    }
}

@MainActor
public struct ETFontModifier: ViewModifier {
    private let descriptor: ETFont?
    private var prepared: PreparedETFont
    @State private var configurationRevision = FontLibrary.adapterCacheToken()

    public init(_ descriptor: ETFont?, sampleText: String? = nil, text: Text? = nil) {
        self.descriptor = descriptor
        prepared = PreparedETFont(descriptor: descriptor, sampleText: sampleText, text: text)
    }

    private struct TaskIdentity: Equatable {
        let request: ETFontPreparationRequest?
        let revision: String
    }

    public func body(content: Content) -> some View {
        content
            .font(descriptor.map { prepared.value.font ?? $0.systemFont })
            .task(id: TaskIdentity(request: prepared.value.request, revision: configurationRevision)) {
                guard !prepared.isExporting else { return }
                // 取消后的结果由状态对象丢弃；新请求会由 SwiftUI 的 task(id:) 重新准备。
                _ = try? await prepared.value.prepare()
            }
            .onReceive(NotificationCenter.default.publisher(for: .syncFontsUpdated).receive(on: DispatchQueue.main)) { _ in
                configurationRevision = FontLibrary.adapterCacheToken()
            }
    }
}

private struct ETFontExportPreparationKey: EnvironmentKey {
    static let defaultValue: ETFontExportPreparation? = nil
}

public extension EnvironmentValues {
    var etFontExportPreparation: ETFontExportPreparation? {
        get { self[ETFontExportPreparationKey.self] }
        set { self[ETFontExportPreparationKey.self] = newValue }
    }
}
