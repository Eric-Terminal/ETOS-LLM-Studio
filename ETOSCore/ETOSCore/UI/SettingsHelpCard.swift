import SwiftUI

/// 将操作说明留在详情中，避免设置列表被长段文字撑开。
public struct SettingsHelpCard: View {
    private let title: String
    private let summary: String
    private let details: String
    @State private var isShowingDetails = false

    public init(title: String, summary: String, details: String) {
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
            Button(NSLocalizedString("进一步了解…", comment: "打开设置使用说明")) {
                isShowingDetails = true
            }
            .font(.footnote)
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $isShowingDetails) {
            #if os(watchOS)
            detailsContent
            #else
            NavigationStack {
                detailsContent
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
            }
            #endif
        }
    }

    private var detailsContent: some View {
        ScrollView {
            Text(details)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
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
