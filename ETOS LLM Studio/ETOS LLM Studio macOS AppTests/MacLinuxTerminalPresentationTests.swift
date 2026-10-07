import Foundation
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacLinuxTerminalPresentationTests {
    @Test("终端菜单使用稳定身份，不泄露命令、环境和目录")
    func terminalLabelDoesNotExposeRequest() {
        let job = LocalLinuxJob(requestID: 1, kind: .terminal, sessionID: nil, runID: nil, rootRunID: nil,
            parentRunID: nil, toolCallID: nil, workspaceID: nil, executorDeviceID: "test",
            request: LocalLinuxJobRequest(executable: "/private/sensitive-shell", arguments: ["secret argument"],
                environment: ["TOKEN": "secret value"], workingDirectory: "/private/secret-directory"))
        let row = MacLinuxTerminalRow(job)
        #expect(row.id == job.id)
        #expect(row.title.contains(String(job.id.uuidString.prefix(8))))
        #expect(!row.title.contains("private") && !row.title.contains("secret"))
    }

    @Test("后台快捷键展示保留复合按键及 PTY 字节")
    func shortcutRetainsControlSequence() {
        let row = MacLinuxTerminalKeyRow(LocalLinuxTerminalShortcut(keys: [.control, .c]))
        #expect(row.data == Data([3]))
        #expect(!row.title.isEmpty)
        let navigation = MacLinuxTerminalKeyRow(LocalLinuxTerminalShortcut(keys: [.arrowUp]))
        #expect(navigation.data == Data([0x1B, 0x5B, 0x41]))
    }
}
