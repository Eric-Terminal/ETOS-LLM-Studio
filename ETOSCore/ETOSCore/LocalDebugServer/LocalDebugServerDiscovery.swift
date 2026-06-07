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
    public let httpPort: Int
    public let webSocketPort: Int
    public let proxyPort: Int
    public let lastSeenAt: Date

    public var httpAddress: String {
        "\(host):\(httpPort)"
    }

    public var webSocketAddress: String {
        "\(host):\(webSocketPort):\(httpPort)"
    }

    public var proxyAddress: String {
        "\(host):\(proxyPort)"
    }

    public func connectionAddress(useHTTP: Bool) -> String {
        useHTTP ? httpAddress : webSocketAddress
    }
}

public final class LocalDebugServerDiscovery: ObservableObject {
    public static let serviceType = "_etos-debug._tcp."
    public static let serviceTypeForInfoPlist = "_etos-debug._tcp"

    @Published public private(set) var discoveredServers: [LocalDebugDiscoveredServer] = []
    @Published public private(set) var isSearching = false
    @Published public private(set) var errorMessage: String?

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.etos.local-debug.discovery")

    public init() {}

    public func start() {
        guard browser == nil else { return }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: Self.serviceTypeForInfoPlist,
            domain: "local."
        )
        let newBrowser = NWBrowser(for: descriptor, using: parameters)

        newBrowser.stateUpdateHandler = { [weak self] state in
            self?.handleBrowserState(state)
        }
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleBrowseResults(results)
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
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    private func handleBrowserState(_ state: NWBrowser.State) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch state {
            case .ready:
                self.isSearching = true
                self.errorMessage = nil
            case .failed(let error):
                self.isSearching = false
                self.errorMessage = String(
                    format: NSLocalizedString("自动发现失败: %@", comment: ""),
                    error.localizedDescription
                )
                self.browser?.cancel()
                self.browser = nil
            case .cancelled:
                self.isSearching = false
            case .waiting(let error):
                self.errorMessage = String(
                    format: NSLocalizedString("自动发现等待网络: %@", comment: ""),
                    error.localizedDescription
                )
            case .setup:
                self.isSearching = true
            @unknown default:
                self.isSearching = true
            }
        }
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        let servers = results.compactMap(Self.discoveredServer(from:))
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }

        DispatchQueue.main.async { [weak self] in
            self?.discoveredServers = servers
        }
    }

    private static func discoveredServer(from result: NWBrowser.Result) -> LocalDebugDiscoveredServer? {
        guard case let .service(name, type, domain, _) = result.endpoint else { return nil }

        let txt = txtRecordDictionary(from: result.metadata)
        guard let host = preferredHost(in: txt, name: name, domain: domain) else { return nil }
        let httpPort = intValue(in: txt, keys: ["http_port", "http"]) ?? 7654
        let webSocketPort = intValue(in: txt, keys: ["ws_port", "ws"]) ?? 8765
        let proxyPort = intValue(in: txt, keys: ["proxy_port", "proxy"]) ?? 8080

        return LocalDebugDiscoveredServer(
            id: "\(name)|\(type)|\(domain)",
            name: name,
            host: host,
            httpPort: httpPort,
            webSocketPort: webSocketPort,
            proxyPort: proxyPort,
            lastSeenAt: Date()
        )
    }

    private static func txtRecordDictionary(from metadata: NWBrowser.Result.Metadata) -> [String: String] {
        guard case let .bonjour(txtRecord) = metadata else { return [:] }
        return txtRecord.dictionary
    }

    private static func preferredHost(in txt: [String: String], name: String, domain: String) -> String? {
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

    private static func isUsableHost(_ host: String) -> Bool {
        !host.contains { $0.isWhitespace || $0 == "/" }
    }

    private static func intValue(in txt: [String: String], keys: [String]) -> Int? {
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
