import SwiftUI

/// JSON 草稿仅在父消息编辑器保存后才落库。向导只能获知状态，不能读取可能包含凭据的调用内容。
public struct MessageToolCallsEditor: View {
    @Binding private var json: String
    @State private var isAdding = false
    @State private var errorMessage: String?
    @State private var showsHelp = false

    public init(json: Binding<String>) { _json = json }

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

    @ViewBuilder
    private var settingsIntroCard: some View {
        #if os(watchOS)
        Button(NSLocalizedString("编辑说明", comment: "")) { showsHelp.toggle() }
            .buttonStyle(.plain)
        if showsHelp {
            Text(helpText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        #else
        DisclosureGroup(NSLocalizedString("编辑说明", comment: "")) {
            Text(helpText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                #if os(iOS)
                .textSelection(.enabled)
                #endif
        }
        #endif
    }

    private var helpText: String {
        NSLocalizedString("使用 JSON 数组编辑调用。每项包含 id、toolName 和 arguments（JSON 对象或包含对象的字符串）；可选 result、resultDisposition 和 providerSpecificFields。新增一项即可添加调用，删除一项可移除调用，[] 表示清空。id 必须唯一，建议保留现有 id 以维持结果关联。result 为字符串，状态可为 completed、failed 或 rejected。修改会同步同轮对话中的关联结果；这些记录会用于后续聊天历史。", comment: "")
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
