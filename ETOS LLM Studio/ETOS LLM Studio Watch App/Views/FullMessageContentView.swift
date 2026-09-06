// ============================================================================
// FullMessageContentView.swift
// ============================================================================
// 全文只在用户主动打开时排版，保留 Markdown 源文本以便核对实际输入。
// ============================================================================

import SwiftUI

struct FullMessageContentView: View {
    let content: String

    var body: some View {
        ScrollView {
            Text(content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .etFont(.body)
        .navigationTitle(NSLocalizedString("查看完整内容", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }
}
