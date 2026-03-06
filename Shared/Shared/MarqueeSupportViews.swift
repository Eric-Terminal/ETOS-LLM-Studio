// ============================================================================
// MarqueeSupportViews.swift
// ============================================================================
// 共享的跑马灯辅助视图
// - 提供主副标题组合展示
// - 提供带选中态的滚动选择行
// ============================================================================

import SwiftUI

public struct MarqueeTitleSubtitleLabel: View {
    let title: String
    let subtitle: String?
    let titleUIFont: UIFont
    let subtitleUIFont: UIFont
    let subtitleColor: Color
    let spacing: CGFloat

    public init(
        title: String,
        subtitle: String? = nil,
        titleUIFont: UIFont = .preferredFont(forTextStyle: .body),
        subtitleUIFont: UIFont = .preferredFont(forTextStyle: .caption1),
        subtitleColor: Color = .secondary,
        spacing: CGFloat = 4
    ) {
        self.title = title
        self.subtitle = subtitle
        self.titleUIFont = titleUIFont
        self.subtitleUIFont = subtitleUIFont
        self.subtitleColor = subtitleColor
        self.spacing = spacing
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            MarqueeText(content: title, uiFont: titleUIFont)
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let subtitle, !subtitle.isEmpty {
                MarqueeText(content: subtitle, uiFont: subtitleUIFont)
                    .foregroundStyle(subtitleColor)
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

public struct MarqueeSelectionRow: View {
    let title: String
    let isSelected: Bool
    let uiFont: UIFont
    let selectedColor: Color

    public init(
        title: String,
        isSelected: Bool,
        uiFont: UIFont = .preferredFont(forTextStyle: .body),
        selectedColor: Color = .accentColor
    ) {
        self.title = title
        self.isSelected = isSelected
        self.uiFont = uiFont
        self.selectedColor = selectedColor
    }

    public var body: some View {
        HStack {
            MarqueeText(content: title, uiFont: uiFont)
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.footnote)
                    .foregroundStyle(selectedColor)
            }
        }
    }
}
