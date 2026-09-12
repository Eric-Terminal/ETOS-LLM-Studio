import Foundation
import Testing
@testable import ETOSCore

@Suite("本地 Linux 终端增量行快照")
struct LocalLinuxTerminalDisplayLineTests {
    @Test("回车覆盖复用行身份并保持已发布快照不可变")
    func overwrittenLineKeepsIdentity() throws {
        let screen = LocalLinuxTerminalScreen(columns: 20, rows: 2)
        screen.append(Data("history\r\nfirst\r\nsecond".utf8))
        let initial = screen.renderedDisplayLines()
        try #require(initial.count == 3)
        screen.append(Data("\rchanged\u{1B}[K".utf8))
        let changed = screen.renderedDisplayLines()
        #expect(changed.map(\.id) == initial.map(\.id))
        #expect(changed[0] == initial[0] && changed[1] == initial[1])
        #expect(initial[2].plainText == "second" && changed[2].plainText == "changed")
        #expect(LocalLinuxTerminalPresentation(lines: changed) == screen.renderedPresentation())
    }

    @Test("回滚裁剪与备用屏切换不复用仍存活历史行的身份")
    func historyAndAlternateScreenHaveStableDistinctIdentities() throws {
        let screen = LocalLinuxTerminalScreen(columns: 20, rows: 2, scrollbackLimit: 2)
        screen.append(Data("one\r\ntwo\r\nthree".utf8))
        let initial = screen.renderedDisplayLines()
        screen.append(Data("\r\nfour".utf8))
        let extended = screen.renderedDisplayLines()
        #expect(extended.first?.id == initial.first?.id)
        screen.append(Data("\r\nfive".utf8))
        let trimmed = screen.renderedDisplayLines()
        #expect(trimmed.map(\.plainText) == ["two", "three", "four", "five"])
        #expect(trimmed.first?.id == extended[1].id)
        #expect(Set(trimmed.map(\.id)).count == trimmed.count)
        screen.append(Data("\u{1B}[?1049halternate".utf8))
        let alternate = screen.renderedDisplayLines()
        #expect(Set(alternate.map(\.id)).isDisjoint(with: trimmed.map(\.id)))
        screen.append(Data("\u{1B}[?1049l".utf8))
        #expect(screen.renderedDisplayLines() == trimmed)
        #expect(screen.renderedDisplayLines(maximumLines: 1).map(\.plainText) == ["five"])
    }

    @Test("空行保留布局高度且布局占位字符不进入纯文本")
    func blankRowsKeepLayoutWithoutChangingCopyText() throws {
        let screen = LocalLinuxTerminalScreen(columns: 20, rows: 4)
        screen.append(Data("one\r\n\r\nthree".utf8))
        let lines = screen.renderedDisplayLines()
        try #require(lines.count == 3)
        #expect(lines[1].plainText.isEmpty && lines[1].attributedText.characters.isEmpty)
        #expect(!lines[1].displayText.characters.isEmpty)
        #expect(LocalLinuxTerminalPresentation(lines: lines).plainText == "one\n\nthree")
    }

    @Test("外观切换与缩放刷新活动行而不污染旧快照")
    func appearanceAndResizeRefreshCachedCells() throws {
        let screen = LocalLinuxTerminalScreen(columns: 20, rows: 2)
        screen.append(Data("\u{1B}[31mabcdef".utf8))
        let dark = screen.renderedDisplayLines(appearance: .dark)
        let light = screen.renderedDisplayLines(appearance: .light)
        #expect(dark.map(\.id) == light.map(\.id))
        #expect(LocalLinuxTerminalPresentation(lines: light) == screen.renderedPresentation(appearance: .light))
        screen.resize(columns: 3, rows: 2)
        #expect(screen.renderedDisplayLines().map(\.plainText) == ["abc"])
        #expect(dark.first?.plainText == "abcdef")
    }
}
