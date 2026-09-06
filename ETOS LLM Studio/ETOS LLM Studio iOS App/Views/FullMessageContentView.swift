// ============================================================================
// FullMessageContentView.swift
// ============================================================================
// 全文只在用户主动打开时排版，保留 Markdown 源文本以便核对实际输入。
// ============================================================================

import SwiftUI
import UIKit

struct FullMessageContentView: View {
    let content: String

    var body: some View {
        ScrollView {
            Text(content)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .etFont(.body)
        .navigationTitle(NSLocalizedString("查看完整内容", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                CopyConfirmationButton {
                    UIPasteboard.general.string = content
                } label: { didCopy in
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityLabel(
                            didCopy
                                ? NSLocalizedString("已复制", comment: "")
                                : NSLocalizedString("复制", comment: "")
                        )
                }
            }
        }
    }
}
