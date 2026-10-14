import ETOSCore
import SwiftUI

struct MacProviderProxyView: View {
    @Binding var proxy: NetworkProxyConfiguration?
    let providerID: UUID
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var appLock = AppLockManager.shared
    @State private var configuration: NetworkProxyConfiguration
    @State private var showsPassword = false
    @State private var visible = false
    private var available: Bool { isActive && workspace.canManageLocalModels && appLock.state != .locked }
    private var enabledOverride: Binding<Bool> {
        Binding(get: { proxy != nil }, set: { proxy = $0 ? configuration : nil })
    }

    init(proxy: Binding<NetworkProxyConfiguration?>, providerID: UUID, isActive: Bool) {
        _proxy = proxy; self.providerID = providerID; self.isActive = isActive
        _configuration = State(initialValue: proxy.wrappedValue ?? NetworkProxyConfiguration())
    }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "provider-proxy-\(providerID)", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac 代理设置使用说明", comment: ""), documentID: "network-proxy", isActive: available)
                Toggle(NSLocalizedString("独立代理", comment: ""), isOn: enabledOverride)
            } footer: {
                Text(NSLocalizedString("Mac 提供商代理优先级说明", comment: "")).font(.footnote).foregroundStyle(.secondary)
            }
            if proxy != nil {
                Section {
                    MacProxyFields(configuration: $configuration, showsPassword: $showsPassword)
                } footer: {
                    Text(NSLocalizedString("修改保留为草稿，点击保存后生效。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped).disabled(!available)
        .navigationTitle(NSLocalizedString("独立代理", comment: ""))
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-provider-proxy-\(providerID)-\(proxy != nil)-\(configuration.type.rawValue)"),
            title: NSLocalizedString("独立代理", comment: ""),
            documents: [GuideDocumentReference(id: "network-proxy", title: "Network Proxy")], isActive: visible && available,
            settings: [
                .bool("override_global", label: NSLocalizedString("独立代理", comment: ""), get: { proxy != nil }, set: { enabledOverride.wrappedValue = $0 }),
                .readOnly("save_in_provider_editor", label: NSLocalizedString("保存", comment: ""), value: { .bool(true) })
            ] + (proxy == nil ? [] : MacProxyGuideSettings.fields($configuration, showsPassword: showsPassword))
        )
        // 这里只修改提供商草稿；真正的校验和持久化仍由父编辑器保存负责。
        .onChange(of: configuration) { _, value in if proxy != nil { proxy = value } }
        .onAppear { visible = true }
        .onDisappear { visible = false; showsPassword = false }
        .onChange(of: available) { _, available in if !available { showsPassword = false } }
    }
}
