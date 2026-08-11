// ============================================================================
// LocalLinuxTerminalShortcut.swift
// ============================================================================
// ETOS LLM Studio
//
// 本地 Linux 终端快捷键的数据模型与 PTY 字节编码。
// ============================================================================

import Foundation

/// 可加入终端快捷键组合的单个按键。
public enum LocalLinuxTerminalKey: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case control
    case option
    case shift
    case escape
    case tab
    case enter
    case backspace
    case space
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z
    case digit0, digit1, digit2, digit3, digit4
    case digit5, digit6, digit7, digit8, digit9
    case grave
    case minus
    case equal
    case leftBracket
    case rightBracket
    case backslash
    case semicolon
    case apostrophe
    case comma
    case period
    case slash
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case home
    case end
    case pageUp
    case pageDown

    public var id: String { rawValue }

    public var isModifier: Bool {
        switch self {
        case .control, .option, .shift:
            return true
        default:
            return false
        }
    }

    public var title: String {
        switch self {
        case .control: NSLocalizedString("Ctrl", comment: "终端 Control 修饰键")
        case .option: NSLocalizedString("Alt", comment: "终端 Option/Alt 修饰键")
        case .shift: NSLocalizedString("Shift", comment: "终端 Shift 修饰键")
        case .escape: NSLocalizedString("Esc", comment: "终端 Escape 键")
        case .tab: NSLocalizedString("Tab", comment: "终端 Tab 键")
        case .enter: NSLocalizedString("Enter", comment: "终端回车键")
        case .backspace: NSLocalizedString("Backspace", comment: "终端退格键")
        case .space: NSLocalizedString("Space", comment: "终端空格键")
        case .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
             .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z:
            rawValue.uppercased()
        case .digit0: "0"
        case .digit1: "1"
        case .digit2: "2"
        case .digit3: "3"
        case .digit4: "4"
        case .digit5: "5"
        case .digit6: "6"
        case .digit7: "7"
        case .digit8: "8"
        case .digit9: "9"
        case .grave: "`"
        case .minus: "-"
        case .equal: "="
        case .leftBracket: "["
        case .rightBracket: "]"
        case .backslash: "\\"
        case .semicolon: ";"
        case .apostrophe: "'"
        case .comma: ","
        case .period: "."
        case .slash: "/"
        case .arrowUp: NSLocalizedString("↑", comment: "终端上方向键")
        case .arrowDown: NSLocalizedString("↓", comment: "终端下方向键")
        case .arrowLeft: NSLocalizedString("←", comment: "终端左方向键")
        case .arrowRight: NSLocalizedString("→", comment: "终端右方向键")
        case .home: NSLocalizedString("Home", comment: "终端 Home 键")
        case .end: NSLocalizedString("End", comment: "终端 End 键")
        case .pageUp: NSLocalizedString("PgUp", comment: "终端 Page Up 键")
        case .pageDown: NSLocalizedString("PgDn", comment: "终端 Page Down 键")
        }
    }

    public static let modifierKeys: [Self] = [.control, .option, .shift]
    public static let typingKeys: [Self] = [
        .escape, .tab, .enter, .backspace, .space,
        .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
        .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z,
        .digit0, .digit1, .digit2, .digit3, .digit4,
        .digit5, .digit6, .digit7, .digit8, .digit9,
        .grave, .minus, .equal, .leftBracket, .rightBracket,
        .backslash, .semicolon, .apostrophe, .comma, .period, .slash
    ]
    public static let navigationKeys: [Self] = [
        .arrowUp, .arrowDown, .arrowLeft, .arrowRight,
        .home, .end, .pageUp, .pageDown
    ]
}

/// 用户在终端快捷栏中配置的一个按键组合。
public struct LocalLinuxTerminalShortcut: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var keys: [LocalLinuxTerminalKey]

    public init(id: UUID = UUID(), keys: [LocalLinuxTerminalKey]) {
        self.id = id
        self.keys = Self.normalized(keys)
    }

    public var title: String {
        keys.map(\.title).joined(separator: " + ")
    }

    /// 一个快捷项只触发一次 PTY 写入，组合中的普通键按配置顺序连续发送。
    public var inputData: Data {
        let modifiers = Set(keys.filter(\.isModifier))
        var result = Data()
        for key in keys where !key.isModifier {
            result.append(Self.bytes(for: key, modifiers: modifiers))
        }
        return result
    }

    private static func normalized(_ keys: [LocalLinuxTerminalKey]) -> [LocalLinuxTerminalKey] {
        var seen = Set<LocalLinuxTerminalKey>()
        let unique = keys.filter { seen.insert($0).inserted }
        let modifiers = LocalLinuxTerminalKey.modifierKeys.filter(unique.contains)
        return modifiers + unique.filter { !$0.isModifier }
    }

    private static func bytes(
        for key: LocalLinuxTerminalKey,
        modifiers: Set<LocalLinuxTerminalKey>
    ) -> Data {
        let control = modifiers.contains(.control)
        let option = modifiers.contains(.option)
        let shift = modifiers.contains(.shift)

        if let sequence = navigationSequence(for: key, control: control, option: option, shift: shift) {
            return Data(sequence.utf8)
        }

        var bytes: [UInt8]
        switch key {
        case .escape:
            bytes = [0x1B]
        case .tab:
            bytes = shift ? Array("\u{1B}[Z".utf8) : [0x09]
        case .enter:
            bytes = [0x0D]
        case .backspace:
            bytes = [0x7F]
        case .space:
            bytes = control ? [0x00] : [0x20]
        default:
            guard let printable = printableByte(for: key, shift: shift) else { return Data() }
            if control, let controlByte = controlByte(for: printable) {
                bytes = [controlByte]
            } else {
                bytes = [printable]
            }
        }

        if option {
            bytes.insert(0x1B, at: 0)
        }
        return Data(bytes)
    }

    private static func navigationSequence(
        for key: LocalLinuxTerminalKey,
        control: Bool,
        option: Bool,
        shift: Bool
    ) -> String? {
        let modifier = 1 + (shift ? 1 : 0) + (option ? 2 : 0) + (control ? 4 : 0)
        let suffix: String
        switch key {
        case .arrowUp: suffix = "A"
        case .arrowDown: suffix = "B"
        case .arrowRight: suffix = "C"
        case .arrowLeft: suffix = "D"
        case .home: suffix = "H"
        case .end: suffix = "F"
        case .pageUp:
            return modifier == 1 ? "\u{1B}[5~" : "\u{1B}[5;\(modifier)~"
        case .pageDown:
            return modifier == 1 ? "\u{1B}[6~" : "\u{1B}[6;\(modifier)~"
        default:
            return nil
        }
        return modifier == 1 ? "\u{1B}[\(suffix)" : "\u{1B}[1;\(modifier)\(suffix)"
    }

    private static func printableByte(for key: LocalLinuxTerminalKey, shift: Bool) -> UInt8? {
        if let letter = key.rawValue.utf8.first,
           key.rawValue.count == 1,
           (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(letter) {
            return shift ? letter - 32 : letter
        }

        let pair: (UInt8, UInt8)? = switch key {
        case .digit0: (UInt8(ascii: "0"), UInt8(ascii: ")"))
        case .digit1: (UInt8(ascii: "1"), UInt8(ascii: "!"))
        case .digit2: (UInt8(ascii: "2"), UInt8(ascii: "@"))
        case .digit3: (UInt8(ascii: "3"), UInt8(ascii: "#"))
        case .digit4: (UInt8(ascii: "4"), UInt8(ascii: "$"))
        case .digit5: (UInt8(ascii: "5"), UInt8(ascii: "%"))
        case .digit6: (UInt8(ascii: "6"), UInt8(ascii: "^"))
        case .digit7: (UInt8(ascii: "7"), UInt8(ascii: "&"))
        case .digit8: (UInt8(ascii: "8"), UInt8(ascii: "*"))
        case .digit9: (UInt8(ascii: "9"), UInt8(ascii: "("))
        case .grave: (UInt8(ascii: "`"), UInt8(ascii: "~"))
        case .minus: (UInt8(ascii: "-"), UInt8(ascii: "_"))
        case .equal: (UInt8(ascii: "="), UInt8(ascii: "+"))
        case .leftBracket: (UInt8(ascii: "["), UInt8(ascii: "{"))
        case .rightBracket: (UInt8(ascii: "]"), UInt8(ascii: "}"))
        case .backslash: (UInt8(ascii: "\\"), UInt8(ascii: "|"))
        case .semicolon: (UInt8(ascii: ";"), UInt8(ascii: ":"))
        case .apostrophe: (UInt8(ascii: "'"), UInt8(ascii: "\""))
        case .comma: (UInt8(ascii: ","), UInt8(ascii: "<"))
        case .period: (UInt8(ascii: "."), UInt8(ascii: ">"))
        case .slash: (UInt8(ascii: "/"), UInt8(ascii: "?"))
        default: nil
        }
        return pair.map { shift ? $0.1 : $0.0 }
    }

    private static func controlByte(for byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"):
            byte - UInt8(ascii: "A") + 1
        case UInt8(ascii: "a")...UInt8(ascii: "z"):
            byte - UInt8(ascii: "a") + 1
        case UInt8(ascii: "@"), UInt8(ascii: " "):
            0x00
        case UInt8(ascii: "["):
            0x1B
        case UInt8(ascii: "\\"):
            0x1C
        case UInt8(ascii: "]"):
            0x1D
        case UInt8(ascii: "^"):
            0x1E
        case UInt8(ascii: "_"):
            0x1F
        case UInt8(ascii: "?"):
            0x7F
        default:
            nil
        }
    }
}

/// 快捷栏持久化。JSON 支持任意组合；旧版逗号列表会在读取时无损迁移。
public enum LocalLinuxTerminalShortcutConfiguration {
    public static let defaults: [LocalLinuxTerminalShortcut] = [
        LocalLinuxTerminalShortcut(keys: [.escape]),
        LocalLinuxTerminalShortcut(keys: [.tab]),
        LocalLinuxTerminalShortcut(keys: [.control, .c]),
        LocalLinuxTerminalShortcut(keys: [.control, .z]),
        LocalLinuxTerminalShortcut(keys: [.arrowUp]),
        LocalLinuxTerminalShortcut(keys: [.arrowDown]),
        LocalLinuxTerminalShortcut(keys: [.arrowLeft]),
        LocalLinuxTerminalShortcut(keys: [.arrowRight]),
        LocalLinuxTerminalShortcut(keys: [.control, .d])
    ]

    public static let defaultEncodedValue = encode(defaults)

    public static func encode(_ shortcuts: [LocalLinuxTerminalShortcut]) -> String {
        guard let data = try? JSONEncoder().encode(shortcuts),
              let value = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return value
    }

    public static func decode(_ value: String) -> [LocalLinuxTerminalShortcut] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["),
           let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([LocalLinuxTerminalShortcut].self, from: data) {
            return decoded.map { LocalLinuxTerminalShortcut(id: $0.id, keys: $0.keys) }
        }

        let migrated = decodeLegacy(trimmed)
        return migrated.isEmpty && !trimmed.isEmpty ? defaults : migrated
    }

    private static func decodeLegacy(_ value: String) -> [LocalLinuxTerminalShortcut] {
        var seen = Set<String>()
        return value.split(separator: ",").compactMap { item in
            let rawValue = String(item)
            guard seen.insert(rawValue).inserted else { return nil }
            return legacyShortcut(rawValue)
        }
    }

    private static func legacyShortcut(_ rawValue: String) -> LocalLinuxTerminalShortcut? {
        let keys: [LocalLinuxTerminalKey]? = switch rawValue {
        case "escape": [.escape]
        case "tab": [.tab]
        case "controlA": [.control, .a]
        case "controlC": [.control, .c]
        case "controlD": [.control, .d]
        case "controlE": [.control, .e]
        case "controlK": [.control, .k]
        case "controlL": [.control, .l]
        case "controlR": [.control, .r]
        case "controlU": [.control, .u]
        case "controlW": [.control, .w]
        case "controlZ": [.control, .z]
        case "arrowUp": [.arrowUp]
        case "arrowDown": [.arrowDown]
        case "arrowLeft": [.arrowLeft]
        case "arrowRight": [.arrowRight]
        case "home": [.home]
        case "end": [.end]
        case "pageUp": [.pageUp]
        case "pageDown": [.pageDown]
        default: nil
        }
        return keys.map { LocalLinuxTerminalShortcut(keys: $0) }
    }
}
