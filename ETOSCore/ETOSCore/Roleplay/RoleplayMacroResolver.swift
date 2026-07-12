// ============================================================================
// RoleplayMacroResolver.swift
// ============================================================================
// ETOS LLM Studio
//
// 对照 SillyTavern 与酒馆助手的宏语义，解析角色、Persona、消息和变量宏。
// ============================================================================

import Foundation

public struct RoleplayMacroContext: Sendable {
    public var character: RoleplayCharacter?
    public var persona: PersonaProfile?
    public var variables: RoleplayVariableSnapshot
    public var messageID: UUID?
    public var messageVersionIndex: Int
    public var lastMessage: String
    public var lastUserMessage: String
    public var lastCharacterMessage: String
    public var userAvatarPath: String
    public var characterAvatarPath: String
    public var currentSwipeID: Int?
    public var lastSwipeID: Int?
    public var messageCount: Int
    public var now: Date
    public var locale: Locale
    public var chatSeed: String
    public var customValues: [String: String]

    public init(
        character: RoleplayCharacter? = nil,
        persona: PersonaProfile? = nil,
        variables: RoleplayVariableSnapshot = .init(),
        messageID: UUID? = nil,
        messageVersionIndex: Int = 0,
        lastMessage: String = "",
        lastUserMessage: String = "",
        lastCharacterMessage: String = "",
        userAvatarPath: String = "",
        characterAvatarPath: String = "",
        currentSwipeID: Int? = nil,
        lastSwipeID: Int? = nil,
        messageCount: Int = 0,
        now: Date = Date(),
        locale: Locale = .current,
        chatSeed: String = "",
        customValues: [String: String] = [:]
    ) {
        self.character = character
        self.persona = persona
        self.variables = variables
        self.messageID = messageID
        self.messageVersionIndex = max(0, messageVersionIndex)
        self.lastMessage = lastMessage
        self.lastUserMessage = lastUserMessage
        self.lastCharacterMessage = lastCharacterMessage
        self.userAvatarPath = userAvatarPath
        self.characterAvatarPath = characterAvatarPath
        self.currentSwipeID = currentSwipeID
        self.lastSwipeID = lastSwipeID
        self.messageCount = max(0, messageCount)
        self.now = now
        self.locale = locale
        self.chatSeed = chatSeed
        self.customValues = customValues
    }
}

public enum RoleplayMacroResolver {
    public static func resolve(_ input: String, context: RoleplayMacroContext) -> String {
        var context = context
        return resolve(input, context: &context)
    }

    public static func resolve(_ input: String, context: inout RoleplayMacroContext) -> String {
        guard input.contains("{{") || input.range(of: #"<(?:USER|BOT|CHAR|GROUP|CHARIFNOTGROUP)>"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return input
        }
        var output = replaceLegacyNames(in: input, context: context)
        output = replaceMacroComments(in: output)
        output = replaceTrimMacros(in: output)
        output = replaceCustomMacros(in: output, values: context.customValues)
        output = replaceSetVariableMacros(in: output, context: &context)
        output = replaceVariableMacros(output, context: context, formatted: true)
        output = replaceVariableMacros(output, context: context, formatted: false)
        output = replaceListMacro(output, name: "random") { values, _ in
            values.randomElement() ?? ""
        }
        output = replaceListMacro(output, name: "pick") { values, offset in
            guard !values.isEmpty else { return "" }
            let seed = "\(context.chatSeed)|\(input)|\(offset)"
            return values[Int(stableHash(seed) % UInt64(values.count))]
        }
        output = replaceRollMacros(output)
        output = replaceSimpleMacros(output, values: simpleValues(context))
        output = replaceReverseMacros(in: output)
        output = replaceUTCtimeMacros(in: output, context: context)
        output = replaceDateFormatMacros(in: output, context: context)
        return output
    }

    public static func resolveWorldbookOutlets(_ input: String, outlets: [String: String]) -> String {
        guard input.range(of: "{{outlet::", options: .caseInsensitive) != nil,
              let regex = try? NSRegularExpression(
                pattern: #"\{\{\s*outlet::(.+?)\}\}"#,
                options: [.caseInsensitive]
              ) else {
            return input
        }
        let source = input as NSString
        let result = NSMutableString(string: input)
        for match in regex.matches(in: input, range: NSRange(location: 0, length: source.length)).reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let key = source.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result.replaceCharacters(in: match.range, with: outlets[key] ?? "")
        }
        return result as String
    }

    private static func simpleValues(_ context: RoleplayMacroContext) -> [String: String] {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = context.locale
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none

        let timeFormatter = DateFormatter()
        timeFormatter.locale = context.locale
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short

        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = context.locale
        weekdayFormatter.dateFormat = "EEEE"

        let isoDateFormatter = DateFormatter()
        isoDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        isoDateFormatter.dateFormat = "yyyy-MM-dd"

        let isoTimeFormatter = DateFormatter()
        isoTimeFormatter.locale = Locale(identifier: "en_US_POSIX")
        isoTimeFormatter.dateFormat = "HH:mm"

        var values: [String: String] = [
            "user": context.persona?.name ?? "User",
            "user-name": context.persona?.name ?? "User",
            "persona": context.persona?.description ?? "",
            "char": context.character?.name ?? "Assistant",
            "description": context.character?.description ?? "",
            "personality": context.character?.personality ?? "",
            "scenario": context.character?.scenario ?? "",
            "mesexamples": context.character?.messageExamples ?? "",
            "systemprompt": context.character?.systemPrompt ?? "",
            "posthistoryinstructions": context.character?.postHistoryInstructions ?? "",
            "lastmessage": context.lastMessage,
            "lastusermessage": context.lastUserMessage,
            "lastcharmessage": context.lastCharacterMessage,
            "useravatarpath": context.userAvatarPath,
            "charavatarpath": context.characterAvatarPath,
            "currentswipeid": context.currentSwipeID.map(String.init) ?? "",
            "lastswipeid": context.lastSwipeID.map(String.init) ?? "",
            "lastmessageid": context.messageCount > 0 ? String(context.messageCount - 1) : "",
            "firstincludedmessageid": context.messageCount > 0 ? "0" : "",
            "firstdisplayedmessageid": context.messageCount > 0 ? "0" : "",
            "date": dateFormatter.string(from: context.now),
            "time": timeFormatter.string(from: context.now),
            "weekday": weekdayFormatter.string(from: context.now),
            "isodate": isoDateFormatter.string(from: context.now),
            "isotime": isoTimeFormatter.string(from: context.now),
            "newline": "\n",
            "noop": "",
            "input": context.lastUserMessage,
            "group": context.character?.name ?? "Assistant",
            "charifnotgroup": context.character?.name ?? "Assistant",
            "ismobile": "true"
        ]
        for (key, value) in context.customValues {
            values[key.lowercased()] = value
        }
        return values
    }

    private static func replaceLegacyNames(in input: String, context: RoleplayMacroContext) -> String {
        let values = [
            "<USER>": context.persona?.name ?? "User",
            "<BOT>": context.character?.name ?? "Assistant",
            "<CHAR>": context.character?.name ?? "Assistant",
            "<GROUP>": context.character?.name ?? "Assistant",
            "<CHARIFNOTGROUP>": context.character?.name ?? "Assistant"
        ]
        return values.reduce(input) { output, item in
            output.replacingOccurrences(of: item.key, with: item.value, options: .caseInsensitive)
        }
    }

    private static func replaceSetVariableMacros(
        in input: String,
        context: inout RoleplayMacroContext
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\{\{\s*(setvar|setglobalvar)::([^:}]+)::([^}]*)\}\}"#,
            options: [.caseInsensitive]
        ) else { return input }
        let source = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return input }

        for match in matches where match.numberOfRanges > 3 {
            let command = source.substring(with: match.range(at: 1)).lowercased()
            let path = source.substring(with: match.range(at: 2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            let value = source.substring(with: match.range(at: 3))
            context.variables.setValue(
                .string(value),
                scope: command == "setglobalvar" ? .global : .chat,
                path: path,
                messageID: context.messageID,
                versionIndex: context.messageVersionIndex
            )
        }

        let result = NSMutableString(string: input)
        for match in matches.reversed() {
            result.replaceCharacters(in: match.range, with: "")
        }
        return result as String
    }

    private static func replaceMacroComments(in input: String) -> String {
        input.replacingOccurrences(
            of: #"\{\{\/\/[\s\S]*?\}\}"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func replaceTrimMacros(in input: String) -> String {
        input.replacingOccurrences(
            of: #"(?:\r?\n)*\{\{\s*trim\s*\}\}(?:\r?\n)*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private static func replaceReverseMacros(in input: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\s*reverse:(.+?)\}\}"#, options: [.caseInsensitive]) else {
            return input
        }
        let source = input as NSString
        let result = NSMutableString(string: input)
        for match in regex.matches(in: input, range: NSRange(location: 0, length: source.length)).reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let value = source.substring(with: match.range(at: 1))
            result.replaceCharacters(in: match.range, with: String(value.reversed()))
        }
        return result as String
    }

    private static func replaceUTCtimeMacros(in input: String, context: RoleplayMacroContext) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\s*time_UTC([-+]\d+)\s*\}\}"#, options: [.caseInsensitive]) else {
            return input
        }
        let source = input as NSString
        let result = NSMutableString(string: input)
        for match in regex.matches(in: input, range: NSRange(location: 0, length: source.length)).reversed() {
            guard match.numberOfRanges > 1,
                  let offset = Int(source.substring(with: match.range(at: 1))),
                  (-24...24).contains(offset) else { continue }
            let formatter = DateFormatter()
            formatter.locale = context.locale
            formatter.timeZone = TimeZone(secondsFromGMT: offset * 3600)
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            result.replaceCharacters(in: match.range, with: formatter.string(from: context.now))
        }
        return result as String
    }

    private static func replaceDateFormatMacros(in input: String, context: RoleplayMacroContext) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\s*datetimeformat\s+([^}]+)\}\}"#, options: [.caseInsensitive]) else {
            return input
        }
        let source = input as NSString
        let result = NSMutableString(string: input)
        for match in regex.matches(in: input, range: NSRange(location: 0, length: source.length)).reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let momentFormat = source.substring(with: match.range(at: 1))
            let format = momentFormat
                .replacingOccurrences(of: "YYYY", with: "yyyy")
                .replacingOccurrences(of: "dddd", with: "EEEE")
                .replacingOccurrences(of: "DD", with: "dd")
            let formatter = DateFormatter()
            formatter.locale = context.locale
            formatter.dateFormat = format
            result.replaceCharacters(in: match.range, with: formatter.string(from: context.now))
        }
        return result as String
    }

    private static func replaceSimpleMacros(_ input: String, values: [String: String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\{?\s*([^{}:]+?)\s*\}\}\}?"#) else {
            return input
        }
        let source = input as NSString
        let result = NSMutableString(string: input)
        for match in regex.matches(in: input, range: NSRange(location: 0, length: source.length)).reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let key = source.substring(with: match.range(at: 1)).lowercased()
            guard let value = values[key] else { continue }
            result.replaceCharacters(in: match.range, with: value)
        }
        return result as String
    }

    private static func replaceCustomMacros(in input: String, values: [String: String]) -> String {
        guard !values.isEmpty else { return input }
        let normalized = values.reduce(into: [String: String]()) { result, item in
            result[item.key.lowercased()] = item.value
        }
        var output = input
        for _ in 0..<10 {
            let updated = replaceSimpleMacros(output, values: normalized)
            guard updated != output else { break }
            output = updated
        }
        return output
    }

    private static func replaceVariableMacros(
        _ input: String,
        context: RoleplayMacroContext,
        formatted: Bool
    ) -> String {
        let prefix = formatted ? "format" : "get"
        let pattern = #"\{\{\{?\s*"# + prefix + #"_(message|chat|character|preset|global)_variable::(.*?)\}\}\}?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return input }
        let source = input as NSString
        let result = NSMutableString(string: input)
        for match in regex.matches(in: input, range: NSRange(location: 0, length: source.length)).reversed() {
            guard match.numberOfRanges > 2 else { continue }
            let rawScope = source.substring(with: match.range(at: 1)).lowercased()
            let path = source.substring(with: match.range(at: 2))
            guard let scope = variableScope(rawScope),
                  let value = context.variables.value(
                    scope: scope,
                    path: path,
                    messageID: context.messageID,
                    versionIndex: context.messageVersionIndex
                  ) else {
                result.replaceCharacters(in: match.range, with: formatted ? "null" : "null")
                continue
            }
            result.replaceCharacters(in: match.range, with: string(value, formatted: formatted))
        }

        guard !formatted else { return result as String }
        return replaceMergedVariableMacros(result as String, context: context)
    }

    private static func replaceMergedVariableMacros(_ input: String, context: RoleplayMacroContext) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\{\{\{?\s*(?:getvar|get_variable)::(.*?)\}\}\}?"#,
            options: [.caseInsensitive]
        ) else { return input }
        let source = input as NSString
        let result = NSMutableString(string: input)
        let merged = context.variables.mergedVariables(
            messageID: context.messageID,
            versionIndex: context.messageVersionIndex
        )
        for match in regex.matches(in: input, range: NSRange(location: 0, length: source.length)).reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let path = source.substring(with: match.range(at: 1))
            let value = value(at: path, in: merged).map { string($0, formatted: false) } ?? "null"
            result.replaceCharacters(in: match.range, with: value)
        }
        return result as String
    }

    private static func replaceListMacro(
        _ input: String,
        name: String,
        select: ([String], Int) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\{\{\s*"# + NSRegularExpression.escapedPattern(for: name) + #"\s*::?\s*([^}]+)\}\}"#,
            options: [.caseInsensitive]
        ) else { return input }
        let source = input as NSString
        let result = NSMutableString(string: input)
        for match in regex.matches(in: input, range: NSRange(location: 0, length: source.length)).reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let raw = source.substring(with: match.range(at: 1))
            let values: [String]
            if raw.contains("::") {
                values = raw.components(separatedBy: "::")
            } else {
                values = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            result.replaceCharacters(in: match.range, with: select(values, match.range.location))
        }
        return result as String
    }

    private static func replaceRollMacros(_ input: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\{\{\s*roll(?:\s*::?|\s+)([^}]+)\}\}"#,
            options: [.caseInsensitive]
        ) else { return input }
        let source = input as NSString
        let result = NSMutableString(string: input)
        for match in regex.matches(in: input, range: NSRange(location: 0, length: source.length)).reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let formula = source.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = roll(formula) else { continue }
            result.replaceCharacters(in: match.range, with: String(value))
        }
        return result as String
    }

    private static func roll(_ formula: String) -> Int? {
        if let sides = Int(formula), sides > 0 { return Int.random(in: 1...sides) }
        guard let regex = try? NSRegularExpression(
            pattern: #"^(\d*)[dD](\d+)(?:\s*([+-])\s*(\d+))?$"#
        ) else { return nil }
        let source = formula as NSString
        guard let match = regex.firstMatch(in: formula, range: NSRange(location: 0, length: source.length)) else { return nil }
        let countText = match.range(at: 1).location == NSNotFound ? "" : source.substring(with: match.range(at: 1))
        let count = countText.isEmpty ? 1 : (Int(countText) ?? 1)
        let sides = Int(source.substring(with: match.range(at: 2))) ?? 0
        guard (1...1000).contains(count), (1...1_000_000).contains(sides) else { return nil }
        var total = (0..<count).reduce(0) { partial, _ in partial + Int.random(in: 1...sides) }
        if match.range(at: 4).location != NSNotFound {
            let modifier = Int(source.substring(with: match.range(at: 4))) ?? 0
            total += source.substring(with: match.range(at: 3)) == "-" ? -modifier : modifier
        }
        return total
    }

    private static func variableScope(_ raw: String) -> RoleplayVariableScope? {
        switch raw {
        case "message": return .message
        case "chat": return .chat
        case "character": return .character
        case "preset": return .preset
        case "global": return .global
        default: return nil
        }
    }

    private static func string(_ value: JSONValue, formatted: Bool) -> String {
        if case .string(let value) = value { return value }
        let encoder = JSONEncoder()
        if formatted { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        guard let data = try? encoder.encode(value), let output = String(data: data, encoding: .utf8) else { return "null" }
        return output
    }

    private static func value(at path: String, in root: [String: JSONValue]) -> JSONValue? {
        let snapshot = RoleplayVariableSnapshot(chat: root)
        return snapshot.value(scope: .chat, path: path)
    }

    private static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}
