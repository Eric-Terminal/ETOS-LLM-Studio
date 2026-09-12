import Foundation
import Testing
@testable import ETOSCore

struct TelemetryCallStackStructureTests {
    @Test("系统空归因栈与其他线程的有效栈分别保留转换计数")
    func emptyAttributedStackKeepsSourceEvidence() throws {
        let tree = try flattenTree(#"{"callStacks":[{"threadAttributed":false,"callStackRootFrames":[{"binaryName":"other","subFrames":[{"binaryName":"child"}]}]},{"threadAttributed":true,"callStackRootFrames":[]}]}"#)
        let stacks = try #require(tree["callStacks"] as? [[String: Any]])
        let counts = try #require(stacks.first?["_etos"] as? [String: Any])
        #expect(counts["source_stack_index"] as? Int == 1)
        #expect(counts["source_root_frames"] as? Int == 0)
        #expect(counts["decoded_root_frames"] as? Int == 0)
        #expect(counts["emitted_root_frames"] as? Int == 0)
        #expect(counts["emitted_frames"] as? Int == 0)
        #expect(stacks.first?["threadAttributed"] as? Bool == true)
        let other = try #require(stacks.last?["_etos"] as? [String: Any])
        #expect(other["source_stack_index"] as? Int == 0)
        #expect(other["source_root_frames"] as? Int == 1)
        #expect(other["emitted_root_frames"] as? Int == 1)
        #expect(other["emitted_frames"] as? Int == 2)
        let treeCounts = try #require(tree["_etos"] as? [String: Any])
        #expect(treeCounts["source_stacks"] as? Int == 2)
        #expect(treeCounts["emitted_stacks"] as? Int == 2)
    }

    @Test("根帧字段缺失或类型异常时不伪装成系统空栈", arguments: ["{}", #"{"callStackRootFrames":null}"#, #"{"callStackRootFrames":{}}"#])
    func missingRootsRemainUnknown(_ stack: String) throws {
        let tree = try flattenTree(#"{"callStacks":[\#(stack)]}"#)
        let stacks = try #require(tree["callStacks"] as? [[String: Any]])
        let counts = try #require(stacks.first?["_etos"] as? [String: Any])
        #expect(counts["source_root_frames"] is NSNull)
        #expect(counts["emitted_frames"] as? Int == 0)
    }

    @Test("原始根帧计数先于有限解码和最终帧预算，线程重排仍保留来源序号", arguments: [false, true])
    func truncationStagesHaveIndependentCounts(_ oversized: Bool) throws {
        let sourceCount = TelemetryPayloadFlattener.maximumCallStackFrames + 1
        let noise = Array(repeating: #"{"binaryName":"other"}"#, count: sourceCount).joined(separator: ",")
        let tree = try flattenTree(
            #"{"callStacks":[{"threadAttributed":false,"callStackRootFrames":[\#(noise)]},{"threadAttributed":true,"callStackRootFrames":[{"binaryName":"attributed"}]}]}"#,
            oversized: oversized
        )
        let stacks = try #require(tree["callStacks"] as? [[String: Any]])
        let attributed = try #require(stacks.first?["_etos"] as? [String: Any])
        #expect(attributed["source_stack_index"] as? Int == 1)
        #expect(attributed["source_root_frames"] as? Int == 1)
        #expect(attributed["emitted_frames"] as? Int == 1)
        let other = try #require(stacks.last?["_etos"] as? [String: Any])
        #expect(other["source_stack_index"] as? Int == 0)
        #expect(other["source_root_frames"] as? Int == sourceCount)
        #expect(other["decoded_root_frames"] as? Int == (oversized ? 4_096 : sourceCount))
        #expect(other["emitted_root_frames"] as? Int == 4_095)
        #expect(other["emitted_frames"] as? Int == 4_095)
        #expect(tree["truncated"] as? Bool == true)
    }

    private func flattenTree(_ tree: String, oversized: Bool = false) throws -> [String: Any] {
        let padding = oversized ? String(repeating: "x", count: TelemetryPayloadFlattener.maximumSourceBytes + 1) : ""
        let raw = Data(#"{"padding":"\#(padding)","crashDiagnostics":[{"callStackTree":\#(tree)}]}"#.utf8)
        let flattened = try TelemetryPayloadFlattener.flatten(raw)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(flattened)) as? [String: Any])
        let diagnostics = try #require(object["crashDiagnostics"] as? [[String: Any]])
        return try #require(diagnostics.first?["callStackTree"] as? [String: Any])
    }
}
