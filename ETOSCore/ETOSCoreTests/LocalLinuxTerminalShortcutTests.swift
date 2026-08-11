import Foundation
import Testing
@testable import ETOSCore

@Suite("本地 Linux 终端快捷键测试")
struct LocalLinuxTerminalShortcutTests {
    @Test("默认快捷栏包含中断与挂起组合键")
    func defaultsContainInterruptAndSuspend() {
        let defaults = LocalLinuxTerminalShortcutConfiguration.defaults

        #expect(defaults.contains { $0.keys == [.control, .c] })
        #expect(defaults.contains { $0.keys == [.control, .z] })
    }

    @Test("JSON 持久化会保留组合、标识与排列顺序")
    func roundTripPreservesChordAndOrder() {
        let shortcuts = [
            LocalLinuxTerminalShortcut(keys: [.control, .z]),
            LocalLinuxTerminalShortcut(keys: [.a, .z]),
            LocalLinuxTerminalShortcut(keys: [.shift, .pageDown])
        ]
        let encoded = LocalLinuxTerminalShortcutConfiguration.encode(shortcuts)

        #expect(LocalLinuxTerminalShortcutConfiguration.decode(encoded) == shortcuts)
    }

    @Test("旧版逗号配置会迁移并忽略未知项与重复项")
    func legacyConfigurationIsMigrated() {
        let decoded = LocalLinuxTerminalShortcutConfiguration.decode(
            "controlC,futureKey,controlC,controlZ"
        )

        #expect(decoded.map(\.keys) == [[.control, .c], [.control, .z]])
    }

    @Test("空列表允许用户隐藏整个快捷栏")
    func emptySelectionIsPreserved() {
        let encoded = LocalLinuxTerminalShortcutConfiguration.encode([])

        #expect(LocalLinuxTerminalShortcutConfiguration.decode(encoded).isEmpty)
    }

    @Test("控制键与导航键会发送标准终端字节")
    func controlAndNavigationKeysProduceExpectedBytes() {
        #expect(LocalLinuxTerminalShortcut(keys: [.control, .c]).inputData == Data([0x03]))
        #expect(LocalLinuxTerminalShortcut(keys: [.control, .z]).inputData == Data([0x1A]))
        #expect(LocalLinuxTerminalShortcut(keys: [.arrowUp]).inputData == Data("\u{1B}[A".utf8))
        #expect(LocalLinuxTerminalShortcut(keys: [.control, .arrowUp]).inputData == Data("\u{1B}[1;5A".utf8))
    }

    @Test("多个普通键会通过同一次 PTY 写入按顺序发送")
    func multipleTypingKeysProduceOneOrderedPayload() {
        let shortcut = LocalLinuxTerminalShortcut(keys: [.a, .z])

        #expect(shortcut.inputData == Data("az".utf8))
    }

    @Test("组合会去重并把修饰键稳定放在前面")
    func chordNormalizationIsStable() {
        let shortcut = LocalLinuxTerminalShortcut(keys: [.a, .control, .a, .shift])

        #expect(shortcut.keys == [.control, .shift, .a])
    }
}
