import ETOSCore
import SwiftUI

struct MacToolPermissionView: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    let request: ToolPermissionRequest
    @ObservedObject private var center = ToolPermissionCenter.shared

    var body: some View {
        VStack(alignment: .leading) {
            Label(NSLocalizedString("工具调用确认", comment: ""), systemImage: "hand.raised")
                .font(.headline)
            Text(request.displayName ?? request.toolName)
            ScrollView {
                Text(request.arguments)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let seconds = center.autoApproveRemainingSeconds(for: request) {
                Text(String(format: NSLocalizedString("将在 %d 秒后自动允许", comment: ""), seconds))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if center.autoApproveEnabled && !request.forcePrompt {
                MacToolAutoApprovalToggle(request: request, model: workspace.toolApproval)
            }
            HStack {
                Button(NSLocalizedString("拒绝", comment: ""), role: .cancel) { resolve(.deny) }
                Button(NSLocalizedString("补充提示", comment: "")) {
                    if center.resolveRequest(withID: request.id, decision: .supplement) {
                        workspace.selectSession(request.sourceSessionID)
                    }
                }
                Spacer()
                if !request.forcePrompt {
                    Menu(NSLocalizedString("更多", comment: "")) {
                        Button(NSLocalizedString("允许此工具", comment: "")) { resolve(.allowForTool) }
                        Button(NSLocalizedString("完全权限", comment: "")) { resolve(.allowAll) }
                    }
                }
                Button(NSLocalizedString("允许一次", comment: "")) { resolve(.allowOnce) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(minWidth: 500, idealWidth: 600, minHeight: 320, idealHeight: 450)
        .guidePageContext(
            descriptor: GuidePageDescriptor(id: GuidePageID(rawValue: "mac-tool-permission-\(request.id)"),
                title: NSLocalizedString("工具调用确认", comment: ""), documents: [GuideDocumentReference(id: "settings-tools", title: "Tool Center")]),
            isActive: center.activeRequest?.id == request.id && !workspace.isRestoringData,
            snapshot: { GuidePageSnapshot(fields: [
                "tool": GuideSnapshotField(label: NSLocalizedString("工具", comment: ""), value: .string(request.displayName ?? request.toolName), access: .readOnly),
                "arguments": GuideSnapshotField(label: NSLocalizedString("参数", comment: ""), value: .string(GuideSnapshotField.hiddenValue), access: .writeOnly),
                "force_prompt": GuideSnapshotField(label: NSLocalizedString("工具调用确认", comment: ""), value: .bool(request.forcePrompt), access: .readOnly),
                "auto_approve_enabled": GuideSnapshotField(label: NSLocalizedString("启用倒计时自动批准", comment: ""), value: .bool(center.autoApproveEnabled), access: .readOnly),
                "remaining_seconds": GuideSnapshotField(label: NSLocalizedString("倒计时自动批准", comment: ""), value: center.autoApproveRemainingSeconds(for: request).map(JSONValue.int) ?? .null, access: .readOnly),
                "auto_approve_disabled": GuideSnapshotField(label: NSLocalizedString("允许该工具自动批准", comment: ""), value: .bool(center.isAutoApproveDisabled(for: request.toolName)), access: .readOnly)
            ]) }
        )
    }

    private func resolve(_ decision: ToolPermissionDecision) {
        center.resolveRequest(withID: request.id, decision: decision)
    }
}

private struct MacToolAutoApprovalToggle: View {
    let request: ToolPermissionRequest
    @ObservedObject var model: MacToolApprovalModel
    @ObservedObject private var center = ToolPermissionCenter.shared
    @State private var error: String?

    var body: some View {
        Toggle(NSLocalizedString("允许该工具自动批准", comment: ""), isOn: Binding(
            get: { !center.isAutoApproveDisabled(for: request.toolName) },
            set: { value in
                let token = model.epoch
                Task {
                    do { try await model.update(.disableForTool(request.toolName, !value), expectedEpoch: token, requestID: request.id) }
                    catch { if token == model.epoch, center.activeRequest?.id == request.id { self.error = error.localizedDescription } }
                }
            }
        )).disabled(!model.canWrite || center.activeRequest?.id != request.id)
        if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
    }
}
