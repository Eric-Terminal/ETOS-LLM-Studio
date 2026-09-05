// ============================================================================
// PromptMacroResolver.swift
// ============================================================================
// 普通聊天提示词的只读宏；一次替换只处理模板本身，不递归解释变量值。
// ============================================================================

import Foundation

struct PromptMacroTemplates: Sendable, Equatable {
    var global: String?
    var conversation: String?
    var topic: String?
    var enhanced: String?

    var texts: [String] {
        [global, conversation, topic, enhanced].compactMap { $0 }
    }

    func rendered(values: [String: String]) -> Self {
        Self(
            global: global.map { PromptMacroResolver.render($0, values: values) },
            conversation: conversation.map { PromptMacroResolver.render($0, values: values) },
            topic: topic.map { PromptMacroResolver.render($0, values: values) },
            enhanced: enhanced.map { PromptMacroResolver.render($0, values: values) }
        )
    }
}

enum PromptMacroResolver {
    static let timeNames: Set<String> = [
        "cur_date", "cur_time", "cur_datetime", "utc_datetime", "weekday", "timestamp",
        "timezone", "timezone_offset"
    ]
    static let batteryNames: Set<String> = ["battery_level", "battery_state", "is_charging"]
    static let supportedNames: Set<String> = timeNames.union(batteryNames).union([
        "model_id", "model_name", "provider_id", "provider_name", "api_format",
        "nickname", "user", "char", "assistant_name", "chat_id", "chat_name", "message_count",
        "locale", "language", "system_locale", "app_name", "app_version", "app_build",
        "platform", "system_version", "device_info", "device_model", "device_name",
        "low_power_mode", "thermal_state", "system_uptime"
    ])

    // 括号边界避免把未闭合或三重括号模板的一部分误识别成单括号宏。
    private static let expression = try! NSRegularExpression(
        pattern: #"(?<!\{)(?:\{\{\s*([a-z_][a-z0-9_]*)\s*\}\}|\{\s*([a-z_][a-z0-9_]*)\s*\})(?!\})"#,
        options: [.caseInsensitive]
    )

    static func referencedNames(in templates: [String]) -> Set<String> {
        var names: Set<String> = []
        for template in templates {
            let source = template as NSString
            for match in expression.matches(in: template, range: NSRange(location: 0, length: source.length)) {
                let name = macroName(in: match, source: source)
                if supportedNames.contains(name) {
                    names.insert(name)
                }
            }
        }
        return names
    }

    static func render(_ template: String, values: [String: String]) -> String {
        let source = template as NSString
        let matches = expression.matches(in: template, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return template }

        var parts: [String] = []
        var cursor = 0
        for match in matches {
            parts.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            let name = macroName(in: match, source: source)
            if supportedNames.contains(name), let value = values[name] {
                parts.append(value)
            } else {
                // 未知宏留给原有角色宏、脚本或用户文本，不静默删除。
                parts.append(source.substring(with: match.range))
            }
            cursor = NSMaxRange(match.range)
        }
        parts.append(source.substring(from: cursor))
        return parts.joined()
    }

    static func timeValues(now: Date, locale: Locale, timeZone: TimeZone) -> [String: String] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: now)
        formatter.dateFormat = "HH:mm:ss"
        let time = formatter.string(from: now)
        formatter.locale = locale
        formatter.dateFormat = "EEEE"
        let weekday = formatter.string(from: now)

        let offset = timeZone.secondsFromGMT(for: now)
        let offsetMinutes = abs(offset) / 60
        let offsetString = String(format: "%@%02d:%02d", offset >= 0 ? "+" : "-", offsetMinutes / 60, offsetMinutes % 60)
        return [
            "cur_date": date,
            "cur_time": time,
            "cur_datetime": "\(date) \(time)",
            "utc_datetime": ISO8601DateFormatter().string(from: now),
            "weekday": weekday,
            "timestamp": String(Int64(now.timeIntervalSince1970)),
            "timezone": timeZone.identifier,
            "timezone_offset": offsetString
        ]
    }

    private static func macroName(in match: NSTextCheckingResult, source: NSString) -> String {
        let range = match.range(at: 1).location == NSNotFound ? match.range(at: 2) : match.range(at: 1)
        return source.substring(with: range).lowercased()
    }
}
