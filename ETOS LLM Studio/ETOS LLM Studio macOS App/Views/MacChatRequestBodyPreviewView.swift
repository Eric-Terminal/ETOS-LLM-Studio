import AppKit
import ETOSCore
import SwiftUI

struct MacChatRequestBodyPreviewView: View {
    let model: Model
    let draft: MacRequestBodyDraft
    let apiFormat: String
    @State private var bodyText = ""
    @State private var error: String?
    @State private var busy = true
    @ObservedObject private var config = AppConfigStore.shared
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: MacWorkspaceModel

    init(model: Model, draft: MacRequestBodyDraft, apiFormat: String) {
        self.model = model; self.draft = draft; self.apiFormat = apiFormat
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "request-preview-\(model.id)", title: NSLocalizedString("使用说明", comment: ""),
                        details: NSLocalizedString("Mac 聊天请求体示例使用说明", comment: ""), documentID: "model-request-body")
                    if busy { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
                    else if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                    else { Text(bodyText).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(NSLocalizedString("聊天请求体示例", comment: ""))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(NSLocalizedString("完成", comment: "")) { dismiss() } }
                ToolbarItem {
                    Button(NSLocalizedString("复制", comment: "")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(bodyText, forType: .string)
                    }.disabled(busy || error != nil || workspace.isRestoringData)
                }
            }
            .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-request-preview-\(model.id)"),
                title: NSLocalizedString("聊天请求体示例", comment: ""),
                documents: [GuideDocumentReference(id: "model-request-body", title: "Request Body Controls")], settings: [
                    .readOnly("preview_kind", label: NSLocalizedString("应用方式", comment: ""), value: { .string("sample_chat_body_with_default_controls") }),
                    .readOnly("api_format", label: NSLocalizedString("API 格式", comment: ""), value: { .string(apiFormat) }),
                    .readOnly("ready", label: NSLocalizedString("配置有效", comment: ""), value: { .bool(!busy && error == nil) })
                ])
        }
        .modifier(MacGuideInspector())
        .frame(minWidth: 580, minHeight: 520)
        .task(id: config.appLanguage) { await prepare() }
        .onChange(of: workspace.isRestoringData) { _, restoring in if restoring { dismiss() } }
    }

    private func prepare() async {
        busy = true; bodyText = ""; error = nil
        let source = model, body = draft, format = apiFormat
        let result = await Task.detached { Result {
            try body.validate()
            var model = source
            body.apply(to: &model)
            return try ModelChatRequestBodyPreview.body(model: model, providerAPIFormat: format)
        } }.value
        guard !Task.isCancelled, !workspace.isRestoringData else { return }
        busy = false
        switch result {
        case .success(let text): bodyText = text
        case .failure(let failure): error = failure.localizedDescription
        }
    }
}
