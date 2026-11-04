import SwiftUI

public enum ProviderCompanionTransferHelp {
    public static var title: String {
        NSLocalizedString("provider.transfer.title", value: "Send a Provider", comment: "单个提供商发送说明标题")
    }

    public static var summary: String {
        NSLocalizedString("provider.transfer.summary", value: "Send one provider with its API keys and models to your paired device.", comment: "单个提供商发送摘要")
    }

    public static var details: String {
        NSLocalizedString("provider.transfer.help", value: "On iPhone, open Provider Management, touch and hold a remote provider, then choose Send to Apple Watch. On Apple Watch, open the provider and choose Send to iPhone.\n\nThe saved provider is sent with its API keys, key notes, models, custom headers and independent proxy settings. Save any edits first. Conversations, other providers, global settings and local model files are not included.\n\nBoth devices must have device sync enabled in Sync & Backup. You do not need to start a full sync. If the other device is offline, delivery waits for a connection. Sent means the transfer finished; check the provider on the receiving device.\n\nThe receiving device uses the existing provider merge rules: matching providers merge keys and models, and conflicting settings may retain the receiving device's values. This does not replace its entire configuration database.\n\nThis transfer is available only between a paired iPhone and Apple Watch, not on Mac. Local model providers cannot be sent. The page guide can explain these steps but cannot send credentials or start a transfer.", comment: "单个提供商发送完整教程")
    }

    #if os(iOS) || os(watchOS)
    @MainActor public static var guideSettings: [GuidePageSetting] {
        [
            .readOnly("single_provider_transfer", label: title, value: { .string(details) }),
            .readOnly("device_sync_enabled", label: NSLocalizedString("设备同步", comment: ""), value: {
                .bool(isWatchConnectivitySyncEnabled())
            }),
            .readOnly("transfer_in_progress", label: title, value: {
                if case .syncing = WatchSyncManager.shared.state { return .bool(true) }
                return .bool(false)
            })
        ]
    }
    #endif
}

#if os(iOS) || os(watchOS)
public struct ProviderCompanionTransferStatusView: View {
    @ObservedObject private var syncManager = WatchSyncManager.shared

    public init() {}

    public var body: some View {
        switch syncManager.state {
        case .idle:
            EmptyView()
        case .syncing(let message):
            ProgressView(message)
                .font(.footnote)
        case .success:
            Label(
                NSLocalizedString("provider.transfer.sent", value: "Sent. Check the provider on the other device.", comment: "单个提供商传输完成，不代表接收端已合并"),
                systemImage: "checkmark.circle"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}
#endif
