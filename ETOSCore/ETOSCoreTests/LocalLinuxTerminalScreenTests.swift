import Foundation
import Testing
@testable import ETOSCore

@Suite("本地 Linux 终端屏幕测试")
struct LocalLinuxTerminalScreenTests {
    @Test("清屏控制序列不会泄漏为可见文本")
    func eraseDisplaySequenceDoesNotLeak() {
        let screen = LocalLinuxTerminalScreen(columns: 80, rows: 12)
        screen.append(Data("ETOS:~# ".utf8))
        screen.append(Data([0x1B, 0x5B, 0x4A]))
        screen.append(Data("ls\r\nhello.txt\r\nETOS:~# ".utf8))

        let rendered = screen.renderedText()
        #expect(!rendered.contains("[J"))
        #expect(rendered == "ETOS:~# ls\nhello.txt\nETOS:~#")
    }

    @Test("回车与行擦除按终端光标覆盖现有内容")
    func carriageReturnAndEraseLineRewriteCells() {
        let screen = LocalLinuxTerminalScreen(columns: 20, rows: 4)
        screen.append(Data("progress 100%\rready".utf8))
        screen.append(Data([0x1B, 0x5B, 0x4B]))

        #expect(screen.renderedText() == "ready")
    }

    @Test("备用屏退出后恢复登录 Shell 主屏")
    func alternateScreenRestoresPrimaryScreen() {
        let screen = LocalLinuxTerminalScreen(columns: 20, rows: 4)
        screen.append(Data("ETOS:~# ".utf8))
        screen.append(Data("\u{1B}[?1049hTOP\u{1B}[?1049l".utf8))

        #expect(screen.renderedText() == "ETOS:~#")
    }

    @Test("跨输出分片的 UTF-8 字符保持完整")
    func splitUTF8SequenceRemainsIntact() {
        let screen = LocalLinuxTerminalScreen(columns: 20, rows: 4)
        let bytes = Array("终端".utf8)
        screen.append(Data(bytes.prefix(2)))
        screen.append(Data(bytes.dropFirst(2)))

        #expect(screen.renderedText() == "终端")
    }
}
