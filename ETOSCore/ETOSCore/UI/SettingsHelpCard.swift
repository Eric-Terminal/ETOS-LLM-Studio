import SwiftUI

/// 将操作说明留在详情中，避免设置列表被长段文字撑开。
public struct SettingsHelpCard<Details: View>: View {
    private let title: String
    private let summary: String
    private let details: () -> Details
    @State private var isShowingDetails = false

    /// 平台页面可为详情接入各自的向导入口，卡片只负责展示与导航。
    public init(title: String, summary: String, @ViewBuilder details: @escaping () -> Details) {
        self.title = title
        self.summary = summary
        self.details = details
    }

    public var body: some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(titleFont)
            Text(summary)
                .font(summaryFont)
                .foregroundStyle(.secondary)
            Button(NSLocalizedString("进一步了解…", value: "Learn more…", comment: "打开设置使用说明")) {
                isShowingDetails = true
            }
            .font(.footnote)
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $isShowingDetails) {
            NavigationStack {
                details()
                    .navigationTitle(title)
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
            }
        }
    }

    private var titleFont: Font {
        #if os(watchOS)
        .footnote.weight(.semibold)
        #else
        .headline
        #endif
    }

    private var summaryFont: Font {
        #if os(watchOS)
        .caption2
        #else
        .footnote
        #endif
    }
}

public extension SettingsHelpCard where Details == SettingsHelpText {
    init(title: String, summary: String, details: String) {
        self.init(title: title, summary: summary) {
            SettingsHelpText(details)
        }
    }
}

/// 保持介绍页的长文排版一致，页面上下文由对应功能显式声明。
public struct SettingsHelpText: View {
    private let details: String

    public init(_ details: String) {
        self.details = details
    }

    public var body: some View {
        ScrollView {
            Text(details)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}
