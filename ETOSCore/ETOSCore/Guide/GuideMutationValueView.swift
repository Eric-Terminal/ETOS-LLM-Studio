import SwiftUI

/// 提案可能包含整段请求体或配置数组，格式化必须离开界面渲染链路。
public struct GuideMutationValueView: View {
    private let mutation: GuideSettingMutation
    @State private var formattedValue: String?

    public init(mutation: GuideSettingMutation) {
        self.mutation = mutation
    }

    public var body: some View {
        Group {
            if let formattedValue {
                Text(formattedValue)
            } else {
                ProgressView()
            }
        }
        .task(id: mutation.id) {
            formattedValue = nil
            // 只传递已脱敏的预览值，执行器的原始参数不会进入此视图。
            let value = mutation.newValue
            let prepared = await Task.detached(priority: .userInitiated) {
                value.prettyPrintedCompact()
            }.value
            guard !Task.isCancelled else { return }
            formattedValue = prepared
        }
    }
}
