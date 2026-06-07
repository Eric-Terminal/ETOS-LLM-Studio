// ============================================================================
// ETOSCoreTestNetworkSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 ETOSCore 测试共用的网络模拟协议与重试流式失败场景。
// ============================================================================

import Foundation

final class MockURLProtocol: URLProtocol {
    static var mockResponses: [URL: Result<(HTTPURLResponse, Data), Error>] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let client = self.client, let url = request.url else {
            fatalError("Client or URL not found.")
        }

        if let mock = MockURLProtocol.mockResponses[url] {
            switch mock {
            case .success(let (response, data)):
                client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(self, didLoad: data)
                client.urlProtocolDidFinishLoading(self)
            case .failure(let error):
                client.urlProtocol(self, didFailWithError: error)
            }
        } else {
            let error = NSError(domain: "MockURLProtocol", code: -1, userInfo: [NSLocalizedDescriptionKey: "No mock response for \(url)"])
            client.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
    }
}

final class RetryStreamingFailureURLProtocol: URLProtocol {
    struct Scenario {
        let chunks: [Data]
        let error: Error
    }

    private static let lock = NSLock()
    private static var scenarios: [String: Scenario] = [:]

    private let stateLock = NSLock()
    private var isStopped = false

    static func reset() {
        lock.lock()
        scenarios.removeAll()
        lock.unlock()
    }

    static func register(marker: String, chunks: [String], errorMessage: String) {
        lock.lock()
        scenarios[marker] = Scenario(
            chunks: chunks.map { Data($0.utf8) },
            error: NSError(
                domain: "RetryStreamingFailureURLProtocol",
                code: -1005,
                userInfo: [NSLocalizedDescriptionKey: errorMessage]
            )
        )
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestURL = request.url,
              let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
              let marker = components.queryItems?.first(where: { $0.name == "marker" })?.value else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "RetryStreamingFailureURLProtocol",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "缺少 marker 参数"]
                )
            )
            return
        }

        Self.lock.lock()
        let scenario = Self.scenarios[marker]
        Self.lock.unlock()

        guard let scenario else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "RetryStreamingFailureURLProtocol",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "未找到 marker=\(marker) 的场景"]
                )
            )
            return
        }

        DispatchQueue.global().async {
            let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/plain; charset=utf-8"]
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

            for chunk in scenario.chunks {
                self.stateLock.lock()
                let stopped = self.isStopped
                self.stateLock.unlock()
                if stopped { return }
                self.client?.urlProtocol(self, didLoad: chunk)
                Thread.sleep(forTimeInterval: 0.02)
            }

            self.stateLock.lock()
            let stopped = self.isStopped
            self.stateLock.unlock()
            if stopped { return }

            self.client?.urlProtocol(self, didFailWithError: scenario.error)
        }
    }

    override func stopLoading() {
        stateLock.lock()
        isStopped = true
        stateLock.unlock()
    }
}
