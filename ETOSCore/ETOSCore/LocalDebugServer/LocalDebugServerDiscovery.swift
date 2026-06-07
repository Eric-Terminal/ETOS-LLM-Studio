// ============================================================================
// LocalDebugServerDiscovery.swift
// ============================================================================
// ETOS LLM Studio
//
// 通过 Bonjour/mDNS 在局域网中发现电脑端调试工具。
// ============================================================================

import Combine
import Darwin
import Foundation

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

public final class LocalDebugServerDiscovery: NSObject, ObservableObject {
    public static let serviceType = "_etos-debug._tcp."
    public static let serviceTypeForInfoPlist = "_etos-debug._tcp"

    @Published public private(set) var discoveredServers: [LocalDebugDiscoveredServer] = []
    @Published public private(set) var isSearching = false
    @Published public private(set) var errorMessage: String?

    private var browser: NetServiceBrowser?
    private var resolvingServices: [String: NetService] = [:]

    public func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.start()
            }
            return
        }
        guard browser == nil else { return }

        let newBrowser = NetServiceBrowser()
        newBrowser.delegate = self
        newBrowser.schedule(in: .main, forMode: .common)
        newBrowser.searchForServices(ofType: Self.serviceType, inDomain: "local.")

        browser = newBrowser
        isSearching = true
        errorMessage = nil
    }

    public func restart() {
        stop()
        start()
    }

    public func stop() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.stop()
            }
            return
        }

        browser?.stop()
        browser?.remove(from: .main, forMode: .common)
        browser?.delegate = nil
        browser = nil

        for service in resolvingServices.values {
            service.stop()
            service.remove(from: .main, forMode: .common)
            service.delegate = nil
        }
        resolvingServices.removeAll()
        isSearching = false
    }

    private func handleFoundService(_ service: NetService) {
        let key = serviceIdentifier(service)
        resolvingServices[key] = service

        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 5)
    }

    private func handleRemovedService(_ service: NetService) {
        let key = serviceIdentifier(service)
        resolvingServices[key]?.stop()
        resolvingServices[key]?.remove(from: .main, forMode: .common)
        resolvingServices[key]?.delegate = nil
        resolvingServices.removeValue(forKey: key)
        discoveredServers.removeAll { $0.id == key }
    }

    private func upsertResolvedService(_ service: NetService) {
        let key = serviceIdentifier(service)
        guard let host = Self.preferredHost(for: service) else { return }

        let txt = NetService.dictionary(fromTXTRecord: service.txtRecordData() ?? Data())
        let httpPort = Self.intValue(in: txt, keys: ["http_port", "http"]) ?? positivePort(service.port) ?? 7654
        let webSocketPort = Self.intValue(in: txt, keys: ["ws_port", "ws"]) ?? 8765
        let proxyPort = Self.intValue(in: txt, keys: ["proxy_port", "proxy"]) ?? 8080
        let discovered = LocalDebugDiscoveredServer(
            id: key,
            name: service.name,
            host: host,
            httpPort: httpPort,
            webSocketPort: webSocketPort,
            proxyPort: proxyPort,
            lastSeenAt: Date()
        )

        if let index = discoveredServers.firstIndex(where: { $0.id == key }) {
            discoveredServers[index] = discovered
        } else {
            discoveredServers.append(discovered)
        }
        discoveredServers.sort {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func serviceIdentifier(_ service: NetService) -> String {
        "\(service.name)|\(service.type)|\(service.domain)"
    }

    private func positivePort(_ port: Int) -> Int? {
        port > 0 ? port : nil
    }

    private static func preferredHost(for service: NetService) -> String? {
        let addresses = (service.addresses ?? []).compactMap(ipAddress(from:))
        if let ipv4Address = addresses.first(where: { !$0.contains(":") }) {
            return ipv4Address
        }
        if let hostName = service.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
           !hostName.isEmpty {
            return hostName
        }
        return nil
    }

    private static func intValue(in txt: [String: Data], keys: [String]) -> Int? {
        for key in keys {
            guard let data = txt[key],
                  let raw = String(data: data, encoding: .utf8),
                  let value = Int(raw),
                  value > 0 else {
                continue
            }
            return value
        }
        return nil
    }

    private static func ipAddress(from data: Data) -> String? {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            let socketAddress = baseAddress.assumingMemoryBound(to: sockaddr.self)
            guard socketAddress.pointee.sa_family == sa_family_t(AF_INET) ||
                  socketAddress.pointee.sa_family == sa_family_t(AF_INET6) else {
                return nil
            }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress,
                socklen_t(data.count),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { return nil }
            return String(cString: hostBuffer)
        }
    }
}

extension LocalDebugServerDiscovery: NetServiceBrowserDelegate {
    public func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        isSearching = true
        errorMessage = nil
    }

    public func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        isSearching = false
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        isSearching = false
        errorMessage = String(
            format: NSLocalizedString("自动发现失败: %@", comment: ""),
            errorDict.description
        )
    }

    public func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        handleFoundService(service)
    }

    public func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        handleRemovedService(service)
    }
}

extension LocalDebugServerDiscovery: NetServiceDelegate {
    public func netServiceDidResolveAddress(_ sender: NetService) {
        upsertResolvedService(sender)
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        errorMessage = String(
            format: NSLocalizedString("自动发现解析失败: %@", comment: ""),
            errorDict.description
        )
    }
}
