import Foundation
import Testing
@testable import ETOSCore

struct ChatResponseAttemptIndexTests {
    @Test("会话索引与单条查询一致，覆盖连续用户输入、工具、孤立回复及失效选择")
    func indexPreservesVersionSemantics() {
        for selection in [0, 1, 2] {
            let messages = fixture(selection: selection)
            let variants = [messages, Array(messages.dropFirst(2)), messages.reversed().map { $0 }]
            for variant in variants {
                let index = ChatResponseAttemptSupport.versionInfoByMessageID(in: variant)
                for message in variant {
                    #expect(index[message.id] == ChatResponseAttemptSupport.versionInfo(for: message, in: variant))
                }
            }
        }
    }

    @Test("流式正文复用版本索引，选择、删除、顺序与会话变化触发重建")
    func workerReusesOnlyUnchangedStructure() async {
        let worker = ChatResponseAttemptIndexWorker()
        let session = UUID()
        var messages = fixture(selection: 0)
        let initial = await worker.prepare(messages: messages, sessionID: session)
        messages[2].content += String(repeating: "新增正文", count: 100)
        let streaming = await worker.prepare(messages: messages, sessionID: session)
        #expect(streaming.revision == initial.revision)
        #expect(streaming.entries == initial.entries)

        let group = messages[1].id
        let otherAttempt = messages[4].responseAttemptID!
        messages = ChatResponseAttemptSupport.selectAttempt(attemptID: otherAttempt, groupID: group, in: messages)
        let switched = await worker.prepare(messages: messages, sessionID: session)
        #expect(switched.revision > streaming.revision)
        #expect(switched.entries[group]?.currentAttemptID == otherAttempt)

        messages.remove(at: 4)
        let deleted = await worker.prepare(messages: messages, sessionID: session)
        #expect(deleted.revision > switched.revision)
        #expect(deleted.entries[group] == nil)
        messages.reverse()
        let reordered = await worker.prepare(messages: messages, sessionID: session)
        #expect(reordered.revision > deleted.revision)
        let newSession = await worker.prepare(messages: messages, sessionID: UUID())
        #expect(newSession.revision > reordered.revision)
        let cleared = await worker.prepare(messages: [], sessionID: nil)
        #expect(cleared.entries.isEmpty)
    }

    private func fixture(selection: Int) -> [ChatMessage] {
        let group = UUID()
        let first = UUID()
        let second = UUID()
        return [
            ChatMessage(role: .user, content: "图片输入"),
            ChatMessage(id: group, role: .user, content: "问题", selectedResponseAttemptID: selection == 0 ? first : (selection == 1 ? second : UUID())),
            ChatMessage(role: .assistant, content: "第一次", responseGroupID: group, responseAttemptID: first, responseAttemptIndex: 0),
            ChatMessage(role: .tool, content: "工具结果", responseGroupID: group, responseAttemptID: first, responseAttemptIndex: 0),
            ChatMessage(role: .error, content: "第二次失败", responseGroupID: group, responseAttemptID: second, responseAttemptIndex: 1),
            ChatMessage(role: .assistant, content: "旧格式无分组回复"),
            ChatMessage(role: .user, content: "下一轮")
        ]
    }
}
