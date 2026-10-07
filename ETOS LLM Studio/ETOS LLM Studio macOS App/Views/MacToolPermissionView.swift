import ETOSCore
import SwiftUI

struct MacToolPermissionView: View {
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
            if let seconds = center.autoApproveRemainingSeconds {
                Text(String(format: NSLocalizedString("将在 %d 秒后自动允许", comment: ""), seconds))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(NSLocalizedString("拒绝", comment: ""), role: .cancel) { resolve(.deny) }
                Spacer()
                if !request.forcePrompt {
                    Button(NSLocalizedString("允许此工具", comment: "")) { resolve(.allowForTool) }
                }
                Button(NSLocalizedString("允许一次", comment: "")) { resolve(.allowOnce) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(minWidth: 500, idealWidth: 600, minHeight: 320, idealHeight: 450)
    }

    private func resolve(_ decision: ToolPermissionDecision) {
        center.resolveRequest(withID: request.id, decision: decision)
    }
}
