import ETOSCore
import Foundation

enum MacRoleplayContentKind: String, Sendable {
    case regex, scripts

    var title: String {
        switch self {
        case .regex: NSLocalizedString("角色正则", comment: "")
        case .scripts: NSLocalizedString("助手脚本", comment: "")
        }
    }
}

struct MacRoleplayRegexRow: Identifiable, Sendable {
    let rule: RoleplayRegexRule
    let title: String
    let preview: String
    var id: UUID { rule.id }
}

struct MacRoleplayScriptRow: Identifiable, Sendable {
    let script: RoleplayHelperScript
    let title: String
    let preview: String
    var id: UUID { script.id }
}

struct MacRoleplayContentSnapshot: Sendable {
    let regex: [MacRoleplayRegexRow]
    let scripts: [MacRoleplayScriptRow]
    let regexGuideValue: JSONValue
    let scriptsGuideValue: JSONValue

    init(character: RoleplayCharacter) {
        regex = character.regexRules.map {
            MacRoleplayRegexRow(rule: $0, title: $0.scriptName.isEmpty ? NSLocalizedString("未命名正则", comment: "") : $0.scriptName,
                               preview: String($0.findRegex.prefix(180)))
        }
        scripts = character.helperScripts.map {
            MacRoleplayScriptRow(script: $0, title: $0.name.isEmpty ? NSLocalizedString("未命名脚本", comment: "") : $0.name,
                                preview: String($0.info.prefix(180)))
        }
        regexGuideValue = .array(regex.map {
            .dictionary(["id": .string($0.id.uuidString), "name": .string($0.title), "enabled": .bool(!$0.rule.disabled),
                         "scope": .string($0.rule.scope.rawValue)])
        })
        // 任意脚本正文与扩展元数据可能含凭据，目录快照仅公开名称和运行状态。
        scriptsGuideValue = .array(scripts.map {
            .dictionary(["id": .string($0.id.uuidString), "name": .string($0.title), "enabled": .bool($0.script.enabled),
                         "buttons": .int($0.script.buttons.count)])
        })
    }
}

struct MacRoleplayRegexDraft: Identifiable, Sendable {
    let originalCharacter: RoleplayCharacter
    var rule: RoleplayRegexRule
    var trimStringsText: String
    private let originalTrimStringsText: String
    var id: UUID { rule.id }

    /// 由后台任务构造；未编辑的修剪列表保留空白与分隔符，不能仅打开保存就改变规则语义。
    init(rule: RoleplayRegexRule, in character: RoleplayCharacter) {
        originalCharacter = character
        self.rule = rule
        trimStringsText = rule.trimStrings.joined(separator: "\n")
        originalTrimStringsText = trimStringsText
    }

    func preparedCharacter() -> RoleplayCharacter {
        var character = originalCharacter
        var rule = rule
        if trimStringsText != originalTrimStringsText {
            rule.trimStrings = trimStringsText.components(separatedBy: .newlines).filter { !$0.isEmpty }
        }
        if let index = character.regexRules.firstIndex(where: { $0.id == rule.id }) { character.regexRules[index] = rule }
        else { character.regexRules.append(rule) }
        return character
    }
}

struct MacRoleplayScriptDraft: Identifiable, Sendable {
    let originalCharacter: RoleplayCharacter
    var script: RoleplayHelperScript
    var id: UUID { script.id }

    init(script: RoleplayHelperScript, in character: RoleplayCharacter) {
        originalCharacter = character
        self.script = script
    }

    func preparedCharacter() -> RoleplayCharacter {
        var character = originalCharacter
        if let index = character.helperScripts.firstIndex(where: { $0.id == script.id }) { character.helperScripts[index] = script }
        else { character.helperScripts.append(script) }
        return character
    }
}

extension RoleplayRegexPlacement {
    var macLabel: String {
        switch self {
        case .userInput: NSLocalizedString("用户输入", comment: "")
        case .aiOutput: NSLocalizedString("模型输出", comment: "")
        case .slashCommand: NSLocalizedString("斜杠命令", comment: "")
        case .worldInfo: NSLocalizedString("世界书内容", comment: "")
        case .reasoning: NSLocalizedString("推理内容", comment: "")
        }
    }
}

extension RoleplayRegexScope {
    static let macGuideValues = ["global", "preset", "character", "session"]
    var macLabel: String {
        switch self {
        case .global: NSLocalizedString("全局", comment: "")
        case .preset: NSLocalizedString("预设", comment: "")
        case .character: NSLocalizedString("角色卡", comment: "")
        case .session: NSLocalizedString("当前会话", comment: "")
        }
    }
}
