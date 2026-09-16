import SwiftUI

public struct ChatRequestRetrySettingsSection: View {
    @ObservedObject private var appConfig = AppConfigStore.shared

    public init() {}

    public var body: some View {
        Section {
            Stepper(value: $appConfig.maximumRequestRetries, in: ChatRequestRetryPolicy.allowedMaximumRetries) {
                Text(String(format: NSLocalizedString("最多重试：%d 次", comment: ""), appConfig.maximumRequestRetries))
                    .monospacedDigit()
            }
        } header: {
            Text(NSLocalizedString("自动重试", comment: ""))
        } footer: {
            Text(NSLocalizedString("网络中断或服务暂时不可用时自动重试。设为 0 可关闭。", comment: ""))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
