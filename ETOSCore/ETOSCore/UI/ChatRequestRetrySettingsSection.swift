import SwiftUI

public struct ChatRequestRetrySettingsSection: View {
    @ObservedObject private var appConfig = AppConfigStore.shared

    public init() {}

    public var body: some View {
        Section {
            Toggle(NSLocalizedString("智能判断", comment: "自动重试错误筛选开关"), isOn: $appConfig.requestRetrySmartDetectionEnabled)
            #if os(watchOS)
            // 避开 watchOS Stepper 的交互异常，直接选择允许的重试次数。
            Picker(NSLocalizedString("最大重试次数", comment: ""), selection: $appConfig.maximumRequestRetries) {
                ForEach(ChatRequestRetryPolicy.allowedMaximumRetries, id: \.self) { count in
                    Text(count, format: .number)
                        .monospacedDigit()
                        .tag(count)
                }
            }
            .pickerStyle(.wheel)
            #else
            Stepper(value: $appConfig.maximumRequestRetries, in: ChatRequestRetryPolicy.allowedMaximumRetries) {
                Text(String(format: NSLocalizedString("最多重试：%d 次", comment: ""), appConfig.maximumRequestRetries))
                    .monospacedDigit()
            }
            #endif
        } header: {
            Text(NSLocalizedString("自动重试", comment: ""))
        } footer: {
            Text(NSLocalizedString("开启时仅重试临时错误；关闭后，所有请求错误都会重试。次数设为 0 可关闭自动重试。", comment: ""))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
