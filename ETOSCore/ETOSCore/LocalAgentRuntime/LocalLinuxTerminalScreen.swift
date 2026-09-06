// ============================================================================
// LocalLinuxTerminalScreen.swift
// ============================================================================
// ETOS LLM Studio
//
// PTY 输出是终端协议，不是可直接追加到 Text 的日志。这个有界屏幕模型在
// 后台增量执行常用 VT100/xterm 控制序列，再把已经排版的纯文本快照交给 UI。
// ============================================================================

import Foundation

final class LocalLinuxTerminalScreen: @unchecked Sendable {
    private struct Cell: Equatable {
        var text = ""
        var isContinuation = false
        var style = LocalLinuxTerminalStyle.default

        static let blank = Cell()
    }

    private struct Cursor: Equatable {
        var row = 0
        var column = 0
    }

    private struct Buffer {
        var lines: [[Cell]]
        var cursor = Cursor()
        var savedCursor = Cursor()
        var scrollTop = 0
        var scrollBottom: Int
        var pendingWrap = false

        init(columns: Int, rows: Int) {
            lines = Array(
                repeating: Array(repeating: .blank, count: columns),
                count: rows
            )
            scrollBottom = rows - 1
        }
    }

    private enum ParserState {
        case ground
        case escape
        case escapeIntermediate
        case csi
        case osc
        case oscEscape
        case ignoredString
        case ignoredStringEscape
    }

    private let scrollbackLimit: Int
    private var columns: Int
    private var rows: Int
    private var primary: Buffer
    private var alternate: Buffer
    private var scrollback: [LocalLinuxTerminalLinePresentation] = []
    private var usesAlternateScreen = false
    private var usesAutoWrap = true
    private var usesInsertMode = false
    private var currentStyle = LocalLinuxTerminalStyle.default
    private var parserState = ParserState.ground
    private var csiBytes: [UInt8] = []
    private var oscBytes: [UInt8] = []
    private var utf8Bytes: [UInt8] = []
    private var utf8BytesRemaining = 0
    private var pendingResponses = Data()

    init(columns: Int, rows: Int, scrollbackLimit: Int = 2_000) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.scrollbackLimit = max(0, scrollbackLimit)
        primary = Buffer(columns: self.columns, rows: self.rows)
        alternate = Buffer(columns: self.columns, rows: self.rows)
    }

    func append(_ data: Data) {
        for byte in data {
            consume(byte)
        }
    }

    func drainResponses() -> Data {
        let responses = pendingResponses
        pendingResponses.removeAll(keepingCapacity: true)
        return responses
    }

    func resize(columns newColumns: Int, rows newRows: Int) {
        let targetColumns = max(1, newColumns)
        let targetRows = max(1, newRows)
        guard targetColumns != columns || targetRows != rows else { return }
        primary = resized(primary, columns: targetColumns, rows: targetRows, preservesHistory: true)
        alternate = resized(alternate, columns: targetColumns, rows: targetRows, preservesHistory: false)
        columns = targetColumns
        rows = targetRows
    }

    func renderedText() -> String {
        var values = usesAlternateScreen ? [] : scrollback.map(\.plainText)
        values.append(contentsOf: activeBuffer.lines.map(renderedPlainText))
        while values.last?.isEmpty == true {
            values.removeLast()
        }
        return values.joined(separator: "\n")
    }

    func renderedPresentation(
        maximumLines: Int? = nil,
        appearance: LocalLinuxTerminalAppearance = .dark
    ) -> LocalLinuxTerminalPresentation {
        var values = usesAlternateScreen ? [] : scrollback
        values.append(contentsOf: activeBuffer.lines.map(renderedLine))
        while values.last?.isEmpty == true {
            values.removeLast()
        }
        if let maximumLines {
            values = Array(values.suffix(max(1, maximumLines)))
        }
        var plainText = ""
        var attributedText = AttributedString()
        for (index, line) in values.enumerated() {
            if index != 0 {
                plainText.append("\n")
                attributedText.append(AttributedString("\n"))
            }
            plainText.append(line.plainText)
            attributedText.append(line.attributedText(for: appearance))
        }
        return LocalLinuxTerminalPresentation(
            plainText: plainText,
            attributedText: attributedText
        )
    }

    private var activeBuffer: Buffer {
        get { usesAlternateScreen ? alternate : primary }
        set {
            if usesAlternateScreen {
                alternate = newValue
            } else {
                primary = newValue
            }
        }
    }

    private func consume(_ byte: UInt8) {
        if utf8BytesRemaining > 0 {
            if byte & 0xC0 == 0x80 {
                utf8Bytes.append(byte)
                utf8BytesRemaining -= 1
                if utf8BytesRemaining == 0 {
                    let value = String(decoding: utf8Bytes, as: UTF8.self)
                    value.forEach(put)
                    utf8Bytes.removeAll(keepingCapacity: true)
                }
                return
            }
            put("�")
            utf8Bytes.removeAll(keepingCapacity: true)
            utf8BytesRemaining = 0
        }

        switch parserState {
        case .ground:
            consumeGround(byte)
        case .escape:
            consumeEscape(byte)
        case .escapeIntermediate:
            parserState = .ground
        case .csi:
            consumeCSI(byte)
        case .osc:
            if byte == 0x07 {
                dispatchOSC()
                parserState = .ground
            } else if byte == 0x1B {
                parserState = .oscEscape
            } else if oscBytes.count < 4_096 {
                oscBytes.append(byte)
            }
        case .oscEscape:
            if byte == 0x5C {
                dispatchOSC()
                parserState = .ground
            } else {
                if oscBytes.count < 4_096 {
                    oscBytes.append(0x1B)
                    oscBytes.append(byte)
                }
                parserState = .osc
            }
        case .ignoredString:
            if byte == 0x1B { parserState = .ignoredStringEscape }
        case .ignoredStringEscape:
            parserState = byte == 0x5C ? .ground : .ignoredString
        }
    }

    private func consumeGround(_ byte: UInt8) {
        switch byte {
        case 0x00, 0x07, 0x0E, 0x0F, 0x7F:
            break
        case 0x08:
            mutateBuffer { buffer in
                buffer.pendingWrap = false
                buffer.cursor.column = max(0, buffer.cursor.column - 1)
            }
        case 0x09:
            mutateBuffer { buffer in
                buffer.pendingWrap = false
                buffer.cursor.column = min(columns - 1, (buffer.cursor.column / 8 + 1) * 8)
            }
        case 0x0A, 0x0B, 0x0C:
            lineFeed()
        case 0x0D:
            mutateBuffer { buffer in
                buffer.pendingWrap = false
                buffer.cursor.column = 0
            }
        case 0x1B:
            parserState = .escape
        case 0x20...0x7E:
            put(Character(UnicodeScalar(byte)))
        case 0xC2...0xDF:
            utf8Bytes = [byte]
            utf8BytesRemaining = 1
        case 0xE0...0xEF:
            utf8Bytes = [byte]
            utf8BytesRemaining = 2
        case 0xF0...0xF4:
            utf8Bytes = [byte]
            utf8BytesRemaining = 3
        default:
            put("�")
        }
    }

    private func consumeEscape(_ byte: UInt8) {
        switch byte {
        case 0x5B:
            csiBytes.removeAll(keepingCapacity: true)
            parserState = .csi
        case 0x5D:
            oscBytes.removeAll(keepingCapacity: true)
            parserState = .osc
        case 0x50, 0x58, 0x5E, 0x5F:
            parserState = .ignoredString
        case 0x37:
            mutateBuffer { $0.savedCursor = $0.cursor }
            parserState = .ground
        case 0x38:
            restoreCursor()
            parserState = .ground
        case 0x44:
            lineFeed()
            parserState = .ground
        case 0x45:
            lineFeed()
            mutateBuffer { $0.cursor.column = 0 }
            parserState = .ground
        case 0x4D:
            reverseIndex()
            parserState = .ground
        case 0x63:
            reset()
            parserState = .ground
        case 0x20...0x2F:
            // 字符集与两字节 ESC 序列对纯文本屏幕没有影响；吞掉下一字节。
            parserState = .escapeIntermediate
        default:
            parserState = .ground
        }
    }

    private func consumeCSI(_ byte: UInt8) {
        if byte >= 0x40, byte <= 0x7E {
            dispatchCSI(finalByte: byte)
            csiBytes.removeAll(keepingCapacity: true)
            parserState = .ground
            return
        }
        guard csiBytes.count < 256 else {
            csiBytes.removeAll(keepingCapacity: false)
            parserState = .ground
            return
        }
        if byte >= 0x20, byte <= 0x3F {
            csiBytes.append(byte)
        } else if byte == 0x1B {
            csiBytes.removeAll(keepingCapacity: true)
            parserState = .escape
        }
    }

    private func dispatchCSI(finalByte: UInt8) {
        let privateMarker = csiBytes.first.flatMap { (0x3C...0x3F).contains($0) ? $0 : nil }
        let parameterBytes = csiBytes.dropFirst(privateMarker == nil ? 0 : 1)
            .prefix { $0 < 0x20 || $0 > 0x2F }
        let parameters = parseParameters(parameterBytes)
        let first = parameter(parameters, at: 0, default: 1)

        switch finalByte {
        case 0x40:
            insertCharacters(first)
        case 0x41:
            moveCursor(rowDelta: -first, columnDelta: 0)
        case 0x42:
            moveCursor(rowDelta: first, columnDelta: 0)
        case 0x43:
            moveCursor(rowDelta: 0, columnDelta: first)
        case 0x44:
            moveCursor(rowDelta: 0, columnDelta: -first)
        case 0x45:
            moveCursor(rowDelta: first, columnDelta: 0, resetsColumn: true)
        case 0x46:
            moveCursor(rowDelta: -first, columnDelta: 0, resetsColumn: true)
        case 0x47, 0x60:
            setCursor(column: first - 1)
        case 0x48, 0x66:
            setCursor(
                row: parameter(parameters, at: 0, default: 1) - 1,
                column: parameter(parameters, at: 1, default: 1) - 1
            )
        case 0x4A:
            eraseDisplay(parameters.first ?? 0)
        case 0x4B:
            eraseLine(parameters.first ?? 0)
        case 0x4C:
            insertLines(first)
        case 0x4D:
            deleteLines(first)
        case 0x50:
            deleteCharacters(first)
        case 0x53:
            scrollUp(first)
        case 0x54:
            scrollDown(first)
        case 0x58:
            eraseCharacters(first)
        case 0x63:
            reportDeviceAttributes(privateMarker: privateMarker)
        case 0x64:
            setCursor(row: first - 1)
        case 0x68, 0x6C:
            setModes(parameters, privateMarker: privateMarker, enabled: finalByte == 0x68)
        case 0x6D:
            applyGraphicRendition(parameters)
        case 0x6E:
            reportDeviceStatus(parameters, privateMarker: privateMarker)
        case 0x71:
            if privateMarker == 0x3E {
                pendingResponses.append(LocalLinuxTerminalIdentity.versionReport)
            }
        case 0x72:
            setScrollRegion(parameters)
        case 0x73:
            mutateBuffer { $0.savedCursor = $0.cursor }
        case 0x74:
            reportWindowState(parameters)
        case 0x75:
            restoreCursor()
        default:
            break
        }
    }

    private func parseParameters(_ bytes: ArraySlice<UInt8>) -> [Int] {
        guard !bytes.isEmpty else { return [] }
        var values: [Int] = []
        var value = 0
        var hasDigit = false
        for byte in bytes {
            if byte >= 0x30, byte <= 0x39 {
                hasDigit = true
                value = min(1_000_000, value * 10 + Int(byte - 0x30))
            } else if byte == 0x3B || byte == 0x3A {
                values.append(hasDigit ? value : 0)
                value = 0
                hasDigit = false
            }
        }
        values.append(hasDigit ? value : 0)
        return values
    }

    private func parameter(_ parameters: [Int], at index: Int, default defaultValue: Int) -> Int {
        guard parameters.indices.contains(index), parameters[index] != 0 else { return defaultValue }
        return parameters[index]
    }

    private func applyGraphicRendition(_ rawParameters: [Int]) {
        let parameters = rawParameters.isEmpty ? [0] : rawParameters
        var index = 0
        while index < parameters.count {
            let value = parameters[index]
            switch value {
            case 0:
                currentStyle = .default
            case 1:
                currentStyle.isBold = true
            case 2:
                currentStyle.isFaint = true
            case 3:
                currentStyle.isItalic = true
            case 4, 21:
                currentStyle.isUnderlined = true
            case 5, 6:
                // 记录闪烁状态，但不在移动设备上启动常驻动画。
                currentStyle.isBlinking = true
            case 7:
                currentStyle.isInverse = true
            case 8:
                currentStyle.isConcealed = true
            case 9:
                currentStyle.isStruckThrough = true
            case 22:
                currentStyle.isBold = false
                currentStyle.isFaint = false
            case 23:
                currentStyle.isItalic = false
            case 24:
                currentStyle.isUnderlined = false
            case 25:
                currentStyle.isBlinking = false
            case 27:
                currentStyle.isInverse = false
            case 28:
                currentStyle.isConcealed = false
            case 29:
                currentStyle.isStruckThrough = false
            case 30...37:
                currentStyle.foreground = .indexed(UInt8(value - 30))
            case 38:
                index += applyExtendedColor(
                    parameters,
                    parameterIndex: index,
                    assigns: { currentStyle.foreground = $0 }
                )
            case 39:
                currentStyle.foreground = nil
            case 40...47:
                currentStyle.background = .indexed(UInt8(value - 40))
            case 48:
                index += applyExtendedColor(
                    parameters,
                    parameterIndex: index,
                    assigns: { currentStyle.background = $0 }
                )
            case 49:
                currentStyle.background = nil
            case 90...97:
                currentStyle.foreground = .indexed(UInt8(value - 90 + 8))
            case 100...107:
                currentStyle.background = .indexed(UInt8(value - 100 + 8))
            default:
                break
            }
            index += 1
        }
    }

    /// 返回已经额外消费的参数数量；调用方仍会统一跨过颜色指令本身。
    private func applyExtendedColor(
        _ parameters: [Int],
        parameterIndex: Int,
        assigns: (LocalLinuxTerminalColor) -> Void
    ) -> Int {
        guard parameters.indices.contains(parameterIndex + 1) else { return 0 }
        switch parameters[parameterIndex + 1] {
        case 5:
            guard parameters.indices.contains(parameterIndex + 2) else { return 1 }
            assigns(.indexed(UInt8(clamping: parameters[parameterIndex + 2])))
            return 2
        case 2:
            var componentStart = parameterIndex + 2
            // ISO-8613-6 的冒号写法可在 RGB 前携带一个空颜色空间参数。
            if parameters.count > parameterIndex + 5, parameters[componentStart] == 0 {
                componentStart += 1
            }
            guard parameters.indices.contains(componentStart + 2) else { return 1 }
            assigns(.rgb(
                red: UInt8(clamping: parameters[componentStart]),
                green: UInt8(clamping: parameters[componentStart + 1]),
                blue: UInt8(clamping: parameters[componentStart + 2])
            ))
            return componentStart + 2 - parameterIndex
        default:
            return 0
        }
    }

    private func reportDeviceAttributes(privateMarker: UInt8?) {
        if privateMarker == 0x3E {
            appendResponse("\u{1B}[>0;1;0c")
        } else if privateMarker == nil {
            appendResponse("\u{1B}[?1;2c")
        }
    }

    private func reportDeviceStatus(_ parameters: [Int], privateMarker: UInt8?) {
        let request = parameters.first ?? 0
        if request == 5, privateMarker == nil {
            appendResponse("\u{1B}[0n")
            return
        }
        guard request == 6 else { return }
        let cursor = activeBuffer.cursor
        let marker = privateMarker == 0x3F ? "?" : ""
        appendResponse("\u{1B}[\(marker)\(cursor.row + 1);\(cursor.column + 1)R")
    }

    private func reportWindowState(_ parameters: [Int]) {
        switch parameters.first ?? 0 {
        case 18:
            appendResponse("\u{1B}[8;\(rows);\(columns)t")
        case 19:
            appendResponse("\u{1B}[9;\(rows);\(columns)t")
        default:
            break
        }
    }

    private func dispatchOSC() {
        defer { oscBytes.removeAll(keepingCapacity: true) }
        guard let value = String(bytes: oscBytes, encoding: .utf8),
              let separator = value.firstIndex(of: ";") else { return }
        let command = String(value[..<separator])
        let body = String(value[value.index(after: separator)...])
        switch command {
        case "10" where body == "?":
            reportOSCColor(command: command, color: .indexed(7))
        case "11" where body == "?":
            reportOSCColor(command: command, color: .indexed(0))
        case "12" where body == "?":
            reportOSCColor(command: command, color: .indexed(7))
        case "4":
            let components = body.split(separator: ";", omittingEmptySubsequences: false)
            guard components.count >= 2,
                  components[1] == "?",
                  let rawIndex = Int(components[0]),
                  (0...255).contains(rawIndex) else { return }
            let color = LocalLinuxTerminalColor.indexed(UInt8(rawIndex))
            appendResponse("\u{1B}]4;\(rawIndex);\(color.xtermColorReport)\u{1B}\\")
        default:
            break
        }
    }

    private func reportOSCColor(command: String, color: LocalLinuxTerminalColor) {
        appendResponse("\u{1B}]\(command);\(color.xtermColorReport)\u{1B}\\")
    }

    private func appendResponse(_ value: String) {
        pendingResponses.append(contentsOf: value.utf8)
    }

    private func put(_ character: Character) {
        var buffer = activeBuffer
        if buffer.pendingWrap {
            buffer.pendingWrap = false
            if usesAutoWrap {
                buffer.cursor.column = 0
                index(&buffer)
            }
        }

        let width = characterWidth(character)
        if width == 2, buffer.cursor.column == columns - 1, usesAutoWrap {
            buffer.cursor.column = 0
            index(&buffer)
        }
        let row = buffer.cursor.row
        let column = buffer.cursor.column
        if usesInsertMode {
            let shift = min(width, columns - column)
            if shift > 0 {
                for target in stride(from: columns - 1, through: column + shift, by: -1) {
                    buffer.lines[row][target] = buffer.lines[row][target - shift]
                }
            }
        }
        buffer.lines[row][column] = Cell(
            text: String(character),
            isContinuation: false,
            style: currentStyle
        )
        if width == 2, column + 1 < columns {
            buffer.lines[row][column + 1] = Cell(
                text: "",
                isContinuation: true,
                style: currentStyle
            )
        }
        let next = column + width
        if next >= columns {
            buffer.cursor.column = columns - 1
            buffer.pendingWrap = usesAutoWrap
        } else {
            buffer.cursor.column = next
        }
        activeBuffer = buffer
    }

    private func lineFeed() {
        mutateBuffer { buffer in
            buffer.pendingWrap = false
            index(&buffer)
        }
    }

    private func index(_ buffer: inout Buffer) {
        if buffer.cursor.row == buffer.scrollBottom {
            scrollUp(&buffer, count: 1)
        } else {
            buffer.cursor.row = min(rows - 1, buffer.cursor.row + 1)
        }
    }

    private func reverseIndex() {
        mutateBuffer { buffer in
            buffer.pendingWrap = false
            if buffer.cursor.row == buffer.scrollTop {
                scrollDown(&buffer, count: 1)
            } else {
                buffer.cursor.row = max(0, buffer.cursor.row - 1)
            }
        }
    }

    private func moveCursor(rowDelta: Int, columnDelta: Int, resetsColumn: Bool = false) {
        mutateBuffer { buffer in
            buffer.pendingWrap = false
            buffer.cursor.row = min(rows - 1, max(0, buffer.cursor.row + rowDelta))
            buffer.cursor.column = resetsColumn
                ? 0
                : min(columns - 1, max(0, buffer.cursor.column + columnDelta))
        }
    }

    private func setCursor(row: Int? = nil, column: Int? = nil) {
        mutateBuffer { buffer in
            buffer.pendingWrap = false
            if let row { buffer.cursor.row = min(rows - 1, max(0, row)) }
            if let column { buffer.cursor.column = min(columns - 1, max(0, column)) }
        }
    }

    private func restoreCursor() {
        mutateBuffer { buffer in
            buffer.cursor = Cursor(
                row: min(rows - 1, max(0, buffer.savedCursor.row)),
                column: min(columns - 1, max(0, buffer.savedCursor.column))
            )
            buffer.pendingWrap = false
        }
    }

    private func eraseDisplay(_ mode: Int) {
        mutateBuffer { buffer in
            let row = buffer.cursor.row
            let column = buffer.cursor.column
            switch mode {
            case 1:
                for line in 0..<row { buffer.lines[line] = blankLine() }
                erase(&buffer.lines[row], from: 0, through: column)
            case 2, 3:
                buffer.lines = Array(repeating: blankLine(), count: rows)
                if mode == 3 { scrollback.removeAll(keepingCapacity: true) }
            default:
                erase(&buffer.lines[row], from: column, through: columns - 1)
                if row + 1 < rows {
                    for line in (row + 1)..<rows { buffer.lines[line] = blankLine() }
                }
            }
            buffer.pendingWrap = false
        }
    }

    private func eraseLine(_ mode: Int) {
        mutateBuffer { buffer in
            let row = buffer.cursor.row
            switch mode {
            case 1:
                erase(&buffer.lines[row], from: 0, through: buffer.cursor.column)
            case 2:
                buffer.lines[row] = blankLine()
            default:
                erase(&buffer.lines[row], from: buffer.cursor.column, through: columns - 1)
            }
            buffer.pendingWrap = false
        }
    }

    private func eraseCharacters(_ count: Int) {
        mutateBuffer { buffer in
            erase(
                &buffer.lines[buffer.cursor.row],
                from: buffer.cursor.column,
                through: min(columns - 1, buffer.cursor.column + max(1, count) - 1)
            )
        }
    }

    private func insertCharacters(_ count: Int) {
        mutateBuffer { buffer in
            let row = buffer.cursor.row
            let column = buffer.cursor.column
            let amount = min(max(1, count), columns - column)
            for target in stride(from: columns - 1, through: column + amount, by: -1) {
                buffer.lines[row][target] = buffer.lines[row][target - amount]
            }
            for target in column..<min(columns, column + amount) {
                buffer.lines[row][target] = blankCell()
            }
        }
    }

    private func deleteCharacters(_ count: Int) {
        mutateBuffer { buffer in
            let row = buffer.cursor.row
            let column = buffer.cursor.column
            let amount = min(max(1, count), columns - column)
            if column + amount < columns {
                for target in column..<(columns - amount) {
                    buffer.lines[row][target] = buffer.lines[row][target + amount]
                }
            }
            for target in (columns - amount)..<columns {
                buffer.lines[row][target] = blankCell()
            }
        }
    }

    private func insertLines(_ count: Int) {
        mutateBuffer { buffer in
            guard (buffer.scrollTop...buffer.scrollBottom).contains(buffer.cursor.row) else { return }
            let amount = min(max(1, count), buffer.scrollBottom - buffer.cursor.row + 1)
            for _ in 0..<amount {
                buffer.lines.insert(blankLine(), at: buffer.cursor.row)
                buffer.lines.remove(at: buffer.scrollBottom + 1)
            }
        }
    }

    private func deleteLines(_ count: Int) {
        mutateBuffer { buffer in
            guard (buffer.scrollTop...buffer.scrollBottom).contains(buffer.cursor.row) else { return }
            let amount = min(max(1, count), buffer.scrollBottom - buffer.cursor.row + 1)
            for _ in 0..<amount {
                buffer.lines.remove(at: buffer.cursor.row)
                buffer.lines.insert(blankLine(), at: buffer.scrollBottom)
            }
        }
    }

    private func scrollUp(_ count: Int) {
        mutateBuffer { scrollUp(&$0, count: max(1, count)) }
    }

    private func scrollUp(_ buffer: inout Buffer, count: Int) {
        let amount = min(count, buffer.scrollBottom - buffer.scrollTop + 1)
        for _ in 0..<amount {
            let removed = buffer.lines.remove(at: buffer.scrollTop)
            buffer.lines.insert(blankLine(), at: buffer.scrollBottom)
            if !usesAlternateScreen && buffer.scrollTop == 0 && buffer.scrollBottom == rows - 1 {
                appendScrollback(renderedLine(removed))
            }
        }
    }

    private func scrollDown(_ count: Int) {
        mutateBuffer { scrollDown(&$0, count: max(1, count)) }
    }

    private func scrollDown(_ buffer: inout Buffer, count: Int) {
        let amount = min(count, buffer.scrollBottom - buffer.scrollTop + 1)
        for _ in 0..<amount {
            buffer.lines.remove(at: buffer.scrollBottom)
            buffer.lines.insert(blankLine(), at: buffer.scrollTop)
        }
    }

    private func setScrollRegion(_ parameters: [Int]) {
        mutateBuffer { buffer in
            let top = parameter(parameters, at: 0, default: 1) - 1
            let bottom = parameter(parameters, at: 1, default: rows) - 1
            if top >= 0, bottom < rows, top < bottom {
                buffer.scrollTop = top
                buffer.scrollBottom = bottom
                buffer.cursor = Cursor()
                buffer.pendingWrap = false
            }
        }
    }

    private func setModes(_ parameters: [Int], privateMarker: UInt8?, enabled: Bool) {
        if privateMarker == 0x3F {
            for mode in parameters {
                switch mode {
                case 7:
                    usesAutoWrap = enabled
                case 47, 1047, 1049:
                    if enabled {
                        if mode == 1049 { primary.savedCursor = primary.cursor }
                        alternate = Buffer(columns: columns, rows: rows)
                        usesAlternateScreen = true
                    } else {
                        usesAlternateScreen = false
                        if mode == 1049 { restoreCursor() }
                    }
                default:
                    break
                }
            }
        } else {
            for mode in parameters where mode == 4 {
                usesInsertMode = enabled
            }
        }
    }

    private func reset() {
        primary = Buffer(columns: columns, rows: rows)
        alternate = Buffer(columns: columns, rows: rows)
        scrollback.removeAll(keepingCapacity: true)
        usesAlternateScreen = false
        usesAutoWrap = true
        usesInsertMode = false
        currentStyle = .default
    }

    private func resized(
        _ source: Buffer,
        columns targetColumns: Int,
        rows targetRows: Int,
        preservesHistory: Bool
    ) -> Buffer {
        var lines = source.lines.map { line -> [Cell] in
            if line.count > targetColumns { return Array(line.prefix(targetColumns)) }
            if line.count < targetColumns {
                return line + Array(repeating: blankCell(), count: targetColumns - line.count)
            }
            return line
        }
        if lines.count > targetRows {
            let removed = lines.prefix(lines.count - targetRows)
            if preservesHistory {
                removed.map(renderedLine).forEach(appendScrollback)
            }
            lines.removeFirst(lines.count - targetRows)
        } else if lines.count < targetRows {
            lines.append(contentsOf: Array(
                repeating: Array(repeating: blankCell(), count: targetColumns),
                count: targetRows - lines.count
            ))
        }
        var result = Buffer(columns: targetColumns, rows: targetRows)
        result.lines = lines
        result.cursor = Cursor(
            row: min(targetRows - 1, source.cursor.row),
            column: min(targetColumns - 1, source.cursor.column)
        )
        result.savedCursor = Cursor(
            row: min(targetRows - 1, source.savedCursor.row),
            column: min(targetColumns - 1, source.savedCursor.column)
        )
        result.scrollTop = min(targetRows - 1, source.scrollTop)
        result.scrollBottom = min(targetRows - 1, max(result.scrollTop, source.scrollBottom))
        result.pendingWrap = source.pendingWrap && result.cursor.column == targetColumns - 1
        return result
    }

    private func mutateBuffer(_ mutation: (inout Buffer) -> Void) {
        var buffer = activeBuffer
        mutation(&buffer)
        activeBuffer = buffer
    }

    private func blankLine() -> [Cell] {
        Array(repeating: blankCell(), count: columns)
    }

    private func blankCell() -> Cell {
        Cell(text: "", isContinuation: false, style: currentStyle)
    }

    private func erase(_ line: inout [Cell], from lower: Int, through upper: Int) {
        guard lower <= upper else { return }
        for index in max(0, lower)...min(line.count - 1, upper) {
            line[index] = blankCell()
        }
    }

    private func renderedLine(_ line: [Cell]) -> LocalLinuxTerminalLinePresentation {
        let end = visibleCellEndIndex(in: line)

        var plainText = ""
        var lightAttributedText = AttributedString()
        var darkAttributedText = AttributedString()
        var runText = ""
        var runStyle: LocalLinuxTerminalStyle?

        func flushRun() {
            guard let runStyle, !runText.isEmpty else { return }
            lightAttributedText.append(runStyle.attributedString(runText, appearance: .light))
            darkAttributedText.append(runStyle.attributedString(runText, appearance: .dark))
            runText.removeAll(keepingCapacity: true)
        }

        for cell in line.prefix(end) where !cell.isContinuation {
            let text = cell.text.isEmpty ? " " : cell.text
            plainText.append(text)
            if runStyle != cell.style {
                flushRun()
                runStyle = cell.style
            }
            runText.append(text)
        }
        flushRun()
        return LocalLinuxTerminalLinePresentation(
            plainText: plainText,
            lightAttributedText: lightAttributedText,
            darkAttributedText: darkAttributedText
        )
    }

    private func renderedPlainText(_ line: [Cell]) -> String {
        var result = ""
        for cell in line.prefix(visibleCellEndIndex(in: line)) where !cell.isContinuation {
            result.append(cell.text.isEmpty ? " " : cell.text)
        }
        return result
    }

    private func visibleCellEndIndex(in line: [Cell]) -> Int {
        var end = line.count
        while end > 0 {
            let cell = line[end - 1]
            if cell.isContinuation {
                end -= 1
                continue
            }
            let isBlank = cell.text.isEmpty || cell.text == " "
            guard isBlank, !cell.style.keepsTrailingBlankVisible else { break }
            end -= 1
        }
        return end
    }

    private func appendScrollback(_ line: LocalLinuxTerminalLinePresentation) {
        guard scrollbackLimit > 0 else { return }
        scrollback.append(line)
        if scrollback.count > scrollbackLimit {
            scrollback.removeFirst(scrollback.count - scrollbackLimit)
        }
    }

    private func characterWidth(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        let value = scalar.value
        switch value {
        case 0x1100...0x115F, 0x2329...0x232A, 0x2E80...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19,
             0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1FAFF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}
