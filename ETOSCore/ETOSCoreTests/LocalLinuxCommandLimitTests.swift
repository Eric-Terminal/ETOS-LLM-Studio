import Foundation
import Testing
@testable import ETOSCore

@Suite("Linux 命令桥接额度")
struct LocalLinuxCommandLimitTests {
    @Test("超时保留默认和关闭语义，并允许 SDK 上限以内的任务")
    func timeoutConversion() throws {
        #expect(try iSHAppleBridgeCommandSession.timeoutMilliseconds(nil) == 0)
        #expect(try iSHAppleBridgeCommandSession.timeoutMilliseconds(0) == UInt32.max)
        #expect(try iSHAppleBridgeCommandSession.timeoutMilliseconds(0.0001) == 1)
        #expect(try iSHAppleBridgeCommandSession.timeoutMilliseconds(300) == 300_000)
        #expect(try iSHAppleBridgeCommandSession.timeoutMilliseconds(3_600) == 3_600_000)
    }

    @Test("超时越界在调用原生桥前返回可读错误", arguments: [3_600.0001, 7_200, Double.greatestFiniteMagnitude])
    func rejectsOversizedTimeout(seconds: Double) {
        let request = LocalLinuxJobRequest(executable: "/bin/sh", arguments: ["/bin/sh"], timeoutSeconds: seconds)
        do {
            _ = try iSHAppleBridgeCommandSession.start(requestID: 1, request: request) { _, _, _ in }
            Issue.record("超限请求不应启动原生命令")
        } catch LocalLinuxRuntimeError.runtimeUnavailable(let message) {
            #expect(message.contains("3600"))
        } catch {
            Issue.record("应说明超时上限，而不是返回底层错误：\(error)")
        }
    }

    @Test("负数和非有限超时无效", arguments: [-1.0, Double.nan, Double.infinity, -Double.infinity])
    func rejectsInvalidTimeout(seconds: Double) {
        #expect(throws: LocalLinuxRuntimeError.self) {
            try iSHAppleBridgeCommandSession.timeoutMilliseconds(seconds)
        }
    }

    @Test("原始输出可关闭限制或使用最多 64 MiB 的有限额度")
    func outputLimitConversion() throws {
        #expect(try iSHAppleBridgeCommandSession.outputLimitBytes(nil) == UInt64.max)
        #expect(try iSHAppleBridgeCommandSession.outputLimitBytes(0) == UInt64.max)
        #expect(try iSHAppleBridgeCommandSession.outputLimitBytes(1) == 1)
        #expect(try iSHAppleBridgeCommandSession.outputLimitBytes(67_108_864) == 67_108_864)
    }

    @Test("输出额度越界在调用原生桥前返回可读错误", arguments: [UInt64(67_108_865), UInt64.max])
    func rejectsOversizedOutput(bytes: UInt64) {
        let request = LocalLinuxJobRequest(executable: "/bin/sh", arguments: ["/bin/sh"], outputLimitBytes: bytes)
        do {
            _ = try iSHAppleBridgeCommandSession.start(requestID: 1, request: request) { _, _, _ in }
            Issue.record("超限请求不应启动原生命令")
        } catch LocalLinuxRuntimeError.runtimeUnavailable(let message) {
            #expect(message.contains("67108864"))
        } catch {
            Issue.record("应说明输出上限，而不是返回底层错误：\(error)")
        }
    }

    @Test("模型可见的额度约束遵循平台实际执行后端")
    func toolSchemaLimits() throws {
        for tool in LocalLinuxToolDefinitions.all where tool.name != LocalLinuxToolName.process.rawValue {
            let data = try JSONEncoder().encode(tool.parameters)
            let schema = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let properties = try #require(schema["properties"] as? [String: [String: Any]])
            let timeout = try #require(properties["timeout_seconds"])
            let output = try #require(properties["output_limit_bytes"])
            #expect(timeout["minimum"] as? Int == 0)
            #expect(output["minimum"] as? Int == 0)
            #if os(macOS)
            #expect(timeout["maximum"] == nil)
            #expect(output["maximum"] == nil)
            #else
            #expect(timeout["maximum"] as? Int == 3_600)
            #expect(output["maximum"] as? Int == 67_108_864)
            #endif
        }
    }
}
