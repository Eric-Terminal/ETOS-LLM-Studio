import Foundation
import Testing
@testable import ETOSCore

@Suite("同步工具调用进度合并")
struct SyncToolCallMergeTests {
    @Test("同一调用的终态双向合并且不会退回待执行", arguments: [
        InternalToolCallResultDisposition.completed, .failed, .rejected
    ])
    func terminalResultIsPreserved(disposition: InternalToolCallResultDisposition) throws {
        let pending = InternalToolCall(id: "call-1", toolName: "search", arguments: "{}")
        var finished = pending
        finished.result = "工具返回内容"
        finished.resultDisposition = disposition

        let forward = try #require(SyncEngine.mergeToolCalls([pending], [finished]))
        let backward = try #require(SyncEngine.mergeToolCalls([finished], [pending]))
        #expect(forward.value == [finished])
        #expect(forward.changed)
        #expect(backward.value == [finished])
        #expect(!backward.changed)
    }

    @Test("流式参数、签名补齐与新增调用保留完整进度")
    func streamingArgumentsAndAppendedCallsMerge() throws {
        let partial = InternalToolCall(id: "call-1", toolName: "search", arguments: "{\"query\":")
        let complete = InternalToolCall(
            id: partial.id,
            toolName: partial.toolName,
            arguments: "{\"query\":\"ELS\"}",
            providerSpecificFields: ["thought_signature": .string("signature")]
        )
        let next = InternalToolCall(id: "call-2", toolName: "fetch", arguments: "{}")

        let forward = try #require(SyncEngine.mergeToolCalls([partial], [complete, next]))
        let backward = try #require(SyncEngine.mergeToolCalls([complete, next], [partial]))
        #expect(forward.value == [complete, next])
        #expect(backward.value == [complete, next])
        #expect(!backward.changed)
    }

    @Test("不同调用、参数、结果、终态与签名仍然保留冲突")
    func incompatibleExecutionsRemainConflicts() {
        let original = InternalToolCall(
            id: "call-1", toolName: "search", arguments: "{\"query\":\"ELS\"}",
            result: "结果", resultDisposition: .completed,
            providerSpecificFields: ["thought_signature": .string("original")]
        )
        let conflictingCalls = [
            InternalToolCall(id: "call-2", toolName: original.toolName, arguments: original.arguments),
            InternalToolCall(id: original.id, toolName: "fetch", arguments: original.arguments),
            InternalToolCall(id: original.id, toolName: original.toolName, arguments: "{\"query\":\"其他\"}"),
            InternalToolCall(id: original.id, toolName: original.toolName, arguments: original.arguments, result: "不同结果"),
            InternalToolCall(id: original.id, toolName: original.toolName, arguments: original.arguments, resultDisposition: .failed),
            InternalToolCall(
                id: original.id, toolName: original.toolName, arguments: original.arguments,
                providerSpecificFields: ["thought_signature": .string("different")]
            )
        ]
        for conflicting in conflictingCalls {
            #expect(SyncEngine.mergeToolCalls([original], [conflicting]) == nil)
            #expect(SyncEngine.mergeToolCalls([conflicting], [original]) == nil)
        }
    }
}
