import SwiftUI
import Foundation
import ETOSCore

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
                header: Text(NSLocalizedString("全局代理", comment: "")),
                footer: Text(globalFooterText)
            ) {
                Toggle(NSLocalizedString("启用全局代理", comment: ""), isOn: $proxyStore.isEnabled)

                if proxyStore.isEnabled {
                    Picker(NSLocalizedString("代理类型", comment: ""), selection: $proxyStore.type) {
                        Text(NSLocalizedString("HTTP / HTTPS", comment: "HTTP proxy type")).tag(NetworkProxyType.http)
                        Text(NSLocalizedString("SOCKS5", comment: "SOCKS5 proxy type")).tag(NetworkProxyType.socks5)
                    }

                    TextField(NSLocalizedString("代理地址", comment: ""), text: $proxyStore.host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField(NSLocalizedString("端口", comment: ""), value: $proxyStore.port, formatter: numberFormatter)
                        .keyboardType(.numberPad)
                        .onChange(of: proxyStore.port) { _, newValue in
                            let clamped = max(1, min(65535, newValue))
                            if clamped != newValue {
                                proxyStore.port = clamped
                            }
                        }

                    TextField(NSLocalizedString("用户名（可选）", comment: ""), text: $proxyStore.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Group {
                        if showPassword {
                            TextField(NSLocalizedString("密码（可选）", comment: ""), text: $proxyStore.password)
                        } else {
                            SecureField(NSLocalizedString("密码（可选）", comment: ""), text: $proxyStore.password)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Toggle(NSLocalizedString("显示代理密码", comment: ""), isOn: $showPassword)
                }
            }

            Section(NSLocalizedString("优先级说明", comment: "")) {
                Text(NSLocalizedString("提供商设置中开启“独立代理”后，将优先使用提供商代理；未开启时才使用这里的全局代理。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("全局代理设置", comment: ""))
        .guidePageContext(
            descriptor: GuidePageDescriptor(
                id: "global-proxy",
                title: NSLocalizedString("全局代理设置", comment: "全局代理向导上下文标题"),
                documents: [GuideDocumentReference(id: "network-proxy", title: "Global Proxy")],
                tools: [GuidePageTool(definition: GuideToolCatalog.updateGlobalProxy, access: .proposeChange)]
            ),
            snapshot: proxyGuideSnapshot,
            buildProposal: buildProxyGuideProposal,
            execute: executeProxyGuideProposal
        )
    }

    private func proxyGuideSnapshot() async -> GuidePageSnapshot {
        GuidePageSnapshot(fields: [
            "enabled": GuideSnapshotField(
                label: NSLocalizedString("启用全局代理", comment: "全局代理向导快照字段"),
                value: .bool(proxyStore.isEnabled)
            ),
            "type": GuideSnapshotField(
                label: NSLocalizedString("代理类型", comment: "全局代理向导快照字段"),
                value: .string(proxyStore.type.rawValue)
            ),
            "host": GuideSnapshotField(
                label: NSLocalizedString("代理地址", comment: "全局代理向导快照字段"),
                value: .string(proxyStore.host)
            ),
            "port": GuideSnapshotField(
                label: NSLocalizedString("端口", comment: "全局代理向导快照字段"),
                value: .int(proxyStore.port)
            ),
            "username": GuideSnapshotField(
                label: NSLocalizedString("用户名", comment: "全局代理向导快照字段"),
                value: .string(proxyStore.username)
            ),
            "password": GuideSnapshotField(
                label: NSLocalizedString("密码", comment: "全局代理向导快照字段"),
                value: .string(proxyStore.password),
                access: .writeOnly
            )
        ])
    }

    private func buildProxyGuideProposal(
        call: InternalToolCall,
        snapshot: GuidePageSnapshot
    ) throws -> GuideActionProposal {
        guard call.toolName == GuideToolCatalog.updateGlobalProxy.name else {
            throw GuideError.unsupportedTool(call.toolName)
        }
        let arguments = try GuideToolArguments.decode(call.arguments)
        if let type = try GuideToolArguments.optionalString("type", in: arguments),
           NetworkProxyType(rawValue: type) == nil {
            throw GuideError.invalidToolArguments
        }
        if let port = try GuideToolArguments.optionalInteger("port", in: arguments),
           !(1...65535).contains(port) {
            throw GuideError.invalidToolArguments
        }
        let labels: [String: String] = [
            "enabled": NSLocalizedString("启用全局代理", comment: "全局代理向导修改字段"),
            "type": NSLocalizedString("代理类型", comment: "全局代理向导修改字段"),
            "host": NSLocalizedString("代理地址", comment: "全局代理向导修改字段"),
            "port": NSLocalizedString("端口", comment: "全局代理向导修改字段"),
            "username": NSLocalizedString("用户名", comment: "全局代理向导修改字段"),
            "password": NSLocalizedString("密码", comment: "全局代理向导修改字段")
        ]
        try GuideToolArguments.requireOnlyKeys(Set(labels.keys), in: arguments)
        _ = try GuideToolArguments.optionalBool("enabled", in: arguments)
        _ = try GuideToolArguments.optionalString("host", in: arguments)
        _ = try GuideToolArguments.optionalString("username", in: arguments)
        _ = try GuideToolArguments.optionalString("password", in: arguments)
        let mutations = labels.compactMap { key, label -> GuideSettingMutation? in
            guard let newValue = arguments[key] else { return nil }
            let sensitive = key == "password"
            let oldValue = snapshot.fields[key]?.value
            guard sensitive || oldValue != newValue else { return nil }
            return GuideSettingMutation(
                path: key,
                label: label,
                oldValue: oldValue,
                newValue: newValue,
                isSensitive: sensitive
            )
        }
        guard !mutations.isEmpty else { throw GuideError.invalidToolArguments }
        return GuideActionProposal(
            pageID: "global-proxy",
            toolCallID: call.id,
            toolName: call.toolName,
            summary: NSLocalizedString("修改全局代理配置", comment: "全局代理向导提案摘要"),
            mutations: mutations,
            arguments: arguments
        )
    }

    private func executeProxyGuideProposal(_ proposal: GuideActionProposal) async throws -> GuideActionExecution {
        guard proposal.toolName == GuideToolCatalog.updateGlobalProxy.name else {
            throw GuideError.unsupportedTool(proposal.toolName)
        }
        let oldConfiguration = proxyStore.snapshot
        var updated = oldConfiguration
        if let value = try GuideToolArguments.optionalBool("enabled", in: proposal.arguments) { updated.isEnabled = value }
        if let value = try GuideToolArguments.optionalString("type", in: proposal.arguments),
           let type = NetworkProxyType(rawValue: value) { updated.type = type }
        if let value = try GuideToolArguments.optionalString("host", in: proposal.arguments) { updated.host = value }
        if let value = try GuideToolArguments.optionalInteger("port", in: proposal.arguments) { updated.port = value }
        if let value = try GuideToolArguments.optionalString("username", in: proposal.arguments) { updated.username = value }
        if let value = try GuideToolArguments.optionalString("password", in: proposal.arguments) { updated.password = value }
        guard !updated.isEnabled || updated.normalizedIfEnabled != nil else { throw GuideError.invalidToolArguments }

        let oldArguments = proxyGuideArguments(from: oldConfiguration, keys: proposal.arguments.keys)
        proxyStore.update(with: updated)
        let undoSnapshot = await proxyGuideSnapshot()
        let undoCall = InternalToolCall(
            id: UUID().uuidString,
            toolName: proposal.toolName,
            arguments: GuideToolArguments.encodedResult(.dictionary(oldArguments))
        )
        return GuideActionExecution(
            message: NSLocalizedString("已保存全局代理配置。", comment: "全局代理向导执行结果"),
            undoProposal: try buildProxyGuideProposal(call: undoCall, snapshot: undoSnapshot)
        )
    }

    private func proxyGuideArguments(
        from configuration: NetworkProxyConfiguration,
        keys: Dictionary<String, JSONValue>.Keys
    ) -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for key in keys {
            switch key {
            case "enabled": values[key] = .bool(configuration.isEnabled)
            case "type": values[key] = .string(configuration.type.rawValue)
            case "host": values[key] = .string(configuration.host)
            case "port": values[key] = .int(configuration.port)
            case "username": values[key] = .string(configuration.username)
            case "password": values[key] = .string(configuration.password)
            default: break
            }
        }
        return values
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
