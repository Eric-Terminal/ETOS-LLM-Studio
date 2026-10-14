import AppKit
import Combine
import ETOSCore
import Foundation
import UniformTypeIdentifiers

@MainActor
final class MacImageGalleryModel: ObservableObject {
    @Published private(set) var items: [MacImageGalleryItem] = []
    @Published private(set) var exporting = false
    @Published var error: String?
    private var loadTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var panel: NSSavePanel?

    func reload(service: ChatService, sessionID: UUID) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let prepared = await Task.detached(priority: .userInitiated) {
                MacImageGalleryItem.prepare(messages: service.messagesSnapshot(for: sessionID),
                    sessionID: sessionID, directory: Persistence.getImageDirectory())
            }.value
            guard !Task.isCancelled else { return }
            self?.items = prepared
        }
    }

    func clear() {
        loadTask?.cancel(); exportTask?.cancel(); panel?.cancel(nil)
        items = []
    }

    func export(_ item: MacImageGalleryItem) {
        guard !exporting else { return }
        exporting = true; error = nil
        exportTask = Task { [weak self] in
            guard let self else { return }
            defer { exporting = false; panel = nil }
            let panel = NSSavePanel()
            self.panel = panel
            panel.nameFieldStringValue = item.fileName
            if let type = UTType(filenameExtension: item.url.pathExtension) { panel.allowedContentTypes = [type] }
            let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
                panel.begin { continuation.resume(returning: $0) }
            }
            guard response == .OK, let destination = panel.url, !Task.isCancelled else { return }
            do {
                try await Task.detached(priority: .utility) {
                    let access = destination.startAccessingSecurityScopedResource()
                    defer { if access { destination.stopAccessingSecurityScopedResource() } }
                    try Data(contentsOf: item.url).write(to: destination, options: .atomic)
                }.value
            } catch { self.error = error.localizedDescription }
        }
    }

    deinit { loadTask?.cancel(); exportTask?.cancel() }
}
