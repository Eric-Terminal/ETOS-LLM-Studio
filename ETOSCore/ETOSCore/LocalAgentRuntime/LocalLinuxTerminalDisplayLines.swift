import Foundation

public struct LocalLinuxTerminalDisplayLine: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let plainText: String
    public let attributedText: AttributedString
    public let displayText: AttributedString

    init(id: UUID, plainText: String, attributedText: AttributedString) {
        self.id = id
        self.plainText = plainText
        self.attributedText = attributedText
        // 空行仍占一行高度；占位字符仅参与布局，不进入复制或日志内容。
        displayText = attributedText.characters.isEmpty ? AttributedString("\u{200B}") : attributedText
    }
}

/// 历史行已经冻结；只比较有界的活动屏幕，复用未变化行的两套富文本。
final class LocalLinuxTerminalDisplayCache {
    private struct Entry {
        let id = UUID()
        var cells: [LocalLinuxTerminalScreen.Cell]
        var presentation: LocalLinuxTerminalLinePresentation
    }

    private var screenRows: [Int: Entry] = [:]

    func render(
        screen: [[LocalLinuxTerminalScreen.Cell]],
        history: [LocalLinuxTerminalLinePresentation],
        maximumLines: Int?,
        appearance: LocalLinuxTerminalAppearance,
        visibleEnd: ([LocalLinuxTerminalScreen.Cell]) -> Int,
        renderLine: ([LocalLinuxTerminalScreen.Cell]) -> LocalLinuxTerminalLinePresentation
    ) -> [LocalLinuxTerminalDisplayLine] {
        var screenEnd = screen.endIndex
        while screenEnd > 0, visibleEnd(screen[screenEnd - 1]) == 0 { screenEnd -= 1 }
        var historyEnd = history.endIndex
        if screenEnd == 0 {
            while historyEnd > 0, history[historyEnd - 1].isEmpty { historyEnd -= 1 }
        }
        let limit = maximumLines.map { max(1, $0) }
        let screenStart = limit.map { max(0, screenEnd - $0) } ?? 0
        let historyCount = limit.map { min(historyEnd, max(0, $0 - (screenEnd - screenStart))) }
            ?? historyEnd
        var result = history[(historyEnd - historyCount)..<historyEnd].map { line in
            LocalLinuxTerminalDisplayLine(
                id: line.id, plainText: line.plainText, attributedText: line.attributedText(for: appearance)
            )
        }
        screenRows = screenRows.filter { $0.key < screen.count }
        for index in screenStart..<screenEnd {
            var entry = screenRows[index] ?? Entry(cells: screen[index], presentation: renderLine(screen[index]))
            if entry.cells != screen[index] {
                entry.cells = screen[index]
                entry.presentation = renderLine(screen[index])
            }
            screenRows[index] = entry
            result.append(LocalLinuxTerminalDisplayLine(
                id: entry.id,
                plainText: entry.presentation.plainText,
                attributedText: entry.presentation.attributedText(for: appearance)
            ))
        }
        return result
    }
}

extension LocalLinuxTerminalPresentation {
    init(lines: [LocalLinuxTerminalDisplayLine]) {
        var plainText = ""
        var attributedText = AttributedString()
        for (index, line) in lines.enumerated() {
            if index != 0 {
                plainText.append("\n")
                attributedText.append(AttributedString("\n"))
            }
            plainText.append(line.plainText)
            attributedText.append(line.attributedText)
        }
        self.init(plainText: plainText, attributedText: attributedText)
    }
}
