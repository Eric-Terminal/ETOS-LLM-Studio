import Combine
import ETOSCore
import SwiftUI

@MainActor
final class MacAppearanceProfileDraft: ObservableObject {
    @Published var profile: ChatAppearanceProfile
    @Published private(set) var isWorking = false
    init(_ profile: ChatAppearanceProfile) { self.profile = profile }

    func reset() {
        // 重置只改变当前草稿；名称、标识及其他配置不变，保存仍需用户确认。
        profile = ChatAppearanceProfile(id: profile.id, name: profile.name)
    }

    func changeRules(_ group: MacAppearanceTextGroup, mutation: @escaping @Sendable (inout [ChatAppearanceTextColorRule]) -> Void) {
        guard !isWorking else { return }; isWorking = true
        let source = profile[keyPath: group.stylesPath].customRules
        Task { [weak self] in
            let rules = await Task.detached {
                var rules = source; mutation(&rules); return rules
            }.value
            guard let self else { return }
            profile[keyPath: group.stylesPath].customRules = rules; isWorking = false
        }
    }
}

/// ColorPicker 使用现成颜色；输入十六进制时在后台解析，渲染链不扫描字符串。
@MainActor
final class MacAppearanceColorDraft: ObservableObject {
    @Published private(set) var color = Color.primary
    private var task: Task<Void, Never>?
    func update(_ hex: String) {
        task?.cancel()
        task = Task { [weak self] in
            let color = await Task.detached { ChatAppearanceColorCodec.color(from: hex, fallback: .primary) }.value
            guard let self, !Task.isCancelled else { return }
            self.color = color
        }
    }
    func cancel() { task?.cancel() }
}
