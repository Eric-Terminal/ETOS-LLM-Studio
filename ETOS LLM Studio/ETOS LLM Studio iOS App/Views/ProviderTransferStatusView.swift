import ETOSCore
import SwiftUI

struct ProviderTransferStatusView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ProviderCompanionTransferStatusView()
                        .accessibilityIdentifier("provider.transfer.status")
                } footer: {
                    Text(ProviderCompanionTransferHelp.summary)
                }
            }
            .navigationTitle(NSLocalizedString("发送到 Apple Watch", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("完成", comment: "")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("provider.transfer.done")
                }
            }
            .guideSettingsPageContext(
                id: "provider-transfer-status",
                title: ProviderCompanionTransferHelp.title,
                documents: [GuideDocumentReference(id: "provider-model-basics", title: "Provider and Model Basics")],
                settings: ProviderCompanionTransferHelp.guideSettings + [
                    .readOnly("transfer_status", label: NSLocalizedString("状态", comment: ""), value: {
                        switch WatchSyncManager.shared.state {
                        case .idle:
                            .dictionary(["state": .string("idle")])
                        case .syncing(let message):
                            .dictionary(["state": .string("syncing"), "message": .string(message)])
                        case .success:
                            .dictionary(["state": .string("sent")])
                        case .failed(let message):
                            .dictionary(["state": .string("failed"), "message": .string(message)])
                        }
                    })
                ]
            )
        }
        .presentationDetents([.medium, .large])
    }
}
