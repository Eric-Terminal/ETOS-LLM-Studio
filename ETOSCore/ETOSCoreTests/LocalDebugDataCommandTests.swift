import Foundation
import Testing
@testable import ETOSCore

@MainActor
@Suite("调试数据命令后台处理与失败保留")
struct LocalDebugDataCommandTests {
    @Test("数据操作离开主线程并保留 JSON 值类型")
    func dataOperationRunsOffMainThread() async {
        let server = LocalDebugServer()
        let result = await server.runDebugDataOperation {
            #expect(!Thread.isMainThread)
            return ["status": "ok", "count": 3, "flag": true, "empty": NSNull()]
        }
        #expect(result["count"] as? Int == 3 && result["flag"] as? Bool == true)
        #expect(result["empty"] is NSNull)
    }

    @Test("配置列表只使用传入快照，按值查询并正确排除本机配置及补默认值")
    func configListUsesSingleSnapshot() throws {
        let server = LocalDebugServer()
        let localKey = AppConfigKey.localDebugLastServerAddress
        let snapshot: [String: Any] = [localKey.rawValue: "fixture-address", AppConfigKey.maximumRequestRetries.rawValue: 7]
        let filtered = server.debugAppConfigList(["query": "fixture-address"], snapshot: snapshot)
        let settings = try #require(filtered["settings"] as? [[String: Any]])
        #expect(settings.count == 1 && settings.first?["key"] as? String == localKey.rawValue)
        let excluded = server.debugAppConfigList(["query": "fixture-address", "include_local_only": false], snapshot: snapshot)
        #expect(excluded["count"] as? Int == 0)
        let all = try #require(server.debugAppConfigList([:], snapshot: snapshot)["settings"] as? [[String: Any]])
        #expect(all.count == AppConfigKey.allCases.count)
        let retry = try #require(all.first { $0["key"] as? String == AppConfigKey.maximumRequestRetries.rawValue })
        #expect(retry["value"] as? Int == 7)
        let defaults = try #require(server.debugAppConfigList(["query": localKey.rawValue], snapshot: [:])["settings"] as? [[String: Any]])
        #expect(defaults.first?["value"] as? String == localKey.defaultValue.anyValue as? String)
    }

    @Test("后台日期编解码兼容整数、数字字符串和两种 ISO 日期")
    func webConsoleDateCompatibility() async throws {
        let server = LocalDebugServer()
        let result = await server.runDebugDataOperation {
            let values: [Any] = [1_700_000_000, "1700000000", "2023-11-14T22:13:20Z", "2023-11-14T22:13:20.000Z"]
            for value in values {
                do {
                    let decoded = try server.decodeWebConsoleObject(["date": value], as: DebugDateFixture.self)
                    #expect(decoded.date.timeIntervalSince1970 == 1_700_000_000)
                    let encoded = try server.encodeWebConsoleJSONObject(decoded)
                    let roundTrip = try server.decodeWebConsoleObject(encoded, as: DebugDateFixture.self)
                    #expect(roundTrip.date == decoded.date)
                } catch { Issue.record(error) }
            }
            return ["status": "ok"]
        }
        #expect(result["status"] as? String == "ok")
    }

    @Test("捕获保存失败保留请求，重复点击不重复写入且之后可以重试或忽略")
    func captureFailureCanBeRetried() async {
        let attempts = DebugInsertionAttempts()
        let server = LocalDebugServer { _, _ in
            #expect(!Thread.isMainThread)
            attempts.record()
            throw SessionInsertionError.storageUnavailable
        }
        _ = await server.handleOpenAICapture(["request": ["messages": [["role": "user", "content": "保留内容"]]]])
        let capturedID = server.pendingOpenAIRequest?.id
        server.resolvePendingOpenAIRequest(save: true)
        server.resolvePendingOpenAIRequest(save: true)
        await server.waitForPendingOperations()
        #expect(attempts.count == 1)
        #expect(server.errorMessage != nil && server.resolvingOpenAIRequestIDs.isEmpty)
        #expect(server.pendingOpenAIRequest?.id == capturedID && server.pendingOpenAIQueueCount == 1)

        let retry = await server.handleOpenAIQueueResolve(["save": true])
        #expect(retry["status"] as? String == "error" && attempts.count == 2)
        #expect(server.pendingOpenAIRequest?.id == capturedID)
        let ignored = await server.handleOpenAIQueueResolve(["save": false])
        #expect(ignored["status"] as? String == "ok")
        #expect(server.pendingOpenAIRequests.isEmpty && server.pendingOpenAIRequest == nil)
    }

    @Test("创建会话的写入错误作为命令错误返回，不发布成功结果")
    func sessionCreationFailureIsReported() async {
        let attempts = DebugInsertionAttempts()
        let server = LocalDebugServer { session, messages in
            #expect(!Thread.isMainThread)
            #expect(session.name == "新名称" && session.topicPrompt == "主题" && messages.isEmpty)
            attempts.record()
            throw SessionInsertionError.storageUnavailable
        }
        let response = await server.handleSessionCreate(["name": " 新名称 ", "topic_prompt": "主题"])
        #expect(response["status"] as? String == "error" && attempts.count == 1)
        #expect(response["session"] == nil && response["message"] as? String != nil)
    }
}

private struct DebugDateFixture: Codable { let date: Date }

private final class DebugInsertionAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}
