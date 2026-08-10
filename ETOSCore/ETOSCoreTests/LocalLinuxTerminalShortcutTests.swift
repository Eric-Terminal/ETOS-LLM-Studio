import Foundation
import Testing
@testable import ETOSCore

@Suite("本地 Linux 终端快捷键测试")
struct LocalLinuxTerminalShortcutTests {
    @Test("默认快捷栏包含中断与挂起组合键")
    func defaultsContainInterruptAndSuspend() {
        #expect(LocalLinuxTerminalShortcutConfiguration.defaults.contains(.controlC))
        #expect(LocalLinuxTerminalShortcutConfiguration.defaults.contains(.controlZ))
    }

    @Test("持久化会保留用户选择的顺序")
    func roundTripPreservesOrder() {
        let shortcuts: [LocalLinuxTerminalShortcut] = [.controlZ, .escape, .pageDown, .controlC]
        let encoded = LocalLinuxTerminalShortcutConfiguration.encode(shortcuts)

        #expect(LocalLinuxTerminalShortcutConfiguration.decode(encoded) == shortcuts)
    }

    @Test("解码会忽略未知项与重复项")
    func decodingDropsUnknownAndDuplicateItems() {
        let decoded = LocalLinuxTerminalShortcutConfiguration.decode(
            "controlC,futureKey,controlC,controlZ"
        )

        #expect(decoded == [.controlC, .controlZ])
    }

    @Test("空列表允许用户隐藏整个快捷栏")
    func emptySelectionIsPreserved() {
        let encoded = LocalLinuxTerminalShortcutConfiguration.encode([])

        #expect(LocalLinuxTerminalShortcutConfiguration.decode(encoded).isEmpty)
    }

    @Test("快捷键会发送正确的终端字节")
    func shortcutsProduceExpectedBytes() {
        #expect(LocalLinuxTerminalShortcut.controlC.inputData == Data([0x03]))
        #expect(LocalLinuxTerminalShortcut.controlZ.inputData == Data([0x1A]))
        #expect(LocalLinuxTerminalShortcut.arrowUp.inputData == Data("\u{1B}[A".utf8))
        #expect(LocalLinuxTerminalShortcut.pageDown.inputData == Data("\u{1B}[6~".utf8))
    }
}
