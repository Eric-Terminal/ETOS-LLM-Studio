// ============================================================================
// MCPNativeCapabilitySupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 原生系统工具共用的安全策略、受控文件 URI 和 JSON 输出辅助。
// ============================================================================

import Foundation

enum MCPNativeCapabilityError: LocalizedError {
    case missingArgument(String)
    case invalidArgument(String)
    case unsupportedTool(String)
    case unavailable(String)
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            return String(format: NSLocalizedString("缺少参数：%@", comment: "Missing native MCP argument"), name)
        case .invalidArgument(let message), .unavailable(let message), .permissionDenied(let message):
            return message
        case .unsupportedTool(let name):
            return String(format: NSLocalizedString("不支持的原生工具：%@", comment: "Unsupported native MCP tool"), name)
        }
    }
}

enum MCPNativeCapabilityPolicy {
    private static let perCallApprovalToolIDs: Set<String> = [
        "health.write_quantity",
        "health.write_category",
        "calendar.create_event",
        "calendar.update_event",
        "calendar.delete_event",
        "reminder.create_reminder",
        "reminder.update_reminder",
        "reminder.delete_reminder",
        "contacts.create",
        "contacts.update",
        "contacts.delete",
        "photos.export_asset",
        "photos.save_asset",
        "photos.create_album",
        "photos.add_to_album",
        "clipboard.write",
        "clipboard.clear",
        "notifications.schedule",
        "notifications.cancel",
        "notifications.remove_delivered",
        "alarms.schedule",
        "alarms.cancel",
        "maps.open",
        "device.open_url",
        "speech.speak",
        "speech.stop",
        "media.play_file",
        "media.pause",
        "media.resume",
        "media.stop",
        "home.write_characteristic",
        "home.execute_scene",
        "bluetooth.connect",
        "bluetooth.write_characteristic",
        "bluetooth.subscribe",
        "nfc.scan",
        "nfc.read_ndef",
        "nfc.write_ndef"
    ]

    static func requiresPerCallApproval(_ toolID: String) -> Bool {
        perCallApprovalToolIDs.contains(toolID)
    }
}

enum MCPNativeFileAccess {
    static func readableURL(for appURI: String) throws -> URL {
        let url = try controlledURL(for: appURI, allowMissingLeaf: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw MCPBuiltInPersonalDataError.invalidArgument(
                NSLocalizedString("指定的 app:// 文件不存在或不是普通文件。", comment: "Native tool input file missing")
            )
        }
        return url
    }

    static func writableURL(for appURI: String, createParentDirectories: Bool = true) throws -> URL {
        let url = try controlledURL(for: appURI, allowMissingLeaf: true)
        let parent = url.deletingLastPathComponent()
        if createParentDirectories {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try validateResolvedURL(parent)
        return url
    }

    static func appURI(for url: URL) -> String {
        let root = StorageUtility.documentsDirectory.standardizedFileURL
        let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "app://" + relative
    }

    private static func controlledURL(for appURI: String, allowMissingLeaf: Bool) throws -> URL {
        let trimmed = appURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("app://") else {
            throw MCPBuiltInPersonalDataError.invalidArgument(
                NSLocalizedString("文件参数必须使用 app:// Documents 受控 URI。", comment: "Native tool requires app URI")
            )
        }
        let relativePath = String(trimmed.dropFirst("app://".count))
        let url = try SandboxFileToolSupport.resolveURL(
            relativePath: relativePath,
            rootDirectory: StorageUtility.documentsDirectory,
            allowRoot: false
        )
        if allowMissingLeaf {
            try validateResolvedURL(url.deletingLastPathComponent())
        } else {
            try validateResolvedURL(url)
        }
        return url
    }

    private static func validateResolvedURL(_ url: URL) throws {
        let root = StorageUtility.documentsDirectory.resolvingSymlinksInPath().standardizedFileURL
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else {
            throw MCPBuiltInPersonalDataError.invalidArgument(
                NSLocalizedString("app:// 路径不能通过符号链接离开 Documents。", comment: "Native tool app URI escaped through symlink")
            )
        }
    }
}

enum MCPNativeJSON {
    static func text(_ object: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw MCPClientError.invalidResponse
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard let value = String(data: data, encoding: .utf8) else {
            throw MCPClientError.invalidResponse
        }
        return value
    }
}

extension Dictionary where Key == String, Value == Any {
    func nativeString(_ key: String) -> String? {
        (self[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func nativeRequiredString(_ key: String) throws -> String {
        guard let value = nativeString(key), !value.isEmpty else {
            throw MCPNativeCapabilityError.missingArgument(key)
        }
        return value
    }

    func nativeDouble(_ key: String) -> Double? {
        if let value = self[key] as? NSNumber { return value.doubleValue }
        return nativeString(key).flatMap(Double.init)
    }

    func nativeRequiredDouble(_ key: String) throws -> Double {
        guard let value = nativeDouble(key) else {
            throw MCPNativeCapabilityError.missingArgument(key)
        }
        return value
    }

    func nativeInt(_ key: String) -> Int? {
        if let value = self[key] as? NSNumber { return value.intValue }
        return nativeString(key).flatMap(Int.init)
    }

    func nativeBool(_ key: String) -> Bool? {
        if let value = self[key] as? Bool { return value }
        if let value = self[key] as? NSNumber { return value.boolValue }
        switch nativeString(key)?.lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    func nativeRequiredStringArray(_ key: String) throws -> [String] {
        guard let values = self[key] as? [Any] else {
            throw MCPNativeCapabilityError.missingArgument(key)
        }
        let strings = values.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !strings.isEmpty, strings.count == values.count else {
            throw MCPNativeCapabilityError.invalidArgument(
                String(format: NSLocalizedString("%@ 必须是非空字符串数组。", comment: "Invalid native MCP string array"), key)
            )
        }
        return strings
    }

    func nativeDate(_ key: String) throws -> Date? {
        guard let value = nativeString(key), !value.isEmpty else { return nil }
        guard let date = MCPBuiltInPersonalDataDateCodec.parse(value) else {
            throw MCPNativeCapabilityError.invalidArgument(
                String(format: NSLocalizedString("%@ 必须是 ISO-8601 时间。", comment: "Invalid native MCP ISO date"), key)
            )
        }
        return date
    }

    func nativeRequiredDate(_ key: String) throws -> Date {
        guard let value = try nativeDate(key) else {
            throw MCPNativeCapabilityError.missingArgument(key)
        }
        return value
    }
}
