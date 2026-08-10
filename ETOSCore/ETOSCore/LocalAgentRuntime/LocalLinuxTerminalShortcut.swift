// ============================================================================
// LocalLinuxTerminalShortcut.swift
// ============================================================================
// ETOS LLM Studio
//
// 本地 Linux 终端快捷键目录及其持久化顺序。
// ============================================================================

import Foundation

public enum LocalLinuxTerminalShortcut: String, CaseIterable, Hashable, Identifiable, Sendable {
    case escape
    case tab
    case controlA
    case controlC
    case controlD
    case controlE
    case controlK
    case controlL
    case controlR
    case controlU
    case controlW
    case controlZ
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case home
    case end
    case pageUp
    case pageDown

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .escape: return NSLocalizedString("Esc", comment: "终端快捷键")
        case .tab: return NSLocalizedString("Tab", comment: "终端快捷键")
        case .controlA: return NSLocalizedString("Ctrl-A", comment: "终端快捷键")
        case .controlC: return NSLocalizedString("Ctrl-C", comment: "终端快捷键")
        case .controlD: return NSLocalizedString("Ctrl-D", comment: "终端快捷键")
        case .controlE: return NSLocalizedString("Ctrl-E", comment: "终端快捷键")
        case .controlK: return NSLocalizedString("Ctrl-K", comment: "终端快捷键")
        case .controlL: return NSLocalizedString("Ctrl-L", comment: "终端快捷键")
        case .controlR: return NSLocalizedString("Ctrl-R", comment: "终端快捷键")
        case .controlU: return NSLocalizedString("Ctrl-U", comment: "终端快捷键")
        case .controlW: return NSLocalizedString("Ctrl-W", comment: "终端快捷键")
        case .controlZ: return NSLocalizedString("Ctrl-Z", comment: "终端快捷键")
        case .arrowUp: return NSLocalizedString("↑", comment: "终端上方向键")
        case .arrowDown: return NSLocalizedString("↓", comment: "终端下方向键")
        case .arrowLeft: return NSLocalizedString("←", comment: "终端左方向键")
        case .arrowRight: return NSLocalizedString("→", comment: "终端右方向键")
        case .home: return NSLocalizedString("Home", comment: "终端快捷键")
        case .end: return NSLocalizedString("End", comment: "终端快捷键")
        case .pageUp: return NSLocalizedString("PgUp", comment: "终端快捷键")
        case .pageDown: return NSLocalizedString("PgDn", comment: "终端快捷键")
        }
    }

    public var inputData: Data {
        switch self {
        case .escape: return Data([0x1B])
        case .tab: return Data([0x09])
        case .controlA: return Data([0x01])
        case .controlC: return Data([0x03])
        case .controlD: return Data([0x04])
        case .controlE: return Data([0x05])
        case .controlK: return Data([0x0B])
        case .controlL: return Data([0x0C])
        case .controlR: return Data([0x12])
        case .controlU: return Data([0x15])
        case .controlW: return Data([0x17])
        case .controlZ: return Data([0x1A])
        case .arrowUp: return Data("\u{1B}[A".utf8)
        case .arrowDown: return Data("\u{1B}[B".utf8)
        case .arrowLeft: return Data("\u{1B}[D".utf8)
        case .arrowRight: return Data("\u{1B}[C".utf8)
        case .home: return Data("\u{1B}[H".utf8)
        case .end: return Data("\u{1B}[F".utf8)
        case .pageUp: return Data("\u{1B}[5~".utf8)
        case .pageDown: return Data("\u{1B}[6~".utf8)
        }
    }
}

public enum LocalLinuxTerminalShortcutConfiguration {
    public static let defaults: [LocalLinuxTerminalShortcut] = [
        .escape,
        .tab,
        .controlC,
        .controlZ,
        .arrowUp,
        .arrowDown,
        .arrowLeft,
        .arrowRight,
        .controlD
    ]

    public static let defaultEncodedValue = "escape,tab,controlC,controlZ,arrowUp,arrowDown,arrowLeft,arrowRight,controlD"

    public static func decode(_ rawValue: String) -> [LocalLinuxTerminalShortcut] {
        var seen = Set<LocalLinuxTerminalShortcut>()
        return rawValue.split(separator: ",").compactMap { identifier in
            guard let shortcut = LocalLinuxTerminalShortcut(rawValue: String(identifier)),
                  seen.insert(shortcut).inserted else {
                return nil
            }
            return shortcut
        }
    }

    public static func encode(_ shortcuts: [LocalLinuxTerminalShortcut]) -> String {
        shortcuts.map(\.rawValue).joined(separator: ",")
    }
}
