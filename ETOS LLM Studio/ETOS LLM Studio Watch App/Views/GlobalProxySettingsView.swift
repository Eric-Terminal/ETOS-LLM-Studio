import SwiftUI
import Foundation
import Shared

struct GlobalProxySettingsView: View {
    @ObservedObject private var proxyStore = NetworkProxySettingsStore.shared
    @State private var showPassword = false

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }

    var body: some View {
        Form {
            Section(
                header: Text("全局代理"),
                footer: Text(globalFooterText)
            ) {
                Toggle("启用全局代理", isOn: $proxyStore.isEnabled)

                if proxyStore.isEnabled {
                    Picker("代理类型", selection: $proxyStore.type) {
                        Text("HTTP / HTTPS").tag(NetworkProxyType.http)
                        Text("SOCKS5").tag(NetworkProxyType.socks5)
                    }

                    TextField("代理地址", text: $proxyStore.host.watchKeyboardNewlineBinding())
                        .etFont(.caption)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("端口", value: $proxyStore.port, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: proxyStore.port) { _, newValue in
                            let clamped = max(1, min(65535, newValue))
                            if clamped != newValue {
                                proxyStore.port = clamped
                            }
                        }

                    TextField("用户名（可选）", text: $proxyStore.username.watchKeyboardNewlineBinding())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Group {
                        if showPassword {
                            TextField("密码（可选）", text: $proxyStore.password.watchKeyboardNewlineBinding())
                        } else {
                            SecureField("密码（可选）", text: $proxyStore.password.watchKeyboardNewlineBinding())
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Toggle("显示代理密码", isOn: $showPassword)
                }
            }

            Section("优先级说明") {
                Text("提供商设置中开启“独立代理”后，将优先使用提供商代理；未开启时才使用这里的全局代理。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("全局代理设置")
    }

    private var globalFooterText: String {
        guard proxyStore.isEnabled else {
            return NSLocalizedString("关闭时不会对任何请求使用全局代理。", comment: "")
        }
        let host = proxyStore.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            return NSLocalizedString("已启用全局代理，但代理地址为空。", comment: "")
        }
        guard (1...65535).contains(proxyStore.port) else {
            return NSLocalizedString("代理端口必须在 1~65535 之间。", comment: "")
        }
        return NSLocalizedString("支持 HTTP / HTTPS 和 SOCKS5。填写用户名后会自动启用代理鉴权。", comment: "")
    }
}
