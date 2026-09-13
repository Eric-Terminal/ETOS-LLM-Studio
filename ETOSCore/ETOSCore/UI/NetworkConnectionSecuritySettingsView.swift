import Combine
import SwiftUI

@MainActor
private final class NetworkConnectionSecuritySettingsModel: ObservableObject {
    @Published var state = NetworkConnectionSecurityState()
    @Published var isLoaded = false
    @Published var error: String?
    @Published var isSaving = false
    @Published var exceptionIDs: Set<UUID> = []

    func reload() async {
        let loaded = await Task.detached {
            let state = await NetworkConnectionSecurity.shared.snapshot()
            return (state, Set(state.exceptions.map(\.id)))
        }.value
        state = loaded.0
        exceptionIDs = loaded.1
        isLoaded = true
    }

    func setEnabled(_ enabled: Bool, kind: NetworkConnectionExceptionKind) {
        guard !isSaving else { return }
        isSaving = true
        Task { [weak self] in
            do {
                try await NetworkConnectionSecurity.shared.setEnabled(enabled, for: kind)
                await self?.reload()
            } catch { self?.error = error.localizedDescription }
            self?.isSaving = false
        }
    }

    func remove(_ exception: NetworkConnectionException) {
        guard !isSaving else { return }
        isSaving = true
        Task { [weak self] in
            do {
                try await NetworkConnectionSecurity.shared.removeException(id: exception.id)
                await self?.reload()
            } catch { self?.error = error.localizedDescription }
            self?.isSaving = false
        }
    }
}

@MainActor
public struct NetworkConnectionSecuritySettingsView: View {
    @StateObject private var model = NetworkConnectionSecuritySettingsModel()
    @State private var showsIntroduction = false
    private let decoratePage: (AnyView) -> AnyView

    public init(decoratePage: @escaping (AnyView) -> AnyView = { $0 }) {
        self.decoratePage = decoratePage
    }

    public var body: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    Text(NSLocalizedString("Connection Exceptions", comment: "连接例外页面标题"))
                        .font(.headline)
                    Text(
                        NSLocalizedString(
                            "Manage connections you have explicitly allowed on this device.", comment: "连接例外介绍摘要")
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                    Button(NSLocalizedString("Learn More…", comment: "连接例外详细说明入口")) { showsIntroduction = true }
                        .buttonStyle(.plain)
                }
            }
            Section {
                Toggle(
                    NSLocalizedString("Allow HTTP exceptions", comment: "HTTP 例外总开关"),
                    isOn: Binding(
                        get: { model.state.allowsHTTPExceptions },
                        set: { model.setEnabled($0, kind: .http) }
                    ))
                Toggle(
                    NSLocalizedString("Allow certificate exceptions", comment: "证书例外总开关"),
                    isOn: Binding(
                        get: { model.state.allowsCertificateExceptions },
                        set: { model.setEnabled($0, kind: .certificate) }
                    ))
            } footer: {
                Text(
                    NSLocalizedString(
                        "Only remembered addresses are allowed. New addresses and new certificate problems still require confirmation. Turning a switch off also stops affected connections.",
                        comment: "网络例外开关说明")
                )
                .font(.footnote).foregroundStyle(.secondary)
            }
            .disabled(!model.isLoaded || model.isSaving)

            Section {
                if model.state.exceptions.isEmpty {
                    Text(NSLocalizedString("No remembered exceptions", comment: "网络例外空状态"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(model.state.exceptions) { exception in
                    NavigationLink {
                        exceptionDetails(exception)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(exception.origin.displayName)
                            Text(exception.kind.title).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("Remembered Addresses", comment: "已记住的网络地址分组"))
            }
        }
        .navigationTitle(NSLocalizedString("Connection Exceptions", comment: "连接例外页面标题"))
        .task { await model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .networkConnectionSecurityDidChange)) { _ in
            Task { await model.reload() }
        }
        .alert(
            NSLocalizedString("Unable to update exceptions", comment: "网络例外更新失败标题"),
            isPresented: Binding(
                get: { model.error != nil }, set: { if !$0 { model.error = nil } }
            )
        ) {
            Button(NSLocalizedString("OK", comment: "确认按钮"), role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
        .sheet(isPresented: $showsIntroduction) {
            NavigationStack {
                ScrollView {
                    Text(
                        NSLocalizedString(
                            "Connection exceptions help you connect to self-hosted services. HTTP sends data without encryption. HTTPS with a certificate exception remains encrypted, but the server's identity cannot be verified normally.\n\nWhen a connection is blocked, choose Continue Once or Continue and Remember. Remembered choices are shared by the app's API, model, MCP and file-transfer requests on this device. A new address, port, certificate or validation problem can require another confirmation.\n\nSwitches control remembered exceptions; they do not approve every server. Remove an address to revoke its exception. App-owned services always require normal HTTPS verification. These settings do not change the certificate trust of iOS or watchOS, Safari, or programs running inside the local Linux environment.",
                            comment: "连接例外详细教程")
                    )
                    .font(.footnote).foregroundStyle(.secondary).padding()
                }
                .navigationTitle(NSLocalizedString("Connection Exceptions", comment: "连接例外页面标题"))
                .guideSettingsPageContext(
                    id: "network-connection-exceptions-introduction",
                    title: NSLocalizedString("Connection Exceptions", comment: "连接例外页面标题"),
                    documents: Self.documents, settings: []
                )
                .modifier(NetworkConnectionPageDecorator(decorate: decoratePage))
            }
        }
        // 信任决策必须由用户操作原生控件，向导仅解释状态，不提供放行执行器。
        .guideSettingsPageContext(
            id: "network-connection-exceptions", title: NSLocalizedString("Connection Exceptions", comment: "连接例外页面标题"),
            documents: Self.documents,
            settings: [
                .readOnly(
                    "http_exceptions_enabled", label: NSLocalizedString("Allow HTTP exceptions", comment: "HTTP 例外总开关"),
                    value: { .bool(model.state.allowsHTTPExceptions) }),
                .readOnly(
                    "certificate_exceptions_enabled",
                    label: NSLocalizedString("Allow certificate exceptions", comment: "证书例外总开关"),
                    value: { .bool(model.state.allowsCertificateExceptions) }),
                .readOnly(
                    "exception_count", label: NSLocalizedString("Remembered Addresses", comment: "已记住的网络地址分组"),
                    value: { .int(model.state.exceptions.count) }),
            ]
        )
        .modifier(NetworkConnectionPageDecorator(decorate: decoratePage))
    }

    private static var documents: [GuideDocumentReference] {
        [
            GuideDocumentReference(
                id: "network-connection-exceptions",
                title: NSLocalizedString("Connection Exceptions", comment: "连接例外页面标题"))
        ]
    }

    private func exceptionDetails(_ exception: NetworkConnectionException) -> some View {
        Form {
            Section {
                Text(exception.origin.displayName)
                Text(exception.kind.title).font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button(NSLocalizedString("Remove Exception", comment: "撤销网络例外按钮"), role: .destructive) {
                    model.remove(exception)
                }.disabled(model.isSaving || !model.exceptionIDs.contains(exception.id))
            } footer: {
                Text(
                    NSLocalizedString(
                        "Removing this exception stops connections to this address and requires confirmation next time.",
                        comment: "撤销网络例外说明")
                )
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("Connection Exception", comment: "连接例外详情标题"))
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "network-connection-exception-\(exception.id.uuidString)"),
            title: NSLocalizedString("Connection Exception", comment: "连接例外详情标题"), documents: Self.documents,
            settings: [
                .readOnly(
                    "address", label: NSLocalizedString("Address", comment: "网络地址字段"),
                    value: { .string(exception.origin.displayName) }),
                .readOnly(
                    "exception_type", label: NSLocalizedString("Exception type", comment: "网络例外类型字段"),
                    value: { .string(exception.kind.rawValue) }),
            ]
        )
        .modifier(NetworkConnectionPageDecorator(decorate: decoratePage))
    }
}

@MainActor
private struct NetworkConnectionPageDecorator: ViewModifier {
    let decorate: (AnyView) -> AnyView
    func body(content: Content) -> some View { decorate(AnyView(content)) }
}
