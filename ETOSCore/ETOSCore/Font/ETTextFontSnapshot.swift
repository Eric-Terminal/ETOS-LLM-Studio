import SwiftUI

/// 与后台准备的正文一起交付字体路由，避免新视图先显示首选字体再切换。
/// 只保存当前进程的显示结果，不写入消息或同步数据。
public struct ETTextFontSnapshot: Equatable, Sendable {
    let sample: String
    let revision: String
    let names: ETMarkdownFontNames
    let fallbackScope: FontFallbackScope
    let scale: Double

    /// 调用方必须位于正文预处理队列；首次使用会等待字体库准备完成。
    public static func prepare(for text: String) -> Self {
        FontLibrary.preloadRuntimeCache()
        let sample = FontLibrary.normalizedSampleText(text)
        let revision = FontLibrary.adapterCacheToken()
        return Self(
            sample: sample,
            revision: revision,
            names: ETMarkdownFontNames.resolve(sampleText: sample),
            fallbackScope: FontLibrary.fallbackScope,
            scale: FontLibrary.customFontScale
        )
    }

    func matches(sampleText: String, revision: String) -> Bool {
        self.revision == revision && sample == FontLibrary.normalizedSampleText(sampleText)
    }

    /// 整段自定义字体是可直接使用的 SwiftUI 描述，不需要再次排队解析文字或访问 CoreText。
    /// 逐字级联和带倍率的系统字体仍交给原有平台度量路径，保留其 Dynamic Type 行为。
    func font(for descriptor: ETFont) -> Font? {
        guard fallbackScope == .segment else { return nil }
        let name: String?
        switch descriptor.role {
        case .body: name = names.body
        case .emphasis: name = names.emphasis
        case .strong: name = names.strong
        case .code: name = names.code
        }
        guard let name else {
            return abs(scale - 1) < 0.001 ? descriptor.systemFont : nil
        }
        let size = descriptor.basePointSize * CGFloat(scale)
        let font: Font
        if let style = descriptor.textStyle {
            font = .custom(name, size: size, relativeTo: style)
        } else {
            font = .custom(name, size: size)
        }
        return descriptor.applyingTraits(to: font)
    }
}

private struct ETTextFontSnapshotKey: EnvironmentKey {
    static let defaultValue: ETTextFontSnapshot? = nil
}

public extension EnvironmentValues {
    var etTextFontSnapshot: ETTextFontSnapshot? {
        get { self[ETTextFontSnapshotKey.self] }
        set { self[ETTextFontSnapshotKey.self] = newValue }
    }
}
