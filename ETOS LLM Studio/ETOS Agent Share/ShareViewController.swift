// ============================================================================
// ShareViewController.swift
// ETOS Agent Share
// ============================================================================

import ETOSCore
import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ETOSShareModel(extensionContext: extensionContext)
        let controller = UIHostingController(rootView: ETOSShareView(model: model))
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        controller.didMove(toParent: self)
    }
}

@MainActor
private final class ETOSShareModel: ObservableObject {
    @Published var mode: ETOSInboxMode = .agent
    @Published var selectedSessionID: UUID?
    @Published private(set) var items: [ETOSInboxItem] = []
    @Published private(set) var sessions: [ETOSSessionSummary] = []
    @Published private(set) var isLoading = true
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?

    private weak var extensionContext: NSExtensionContext?
    private var payloads: [(ETOSInboxItem, Data?)] = []

    init(extensionContext: NSExtensionContext?) {
        self.extensionContext = extensionContext
        Task { [weak self] in await self?.loadSessionSummaries() }
        Task { [weak self] in await self?.loadInput() }
    }

    func cancel() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            do {
                let requestID = try await Task.detached(priority: .userInitiated) { [payloads, mode, selectedSessionID] in
                    try Self.persist(payloads: payloads, mode: mode, selectedSessionID: selectedSessionID)
                }.value
                let url = ETOSSystemEntryURL.consumeInbox(requestID)
                _ = await extensionContext?.open(url)
                extensionContext?.completeRequest(returningItems: nil)
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }

    private func loadSessionSummaries() async {
        sessions = await Task.detached(priority: .utility) {
            guard let layout = ETOSSharedStorageLayout.resolve() else { return [] }
            let url = layout.runSnapshots.appendingPathComponent("widget.json")
            return (try? ETOSSharedFileStore.read(ETOSWidgetSnapshot.self, from: url))?.recentSessions ?? []
        }.value
    }

    private func loadInput() async {
        let providers = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] } ?? []
        var loaded: [(ETOSInboxItem, Data?)] = []
        for provider in providers.prefix(ETOSSystemEntryConstants.maximumInboxItemCount) {
            do {
                if let value = try await Self.load(provider: provider) { loaded.append(value) }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        payloads = loaded
        items = loaded.map(\.0)
        isLoading = false
    }

    private nonisolated static func load(provider: NSItemProvider) async throws -> (ETOSInboxItem, Data?)? {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let value = try await loadObject(provider, as: NSURL.self)
            let url = value as URL
            let text = url.absoluteString
            return (ETOSInboxItem(kind: .url, displayName: text, text: text, byteCount: text.utf8.count), nil)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let value = try await loadObject(provider, as: NSString.self)
            let text = value as String
            return (ETOSInboxItem(kind: .text, displayName: String(text.prefix(80)), text: text, byteCount: text.utf8.count), nil)
        }

        let type: UTType
        let kind: ETOSInboxItemKind
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            type = .image
            kind = .image
        } else if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
            type = .audio
            kind = .audio
        } else if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
            type = .data
            kind = .file
        } else {
            return nil
        }
        let data = try await loadData(provider, typeIdentifier: type.identifier)
        guard data.count <= ETOSSystemEntryConstants.maximumInboxRequestBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        let displayName = (provider.suggestedName?.isEmpty == false ? provider.suggestedName : nil)
            ?? NSLocalizedString("共享项目", comment: "Fallback shared item name")
        return (
            ETOSInboxItem(kind: kind, displayName: displayName, byteCount: data.count),
            data
        )
    }

    private nonisolated static func loadObject<T: NSItemProviderReading>(
        _ provider: NSItemProvider,
        as type: T.Type
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadObject(ofClass: type) { object, error in
                if let value = object as? T { continuation.resume(returning: value) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile)) }
            }
        }
    }

    private nonisolated static func loadData(_ provider: NSItemProvider, typeIdentifier: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile)) }
            }
        }
    }

    private nonisolated static func persist(
        payloads: [(ETOSInboxItem, Data?)],
        mode: ETOSInboxMode,
        selectedSessionID: UUID?
    ) throws -> UUID {
        try ETOSInboxStore.persist(
            payloads: payloads.map { ETOSInboxPayloadItem(item: $0.0, data: $0.1) },
            mode: mode,
            preferredSessionID: selectedSessionID
        ).id
    }
}

private struct ETOSShareView: View {
    @ObservedObject var model: ETOSShareModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(NSLocalizedString("处理方式", comment: "Share mode picker"), selection: $model.mode) {
                        Text(NSLocalizedString("Agent", comment: "Agent mode")).tag(ETOSInboxMode.agent)
                        Text(NSLocalizedString("Chat", comment: "Chat mode")).tag(ETOSInboxMode.chat)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(NSLocalizedString("内容会先进入 ETOS 预览，确认后才会发送。", comment: "Share preview behavior"))
                }

                if !model.sessions.isEmpty {
                    Section(NSLocalizedString("目标会话", comment: "Share target session section")) {
                        Picker(NSLocalizedString("会话", comment: "Share session picker"), selection: $model.selectedSessionID) {
                            Text(NSLocalizedString("新会话", comment: "Share creates a new session")).tag(UUID?.none)
                            ForEach(model.sessions) { session in
                                Text(session.name).tag(Optional(session.id))
                            }
                        }
                    }
                }

                Section(NSLocalizedString("共享内容", comment: "Shared content section")) {
                    if model.isLoading {
                        ProgressView(NSLocalizedString("正在读取…", comment: "Loading share input"))
                    } else if model.items.isEmpty {
                        Text(NSLocalizedString("没有可导入的内容。", comment: "No supported share content"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.items) { item in
                            Label(item.displayName, systemImage: icon(for: item.kind))
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("发送到 ETOS", comment: "Share extension title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "Cancel share"), action: model.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("继续", comment: "Continue share"), action: model.save)
                        .disabled(model.isLoading || model.isSaving || model.items.isEmpty)
                }
            }
            .alert(
                NSLocalizedString("无法保存", comment: "Share save error title"),
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                )
            ) {
                Button(NSLocalizedString("好", comment: "Dismiss share error"), role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private func icon(for kind: ETOSInboxItemKind) -> String {
        switch kind {
        case .text: return "text.alignleft"
        case .url: return "link"
        case .image: return "photo"
        case .audio: return "waveform"
        case .file: return "doc"
        }
    }
}
