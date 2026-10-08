// ============================================================================
// LocalDebugServerDiscovery.swift
// ============================================================================
// ETOS LLM Studio
//
// 通过 Bonjour/mDNS 在局域网中发现电脑端调试工具。
// ============================================================================

import Combine
import Foundation
import Network

public struct LocalDebugDiscoveredServer: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let host: String
    public let port: Int
    public let lastSeenAt: Date

    public var address: String {
        "\(host):\(port)"
    }

    public func connectionAddress(useHTTP _: Bool) -> String {
        address
    }
}

@MainActor
public final class LocalDebugServerDiscovery: ObservableObject {
    nonisolated public static let serviceType = "_etos-debug._tcp."
    nonisolated public static let serviceTypeForInfoPlist = "_etos-debug._tcp"

    @Published public private(set) var discoveredServers: [LocalDebugDiscoveredServer] = []
    @Published public private(set) var isSearching = false
    @Published public private(set) var errorMessage: String?

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.etos.local-debug.discovery")
    private(set) var generation = UUID()

    public init() {}

    public func start() {
        guard browser == nil else { return }
        generation = UUID()
        let token = generation

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: Self.serviceTypeForInfoPlist,
            domain: "local."
        )
        let newBrowser = NWBrowser(for: descriptor, using: parameters)

        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in self?.handleBrowserState(state, generation: token) }
        }
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            // TXT 解析和排序在浏览器队列完成，主执行器只接收当前扫描的展示数据。
            let servers = results.compactMap(Self.discoveredServer(from:)).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            Task { @MainActor [weak self] in self?.handleBrowseResults(servers, generation: token) }
        }

        browser = newBrowser
        isSearching = true
        errorMessage = nil
        newBrowser.start(queue: queue)
    }

    public func restart() {
        stop()
        start()
    }

    public func stop() {
        generation = UUID()
        browser?.cancel()
        browser = nil
        isSearching = false
        discoveredServers = []
        errorMessage = nil
    }

    func handleBrowserState(_ state: NWBrowser.State, generation token: UUID) {
        guard generation == token else { return }
        switch state {
        case .ready:
            isSearching = true
            errorMessage = nil
        case .failed(let error):
            isSearching = false
            errorMessage = String(format: NSLocalizedString("自动发现失败: %@", comment: ""), error.localizedDescription)
            browser?.cancel()
            browser = nil
            generation = UUID()
            discoveredServers = []
        case .cancelled:
            isSearching = false
            browser = nil
            generation = UUID()
            discoveredServers = []
        case .waiting(let error):
            errorMessage = String(format: NSLocalizedString("自动发现等待网络: %@", comment: ""), error.localizedDescription)
        case .setup:
            isSearching = true
        @unknown default:
            isSearching = true
        }
    }

    func handleBrowseResults(_ servers: [LocalDebugDiscoveredServer], generation token: UUID) {
        guard generation == token else { return }
        discoveredServers = servers
    }

    nonisolated private static func discoveredServer(from result: NWBrowser.Result) -> LocalDebugDiscoveredServer? {
        guard case let .service(name, type, domain, _) = result.endpoint else { return nil }

        let txt = txtRecordDictionary(from: result.metadata)
        guard let host = preferredHost(in: txt, name: name, domain: domain) else { return nil }
        let port = intValue(in: txt, keys: ["port", "http_port", "http"]) ?? 7654

        return LocalDebugDiscoveredServer(
            id: "\(name)|\(type)|\(domain)",
            name: name,
            host: host,
            port: port,
            lastSeenAt: Date()
        )
    }

    nonisolated private static func txtRecordDictionary(from metadata: NWBrowser.Result.Metadata) -> [String: String] {
        guard case let .bonjour(txtRecord) = metadata else { return [:] }
        return txtRecord.dictionary
    }

    nonisolated private static func preferredHost(in txt: [String: String], name: String, domain: String) -> String? {
        for key in ["host", "hostname", "address", "ip"] {
            if let value = txt[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            }
        }

        let trimmedDomain = domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if trimmedDomain.isEmpty {
            let host = "\(name).local"
            return isUsableHost(host) ? host : nil
        }
        if name.hasSuffix(".\(trimmedDomain)") {
            return isUsableHost(name) ? name : nil
        }
        let host = "\(name).\(trimmedDomain)"
        return isUsableHost(host) ? host : nil
    }

    nonisolated private static func isUsableHost(_ host: String) -> Bool {
        !host.contains { $0.isWhitespace || $0 == "/" }
    }

    nonisolated private static func intValue(in txt: [String: String], keys: [String]) -> Int? {
        for key in keys {
            guard let raw = txt[key],
                  let value = Int(raw),
                  value > 0 else {
                continue
            }
            return value
        }
        return nil
    }
}
