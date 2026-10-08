import ETOSCore
import SwiftUI

@MainActor
struct MacConnectionSecurityView: View {
    let isActive: Bool
    @ObservedObject var model: MacConnectionSecurityModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var visible = false
    private var available: Bool { isActive && workspace.canManageLocalModels && !model.isSuspended }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "connection-exceptions", title: NSLocalizedString("Connection Exceptions", comment: ""),
                    details: NSLocalizedString("Mac 连接例外说明", comment: ""), documentID: "network-connection-exceptions", isActive: available)
                Text(NSLocalizedString("Manage connections you have explicitly allowed on this device.", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
                if model.isLoading { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
            }
            Section {
                Toggle(NSLocalizedString("Allow HTTP exceptions", comment: ""), isOn: Binding(
                    get: { model.presentation?.allowsHTTP ?? false },
                    set: { if available { model.setEnabled($0, kind: .http) } }))
                Toggle(NSLocalizedString("Allow certificate exceptions", comment: ""), isOn: Binding(
                    get: { model.presentation?.allowsCertificates ?? false },
                    set: { if available { model.setEnabled($0, kind: .certificate) } }))
            } footer: {
                Text(NSLocalizedString("Only remembered addresses are allowed. New addresses and new certificate problems still require confirmation. Turning a switch off also stops affected connections.", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .disabled(!model.canEdit)
            Section(NSLocalizedString("Remembered Addresses", comment: "")) {
                if let value = model.presentation {
                    if value.addresses.isEmpty {
                        Text(NSLocalizedString("No remembered exceptions", comment: "")).font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(value.addresses) { address in
                        NavigationLink {
                            MacConnectionExceptionView(id: address.id, isActive: isActive, model: model)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(address.origin)
                                Text(address.title).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("Connection Exceptions", comment: ""))
        .disabled(!available || model.isSaving)
        .onAppear { visible = true; if available { model.reload() } }
        .onDisappear { visible = false }
        .onChange(of: available) { _, active in if active { model.reload() } }
        .onChange(of: configuration.appLanguage) { _, _ in if available { model.reload() } }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-connection-exceptions-\(model.epoch)"),
            title: NSLocalizedString("Connection Exceptions", comment: ""), documents: Self.documents,
            isActive: available && visible && !model.isSaving, settings: [
                .readOnly("loading", label: NSLocalizedString("正在加载…", comment: ""), value: { .bool(model.isLoading) }),
                .readOnly("http_exceptions_enabled", label: NSLocalizedString("Allow HTTP exceptions", comment: ""),
                    value: { .bool(model.presentation?.allowsHTTP ?? false) }),
                .readOnly("certificate_exceptions_enabled", label: NSLocalizedString("Allow certificate exceptions", comment: ""),
                    value: { .bool(model.presentation?.allowsCertificates ?? false) }),
                .readOnly("exception_count", label: NSLocalizedString("Remembered Addresses", comment: ""),
                    value: { .int(model.presentation?.addresses.count ?? 0) })
            ])
    }

    static var documents: [GuideDocumentReference] {
        [GuideDocumentReference(id: "network-connection-exceptions", title: NSLocalizedString("Connection Exceptions", comment: ""))]
    }
}

@MainActor
private struct MacConnectionExceptionView: View {
    let id: UUID
    let isActive: Bool
    @ObservedObject var model: MacConnectionSecurityModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @State private var visible = false
    private var address: MacConnectionSecurityPresentation.Address? { model.presentation?.addressesByID[id] }
    private var active: Bool { isActive && visible && workspace.canManageLocalModels && !model.isSuspended }

    var body: some View {
        Form {
            if let address {
                Section {
                    LabeledContent(NSLocalizedString("Address", comment: ""), value: address.origin).textSelection(.enabled)
                    LabeledContent(NSLocalizedString("Exception type", comment: ""), value: address.title)
                    LabeledContent(NSLocalizedString("创建时间", comment: ""), value: address.createdAt)
                }
                Section {
                    Button(NSLocalizedString("Remove Exception", comment: ""), role: .destructive) {
                        guard active else { return }
                        model.remove(id: id)
                    }.disabled(!model.canEdit)
                } footer: {
                    Text(NSLocalizedString("Removing this exception stops connections to this address and requires confirmation next time.", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else if model.isLoading {
                ProgressView(NSLocalizedString("正在加载…", comment: ""))
            } else {
                Text(NSLocalizedString("This connection exception is no longer saved.", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("Connection Exception", comment: ""))
        .disabled(!active || model.isSaving)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-connection-exception-\(id)-\(model.epoch)"),
            title: NSLocalizedString("Connection Exception", comment: ""), documents: MacConnectionSecurityView.documents,
            isActive: active && !model.isSaving, settings: [
                .readOnly("exists", label: NSLocalizedString("Remembered Addresses", comment: ""), value: { .bool(address != nil) }),
                .readOnly("address", label: NSLocalizedString("Address", comment: ""), value: { .string(address?.origin ?? "") }),
                .readOnly("exception_type", label: NSLocalizedString("Exception type", comment: ""), value: { .string(address?.kind.rawValue ?? "") }),
                .readOnly("created_at", label: NSLocalizedString("创建时间", comment: ""), value: { .string(address?.createdAt ?? "") })
            ])
    }
}
