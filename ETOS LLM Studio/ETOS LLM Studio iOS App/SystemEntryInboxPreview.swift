// ============================================================================
// SystemEntryInboxPreview.swift
// ETOS LLM Studio iOS App
// ============================================================================

import SwiftUI
import UniformTypeIdentifiers
import ETOSCore

extension Notification.Name {
    static let requestSystemEntryInboxPreview = Notification.Name("ios.requestSystemEntryInboxPreview")
    static let requestSystemEntryRoute = Notification.Name("ios.requestSystemEntryRoute")
}

enum SystemEntryRoute: Identifiable {
    case browser
    case terminal
    case memory(MemoryItem?)

    var id: String {
        switch self {
        case .browser: return "browser"
        case .terminal: return "terminal"
        case .memory(let memory): return "memory-\(memory?.id.uuidString ?? "library")"
        }
    }
}

struct SystemEntryInboxPayload: Identifiable, Sendable {
    let id: UUID
    let request: ETOSInboxRequest
    let directory: URL
}

enum SystemEntryInboxLoader {
    nonisolated static func load(requestID: UUID) throws -> SystemEntryInboxPayload {
        guard let layout = ETOSSharedStorageLayout.resolve() else { throw CocoaError(.fileNoSuchFile) }
        let directory = layout.inbox.appendingPathComponent(requestID.uuidString, isDirectory: true)
        let request = try ETOSInboxStore.load(requestID: requestID, layout: layout)
        return SystemEntryInboxPayload(id: requestID, request: request, directory: directory)
    }
}

struct SystemEntryInboxPreviewView: View {
    let payload: SystemEntryInboxPayload
    let onComplete: (UUID?) -> Void

    @State private var isSending = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(NSLocalizedString("处理方式", comment: "Inbox preview mode")) {
                        Text(payload.request.mode == .agent
                            ? NSLocalizedString("Agent", comment: "Agent mode")
                            : NSLocalizedString("Chat", comment: "Chat mode"))
                    }
                    LabeledContent(NSLocalizedString("目标", comment: "Inbox preview target")) {
                        Text(payload.request.preferredSessionID == nil
                            ? NSLocalizedString("新会话", comment: "New inbox session")
                            : NSLocalizedString("指定会话", comment: "Existing inbox session"))
                    }
                } footer: {
                    Text(NSLocalizedString("确认后才会把这些内容交给模型处理。", comment: "Inbox preview confirmation footer"))
                }

                Section(NSLocalizedString("内容", comment: "Inbox preview content")) {
                    ForEach(payload.request.items) { item in
                        Label(item.displayName, systemImage: icon(for: item.kind))
                    }
                }
            }
            .navigationTitle(NSLocalizedString("发送预览", comment: "Inbox preview title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "Cancel inbox preview")) { onComplete(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("发送", comment: "Send inbox content")) {
                        send()
                    }
                    .disabled(isSending)
                }
            }
            .overlay {
                if isSending { ProgressView().controlSize(.large) }
            }
            .alert(
                NSLocalizedString("发送失败", comment: "Inbox send error"),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button(NSLocalizedString("好", comment: "Dismiss inbox error"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func send() {
        isSending = true
        Task {
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try Self.preparePayload(payload: payload)
                }.value
                let coordinator = SystemEntryCoordinator.shared
                let result: ETOSSystemEntryTaskResult
                let preferredSessionID = payload.request.preferredSessionID
                let preferredSessionExists = await Task.detached(priority: .userInitiated) {
                    preferredSessionID.flatMap(Persistence.loadChatSession(id:)) != nil
                }.value
                if let sessionID = preferredSessionID, preferredSessionExists {
                    result = try await coordinator.continueTask(
                        sessionID: sessionID,
                        prompt: prepared.text,
                        requestID: payload.id,
                        kind: .shareExtension,
                        fileAttachments: prepared.files,
                        imageAttachments: prepared.images
                    )
                } else {
                    result = try await coordinator.startTask(
                        prompt: prepared.text,
                        mode: payload.request.mode == .agent ? .agent : .chat,
                        requestID: payload.id,
                        kind: .shareExtension,
                        fileAttachments: prepared.files,
                        imageAttachments: prepared.images
                    )
                }
                let directory = payload.directory
                try? await Task.detached(priority: .utility) {
                    try FileManager.default.removeItem(at: directory)
                }.value
                onComplete(result.sessionID)
            } catch {
                errorMessage = error.localizedDescription
                isSending = false
            }
        }
    }

    private nonisolated static func preparePayload(
        payload: SystemEntryInboxPayload
    ) throws -> (text: String, files: [FileAttachment], images: [ImageAttachment]) {
        var textParts: [String] = []
        var files: [FileAttachment] = []
        var images: [ImageAttachment] = []
        let rootPath = payload.directory.standardizedFileURL.path + "/"
        for item in payload.request.items {
            if let text = item.text { textParts.append(text) }
            guard let relative = item.relativeFilePath else { continue }
            let fileURL = payload.directory.deletingLastPathComponent()
                .appendingPathComponent(relative)
                .standardizedFileURL
            guard fileURL.path.hasPrefix(rootPath) else { throw CocoaError(.fileReadInvalidFileName) }
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? 0) <= ETOSSystemEntryConstants.maximumInboxRequestBytes else {
                throw CocoaError(.fileReadTooLarge)
            }
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            if item.kind == .image {
                images.append(ImageAttachment(data: data, mimeType: mime, fileName: item.displayName))
            } else {
                files.append(FileAttachment(data: data, mimeType: mime, fileName: item.displayName))
            }
        }
        let text = textParts.joined(separator: "\n\n")
        return (text, files, images)
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

enum SystemEntryURLRouter {
    @MainActor
    static func handle(_ url: URL) async -> Bool {
        guard url.scheme?.lowercased() == ETOSSystemEntryConstants.appURLScheme else { return false }
        let components = url.pathComponents.filter { $0 != "/" }
        switch url.host?.lowercased() {
        case "inbox":
            guard let rawID = components.first, let requestID = UUID(uuidString: rawID) else { return true }
            do {
                let payload = try await Task.detached(priority: .userInitiated) {
                    try SystemEntryInboxLoader.load(requestID: requestID)
                }.value
                NotificationCenter.default.post(name: .requestSystemEntryInboxPreview, object: payload)
            } catch {
                NotificationCenter.default.post(name: .newAPIProviderImportDidFail, object: error.localizedDescription)
            }
            return true
        case "open":
            guard let destination = components.first else { return false }
            if destination == "session", components.count > 1,
               let sessionID = UUID(uuidString: components[1]) {
                let session = await Task.detached(priority: .userInitiated) {
                    Persistence.loadChatSession(id: sessionID)
                }.value
                if let session {
                    ChatService.shared.setCurrentSession(session)
                    NotificationCenter.default.post(name: .requestSwitchToChatTab, object: nil)
                }
                return true
            } else if destination == "new-agent" {
                let session = ChatService.shared.createSavedSession(
                    name: NSLocalizedString("新的 Agent 任务", comment: "Widget Agent session title")
                )
                _ = await Task.detached(priority: .userInitiated) {
                    Persistence.saveLocalAgentMode(.agent, sessionID: session.id)
                }.value
                NotificationCenter.default.post(name: .requestSwitchToChatTab, object: nil)
                return true
            } else if destination == "daily-pulse" {
                NotificationCenter.default.post(name: .requestOpenDailyPulse, object: nil)
                return true
            } else if destination == "memory" {
                let memoryID = components.count > 1 ? UUID(uuidString: components[1]) : nil
                let memory: MemoryItem? = if let memoryID {
                    await Task.detached(priority: .userInitiated) {
                        await MemoryManager.shared.getAllMemories().first { $0.id == memoryID }
                    }.value
                } else {
                    nil
                }
                NotificationCenter.default.post(name: .requestSystemEntryRoute, object: SystemEntryRoute.memory(memory))
                return true
            } else if destination == "browser" {
                NotificationCenter.default.post(name: .requestSystemEntryRoute, object: SystemEntryRoute.browser)
                return true
            } else if destination == "terminal" {
                NotificationCenter.default.post(name: .requestSystemEntryRoute, object: SystemEntryRoute.terminal)
                return true
            } else if destination == "app" {
                // Web Clip 只需将 App 带到前台，保留用户上次停留的界面即可。
                return true
            }
            return false
        default:
            return false
        }
    }
}
