import Foundation
import Testing
@testable import ETOSCore

@Suite("安装级反馈身份与私密留言", .serialized)
struct DeviceMessageTests {
    @Test("设备留言可检索到反馈助手的专属说明")
    func deviceMessageGuideIsDiscoverable() async {
        let references = await GuideKnowledgeService().search("设备留言", limit: 1)
        #expect(references.first?.id == "feedback-assistant")
    }

    @Test("公开标识与服务端 SHA-256 向量一致，凭据不等于公开标识")
    func identityVector() {
        let identity = FeedbackDeviceIdentity(secret: Data(repeating: 0, count: 32))
        #expect(identity.deviceID == "66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925")
        #expect(identity.token == String(repeating: "00", count: 32))
        #expect(identity.deviceID != identity.token)
    }

    @Test("重启复用安装身份，删除本地数据后产生新身份")
    func installationLifetime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await FeedbackDeviceIdentityStore(directory: directory).identity()
        let second = try await FeedbackDeviceIdentityStore(directory: directory).identity()
        #expect(first.deviceID == second.deviceID)
        #expect(first.token == second.token)
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        try FileManager.default.removeItem(at: directory)
        let reinstalled = try await FeedbackDeviceIdentityStore(directory: directory).identity()
        #expect(reinstalled.deviceID != first.deviceID)
    }

    @Test("损坏凭据不会被静默覆盖")
    func corruptedIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("credential")
        let corrupted = Data("invalid".utf8)
        try corrupted.write(to: file)
        do {
            _ = try await FeedbackDeviceIdentityStore(directory: directory).identity()
            Issue.record("损坏凭据应拒绝读取")
        } catch {
            #expect(try Data(contentsOf: file) == corrupted)
        }
    }

    @Test("纯文字问题可以解码，反馈仅携带公开标识")
    func modelsKeepCredentialsOutOfFeedback() throws {
        let message = try JSONDecoder().decode(DeviceMessage.self, from: Data(DeviceMessageURLProtocol.definition.utf8))
        #expect(message.questions.count == 1)
        #expect(message.questions[0].options.isEmpty)
        #expect(message.questions[0].allowOther)
        let identity = FeedbackDeviceIdentity(secret: Data(repeating: 1, count: 32))
        let payload = SubmitIssuePayload(type: "suggestion", title: "建议标题", detail: "反馈详细描述", reproductionSteps: "", expectedBehavior: "", actualBehavior: "", extraContext: "", environment: FeedbackEnvironmentCollector.collectSnapshot(), logs: [], deviceID: identity.deviceID)
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        #expect(json.contains(identity.deviceID))
        #expect(!json.contains(identity.token))
    }

    @MainActor
    @Test("启动只检查一次，失败保留表单，成功结束并禁止本次启动再次弹出")
    func submissionLifecycle() async throws {
        DeviceMessageURLProtocol.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeviceMessageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let manager = DeviceMessageManager(session: session, baseURL: URL(string: "https://feedback.example.test")!, identityStore: FeedbackDeviceIdentityStore(directory: directory))
        await manager.checkMessages()
        await manager.checkMessages()
        #expect(DeviceMessageURLProtocol.capturedRequests().count == 1)
        #expect(manager.currentMessage == nil)
        #expect(manager.presentIfPossible())
        let answers = [DeviceMessageAnswer(questionID: "q", selectedOptionIDs: [], otherText: "私密回答")]
        DeviceMessageURLProtocol.setSubmissionStatus(503)
        await manager.respond(answers: answers)
        #expect(manager.currentMessage != nil)
        #expect(manager.errorMessage != nil)
        #expect(!manager.isClosed)
        DeviceMessageURLProtocol.setSubmissionStatus(200)
        await manager.respond(answers: answers)
        #expect(manager.currentMessage == nil)
        #expect(!manager.hasPendingMessage)
        #expect(!manager.presentIfPossible())
        for request in DeviceMessageURLProtocol.capturedRequests() {
            #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
            #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
            #expect(request.value(forHTTPHeaderField: "X-ELS-Device-ID")?.count == 64)
            #expect(request.url?.query == nil)
        }
    }

    @MainActor
    @Test("稍后处理只推迟本次启动，后台关闭会阻止再次提交")
    func postponeAndRemoteClose() async throws {
        DeviceMessageURLProtocol.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeviceMessageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let identity = FeedbackDeviceIdentityStore(directory: directory)
        let baseURL = URL(string: "https://feedback.example.test")!
        let manager = DeviceMessageManager(session: session, baseURL: baseURL, identityStore: identity)
        await manager.checkMessages()
        manager.presentIfPossible()
        manager.postpone()
        #expect(manager.hasPendingMessage)
        #expect(!manager.presentIfPossible())
        #expect(DeviceMessageURLProtocol.capturedRequests().count == 1)
        let nextLaunch = DeviceMessageManager(session: session, baseURL: baseURL, identityStore: identity)
        await nextLaunch.checkMessages()
        #expect(nextLaunch.presentIfPossible())
        DeviceMessageURLProtocol.setSubmissionStatus(410)
        await nextLaunch.respond(answers: [], dismissed: true)
        #expect(nextLaunch.isClosed)
        #expect(nextLaunch.currentMessage != nil)
        let count = DeviceMessageURLProtocol.capturedRequests().count
        await nextLaunch.respond(answers: [], dismissed: true)
        #expect(DeviceMessageURLProtocol.capturedRequests().count == count)
    }
}

private final class DeviceMessageURLProtocol: URLProtocol {
    static let definition = """
    {"key":"message-key","title":"开发者留言","description":"请补充信息","questions":[{"id":"q","question":"联系方式？","type":"single_select","options":null,"allow_other":true,"required":true}]}
    """
    private static let lock = NSLock()
    private nonisolated(unsafe) static var requests: [URLRequest] = []
    private nonisolated(unsafe) static var submissionStatus = 200

    static func reset() { lock.lock(); defer { lock.unlock() }; requests = []; submissionStatus = 200 }
    static func setSubmissionStatus(_ value: Int) { lock.lock(); defer { lock.unlock() }; submissionStatus = value }
    static func capturedRequests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let status = request.httpMethod == "GET" ? 200 : Self.submissionStatus
        Self.lock.unlock()
        let body = request.httpMethod == "GET" ? "[\(Self.definition)]" : "{\"success\":true}"
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Cache-Control": "no-store"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
