import ETOSCore
import SwiftUI

/// 全局和提供商草稿共用字段，关闭开关不会清除已填的认证信息。
struct MacProxyFields: View {
    @Binding var configuration: NetworkProxyConfiguration
    @Binding var showsPassword: Bool

    var body: some View {
        Toggle(NSLocalizedString("启用代理", comment: ""), isOn: $configuration.isEnabled)
        Picker(NSLocalizedString("代理类型", comment: ""), selection: $configuration.type) {
            Text(NSLocalizedString("HTTP / HTTPS", comment: "")).tag(NetworkProxyType.http)
            Text(NSLocalizedString("SOCKS5", comment: "")).tag(NetworkProxyType.socks5)
        }
        TextField(NSLocalizedString("代理地址", comment: ""), text: $configuration.host)
            .autocorrectionDisabled()
        TextField(NSLocalizedString("端口", comment: ""), value: $configuration.port, format: .number.grouping(.never))
        TextField(NSLocalizedString("用户名（可选）", comment: ""), text: $configuration.username)
            .autocorrectionDisabled()
        if showsPassword {
            TextField(NSLocalizedString("密码（可选）", comment: ""), text: $configuration.password)
                .autocorrectionDisabled()
        } else {
            SecureField(NSLocalizedString("密码（可选）", comment: ""), text: $configuration.password)
        }
        Toggle(NSLocalizedString("显示代理密码", comment: ""), isOn: $showsPassword)
    }
}

@MainActor
enum MacProxyGuideSettings {
    static func fields(_ configuration: Binding<NetworkProxyConfiguration>, showsPassword: Bool) -> [GuidePageSetting] {
        [
            .readOnly("editing_mode", label: NSLocalizedString("编辑方式", comment: ""), value: { .string("draft_until_save") }),
            .readOnly("password_visible", label: NSLocalizedString("显示代理密码", comment: ""), value: { .bool(showsPassword) }),
            .bool("enabled", label: NSLocalizedString("启用代理", comment: ""), get: { configuration.wrappedValue.isEnabled }, set: { configuration.wrappedValue.isEnabled = $0 }),
            .string("type", label: NSLocalizedString("代理类型", comment: ""), allowedValues: ["http", "socks5"], get: { configuration.wrappedValue.type.rawValue }, set: {
                if let type = NetworkProxyType(rawValue: $0) { configuration.wrappedValue.type = type }
            }),
            .string("host", label: NSLocalizedString("代理地址", comment: ""), get: { configuration.wrappedValue.host }, set: { configuration.wrappedValue.host = $0 }),
            .integer("port", label: NSLocalizedString("端口", comment: ""), range: 1...65535, get: { configuration.wrappedValue.port }, set: { configuration.wrappedValue.port = $0 }),
            .writeOnlyString("username", label: NSLocalizedString("用户名（可选）", comment: ""), isConfigured: { !configuration.wrappedValue.username.isEmpty }, set: { configuration.wrappedValue.username = $0 }),
            .writeOnlyString("password", label: NSLocalizedString("密码（可选）", comment: ""), isConfigured: { !configuration.wrappedValue.password.isEmpty }, set: { configuration.wrappedValue.password = $0 })
        ]
    }
}
