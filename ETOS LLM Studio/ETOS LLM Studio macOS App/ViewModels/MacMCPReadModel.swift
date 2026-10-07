import Combine
import ETOSCore
import Foundation

@MainActor
final class MacMCPReadModel: ObservableObject {
    @Published var parameters = "{}" { didSet { draftRevision = UUID() } }
    @Published var resourceID: String { didSet { draftRevision = UUID() } }
    private(set) var draftRevision = UUID()
    @Published private(set) var schema = ""
    @Published private(set) var output = ""
    @Published private(set) var error: String?
    @Published private(set) var isPrepared = false
    @Published private(set) var isReading = false
    let server: MCPServerConfiguration
    let target: MacMCPReadTarget
    private var operation: Task<Void, Never>?

    init(server: MCPServerConfiguration, target: MacMCPReadTarget) {
        self.server = server
        self.target = target
        resourceID = target.resourceID
    }

    func prepare() async {
        guard !isPrepared else { return }
        let target = target
        do {
            let prepared = try await Task.detached(priority: .userInitiated) { try target.prepare() }.value
            guard !Task.isCancelled else { return }
            schema = prepared.schema
            parameters = prepared.parameters
            isPrepared = true
        } catch { self.error = error.localizedDescription }
    }

    func read() {
        guard isPrepared, !isReading else { return }
        isReading = true
        error = nil
        output = ""
        let target = target
        let server = server
        let parameters = parameters
        let resourceID = resourceID
        operation = Task { [weak self] in
            defer { self?.isReading = false; self?.operation = nil }
            do {
                let request = try await Task.detached(priority: .userInitiated) {
                    try target.request(parameters: parameters, resourceID: resourceID)
                }.value
                try Task.checkCancellation()
                let result: String
                switch request {
                case .resource(let uri, let query):
                    let value = try await MCPManager.shared.readResourceAsync(on: server, resourceID: uri, query: query)
                    result = await Task.detached(priority: .userInitiated) { value.prettyPrinted() }.value
                case .prompt(let name, let arguments):
                    let value = try await MCPManager.shared.getPromptAsync(on: server, name: name, arguments: arguments)
                    result = try await Task.detached(priority: .userInitiated) {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                        return String(decoding: try encoder.encode(value), as: UTF8.self)
                    }.value
                }
                try Task.checkCancellation()
                self?.output = result
            } catch {
                if !Task.isCancelled { self?.error = error.localizedDescription }
            }
        }
    }

    func cancel() { operation?.cancel() }
}
