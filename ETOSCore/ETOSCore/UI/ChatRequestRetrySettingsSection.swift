import SwiftUI

public struct ChatRequestRetrySettingsSection: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var maximumRetriesDraft = ""
    @State private var isInvalid = false

    public init() {}

    public var body: some View {
        Section {
            Toggle(NSLocalizedString("智能判断", comment: "自动重试错误筛选开关"), isOn: $appConfig.requestRetrySmartDetectionEnabled)
            VStack(alignment: .leading) {
                Text(NSLocalizedString("最大重试次数", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(NSLocalizedString("最大重试次数", comment: ""), text: $maximumRetriesDraft)
                    .monospacedDigit()
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }
            if isInvalid {
                Text(NSLocalizedString("retry.count.invalid", value: "Enter a whole number from 0 to 10. The last valid value is kept until then.", comment: "重试次数格式错误提示"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(NSLocalizedString("自动重试", comment: ""))
        } footer: {
            Text(NSLocalizedString("retry.count.help", value: "Enter a whole number from 0 to 10. Valid changes are saved automatically.", comment: "重试次数输入说明"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(NSLocalizedString("开启时仅重试临时错误；关闭后，所有请求错误都会重试。次数设为 0 可关闭自动重试。", comment: ""))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .onAppear { maximumRetriesDraft = String(appConfig.maximumRequestRetries) }
        .onChange(of: maximumRetriesDraft) { _, text in
            // 清空、输入中和越界值不写入数据库，避免把未完成的输入误当作关闭重试。
            guard let count = ChatRequestRetryPolicy.maximumRetries(from: text) else {
                isInvalid = true
                return
            }
            isInvalid = false
            if appConfig.maximumRequestRetries != count { appConfig.maximumRequestRetries = count }
        }
        .onChange(of: appConfig.maximumRequestRetries) { _, count in
            if ChatRequestRetryPolicy.maximumRetries(from: maximumRetriesDraft) != count {
                maximumRetriesDraft = String(count)
                isInvalid = false
            }
        }
    }
}
