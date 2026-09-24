import SwiftUI

/// 预览在后台准备，列表滚动和跑马灯布局不重复扫描提示词正文。
public struct GlobalSystemPromptSelectionLabel: View {
    private let entry: GlobalSystemPromptEntry
    private let isSelected: Bool
    @State private var title = ""
    @State private var preview = ""

    public init(entry: GlobalSystemPromptEntry, isSelected: Bool) {
        self.entry = entry
        self.isSelected = isSelected
    }

    public var body: some View {
        MarqueeTitleSubtitleSelectionRow(
            title: title.isEmpty ? NSLocalizedString("未命名提示词", comment: "") : title,
            subtitle: preview.isEmpty ? NSLocalizedString("空提示词（不发送）", comment: "") : preview,
            isSelected: isSelected,
            selectedColor: .blue
        )
        .task(id: entry) {
            let entry = entry
            let prepared = await Task.detached(priority: .userInitiated) {
                let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let preview = String(entry.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                return (title, preview)
            }.value
            guard !Task.isCancelled else { return }
            title = prepared.0
            preview = prepared.1
        }
    }
}
