import Foundation
import Testing
@testable import ETOSCore

@Suite("本地 Linux 终端环形历史")
struct LocalLinuxTerminalHistoryTests {
    @Test("多次绕回后仍按时间顺序读取，已发布快照保持不变")
    func wrappedHistoryPreservesOrderAndSnapshots() {
        let screen = LocalLinuxTerminalScreen(columns: 20, rows: 2, scrollbackLimit: 3)
        screen.append(Data("0\r\n1\r\n2\r\n3\r\n4".utf8))
        let initial = screen.renderedDisplayLines()
        for number in 5...100 {
            screen.append(Data("\r\n\(number)".utf8))
        }
        #expect(initial.map(\.plainText) == ["0", "1", "2", "3", "4"])
        #expect(screen.renderedText() == "96\n97\n98\n99\n100")
        #expect(screen.renderedDisplayLines().map(\.plainText) == ["96", "97", "98", "99", "100"])
        #expect(screen.renderedDisplayLines(maximumLines: 3).map(\.plainText) == ["98", "99", "100"])
        let beforeResize = screen.renderedDisplayLines()
        screen.resize(columns: 20, rows: 1)
        #expect(screen.renderedText() == "97\n98\n99\n100")
        #expect(screen.renderedDisplayLines().first?.id == beforeResize[1].id)
        screen.append(Data("\u{1B}[3J".utf8))
        #expect(screen.renderedText().isEmpty)
        screen.append(Data("\r101\r\n102".utf8))
        #expect(screen.renderedText() == "101\n102")
    }

    @Test("零容量与单行容量不会保留过期历史", arguments: [0, 1])
    func minimalCapacity(capacity: Int) {
        let screen = LocalLinuxTerminalScreen(columns: 20, rows: 1, scrollbackLimit: capacity)
        screen.append(Data("one\r\ntwo\r\nthree".utf8))
        #expect(screen.renderedText() == (capacity == 0 ? "three" : "two\nthree"))
        screen.append(Data("\u{1B}cfresh".utf8))
        #expect(screen.renderedDisplayLines().map(\.plainText) == ["fresh"])
    }

    @Test("历史值拷贝不会被后续覆盖或清空修改")
    func copiedHistoryHasIndependentStorage() {
        var history = LocalLinuxTerminalHistory(capacity: 2)
        for text in ["one", "two", "three"] {
            history.append(LocalLinuxTerminalLinePresentation(
                plainText: text, lightAttributedText: AttributedString(text), darkAttributedText: AttributedString(text)
            ))
        }
        let saved = history
        history.removeAll(keepingCapacity: true)
        history.append(LocalLinuxTerminalLinePresentation(
            plainText: "four", lightAttributedText: AttributedString("four"), darkAttributedText: AttributedString("four")
        ))
        #expect(saved.map(\.plainText) == ["two", "three"])
        #expect(history.map(\.plainText) == ["four"])
    }
}
