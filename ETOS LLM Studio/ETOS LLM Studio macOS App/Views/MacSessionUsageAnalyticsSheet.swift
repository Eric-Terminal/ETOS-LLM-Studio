import ETOSCore
import SwiftUI

struct MacSessionUsageAnalyticsSheet: View {
    let session: ChatSession
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SessionUsageAnalyticsView(sessionID: session.id, sessionName: session.name, isActive: workspace.canManageLocalModels)
                .id(session.id)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(NSLocalizedString("关闭", comment: "")) { dismiss() }
                    }
                }
                .modifier(MacGuideInspector())
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 480, idealHeight: 620)
    }
}
