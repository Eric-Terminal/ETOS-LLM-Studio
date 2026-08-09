import Foundation
import SwiftUI
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

    @Test("ANSI 16 色、256 色与真彩色会生成富文本样式")
    func ansiColorsProduceAttributedRuns() {
        let screen = LocalLinuxTerminalScreen(columns: 80, rows: 4)
        screen.append(Data("默认 \u{1B}[31m红色 \u{1B}[38;5;202m索引 \u{1B}[38;2;1;2;3m真彩\u{1B}[0m".utf8))

        let presentation = screen.renderedPresentation()
        #expect(presentation.plainText == "默认 红色 索引 真彩")
        #expect(Array(presentation.attributedText.runs).count >= 4)
        #expect(presentation.attributedText != AttributedString(presentation.plainText))
    }

    @Test("ANSI 字体、背景与反色样式不会泄漏控制字符")
    func ansiTextStylesAreRendered() {
        let screen = LocalLinuxTerminalScreen(columns: 40, rows: 4)
        screen.append(Data("\u{1B}[1;3;4;44m样式\u{1B}[7m反色\u{1B}[0m".utf8))

        let presentation = screen.renderedPresentation()
        let runs = Array(presentation.attributedText.runs)
        #expect(presentation.plainText == "样式反色")
        #expect(runs.contains { $0.backgroundColor != nil })
        #expect(runs.contains { $0.underlineStyle != nil })
        #expect(runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    @Test("光标、设备属性和窗口尺寸查询返回 PTY 协议响应")
    func terminalQueriesProduceResponses() {
        let screen = LocalLinuxTerminalScreen(columns: 80, rows: 24)
        screen.append(Data("abc\u{1B}[6n\u{1B}[c\u{1B}[>c\u{1B}[18t\u{1B}[>0q".utf8))

        let response = String(decoding: screen.drainResponses(), as: UTF8.self)
        #expect(response.contains("\u{1B}[1;4R"))
        #expect(response.contains("\u{1B}[?1;2c"))
        #expect(response.contains("\u{1B}[>0;1;0c"))
        #expect(response.contains("\u{1B}[8;24;80t"))
        #expect(response.contains("\u{1B}P>|ETOS-LLM-Studio("))
    }

    @Test("OSC 调色板查询返回 xterm 颜色值")
    func oscColorQueryProducesResponse() {
        let screen = LocalLinuxTerminalScreen(columns: 20, rows: 4)
        screen.append(Data("\u{1B}]4;9;?\u{7}\u{1B}]11;?\u{1B}\\".utf8))

        let response = String(decoding: screen.drainResponses(), as: UTF8.self)
        #expect(response.contains("\u{1B}]4;9;rgb:ffff/0000/0000\u{1B}\\"))
        #expect(response.contains("\u{1B}]11;rgb:0000/0000/0000\u{1B}\\"))
    }

    @Test("基础环境如实声明 ETOS 真彩色终端")
    func baseEnvironmentDeclaresTerminalCapabilities() {
        let environment = LocalLinuxProcessEnvironmentProvider.baseEnvironment

        #expect(environment["TERM"] == "xterm-256color")
        #expect(environment["COLORTERM"] == "truecolor")
        #expect(environment["TERM_PROGRAM"] == "ETOS-LLM-Studio")
        #expect(environment["LC_TERMINAL"] == "ETOS-LLM-Studio")
        #expect(environment["TERM_PROGRAM_VERSION"] == LocalLinuxTerminalIdentity.programVersion)
    }
}
