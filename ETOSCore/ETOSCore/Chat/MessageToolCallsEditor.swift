import SwiftUI

/// JSON 草稿仅在父消息编辑器保存后才落库。向导只能获知状态，不能读取可能包含凭据的调用内容。
public struct MessageToolCallsEditor<Help: View>: View {
    @Binding private var json: String
    @State private var isAdding = false
    @State private var errorMessage: String?
    private let help: () -> Help

    public init(json: Binding<String>, @ViewBuilder help: @escaping () -> Help) {
        _json = json
        self.help = help
    }

    public var body: some View {
        Form {
            Section {
                settingsIntroCard
                Button(NSLocalizedString("添加工具调用", comment: "")) {
                    appendCall()
                }
                .disabled(isAdding)
            }
            Section {
                #if os(watchOS)
                TextField(NSLocalizedString("工具调用 JSON", comment: ""), text: $json, axis: .vertical)
                    .font(.footnote.monospaced())
                    .lineLimit(8...20)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                #else
                TextEditor(text: $json)
                    .font(.footnote.monospaced())
                    .frame(minHeight: 280)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                #endif
            } header: {
                Text(NSLocalizedString("工具调用 JSON", comment: ""))
            } footer: {
                Text(NSLocalizedString("返回后点击“保存”才会更新消息；保存不会执行工具。", comment: ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("工具调用 JSON", comment: ""))
        .guidePageContext(
            descriptor: GuidePageDescriptor(
                id: "message-tool-calls-editor",
                title: NSLocalizedString("工具调用 JSON", comment: ""),
                documents: [GuideDocumentReference(id: "message-tool-call-editing", title: NSLocalizedString("工具调用 JSON", comment: ""))]
            ),
            snapshot: { GuidePageSnapshot(fields: [
                "draft": GuideSnapshotField(label: NSLocalizedString("工具调用 JSON", comment: ""), value: .string(""), access: .writeOnly),
                "saved": GuideSnapshotField(label: NSLocalizedString("保存", comment: ""), value: .bool(false), access: .readOnly)
            ]) }
        )
        .alert(NSLocalizedString("操作失败", comment: ""), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button(NSLocalizedString("确定", comment: ""), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private var settingsIntroCard: some View {
        SettingsHelpCard(
            title: NSLocalizedString("编辑说明", value: "Editing guide", comment: "工具调用介绍卡标题"),
            summary: NSLocalizedString("可以添加、修改或移除调用；正文为空也可以保存。", value: "Add, edit, or remove calls. Messages with an empty body can also be saved.", comment: "工具调用介绍卡摘要"),
            details: help
        )
    }

    private func appendCall() {
        let draft = json
        isAdding = true
        Task {
            defer { isAdding = false }
            do {
                let updated = try await Task.detached(priority: .userInitiated) {
                    var calls = try MessageToolCallEditingSupport.parse(draft)
                    calls.append(InternalToolCall(id: "call_\(UUID().uuidString)", toolName: "", arguments: "{}"))
                    return try MessageToolCallEditingSupport.editableJSON(calls)
                }.value
                // 异步准备期间用户可以继续输入，不能用旧草稿覆盖新编辑。
                guard json == draft else { return }
                json = updated
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

public extension MessageToolCallsEditor where Help == MessageToolCallsHelpView {
    init(json: Binding<String>) {
        self.init(json: json) { MessageToolCallsHelpView() }
    }
}
