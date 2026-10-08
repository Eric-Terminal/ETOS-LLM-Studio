import ETOSCore
import SwiftUI

struct MacFontPreview: View {
    let revision: UUID
    @ObservedObject private var config = AppConfigStore.shared
    @State private var prepared: MacPreparedMessageText?
    var body: some View {
        Group {
            if let prepared { MacMessageTextView(text: prepared) }
            else { ProgressView() }
        }
        .task(id: revision) {
            let spacing = config.fontLineSpacingEmIOS
            let result = await Task.detached {
                let source = NSLocalizedString("The quick brown fox jumps over the lazy dog.", comment: "") + "\n\n"
                    + NSLocalizedString("中文：风来疏竹，风过而竹不留声。", comment: "") + "\n\n*"
                    + NSLocalizedString("斜体预览 / Emphasis", comment: "") + "*\n\n**"
                    + NSLocalizedString("粗体预览 / Strong", comment: "") + "**\n\n`"
                    + NSLocalizedString("let message = \"Code Preview\"", comment: "") + "`"
                let base = MacPreparedMessageText(source, markdown: true)
                let typography = await MacTextTypography.prepare(source, lineSpacing: spacing)
                return MacPreparedMessageText(base: base, lightRules: nil, darkRules: nil, typography: typography)
            }.value
            guard !Task.isCancelled else { return }; prepared = result
        }
    }
}
