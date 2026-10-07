import ETOSCore
import Foundation

struct MacSkillRow: Identifiable, Sendable {
    let metadata: SkillMetadata
    let enabled: Bool
    let status: String
    var id: String { metadata.name }
}

struct MacSkillDetailPresentation: Sendable {
    let source: SkillLibraryDetail
    let allowedTools: String
    let fileSizes: [String: String]
    let guideFiles: JSONValue
    let bodyCharacterCount: Int
    let policyFooter: String

    init(_ detail: SkillLibraryDetail) {
        source = detail
        allowedTools = detail.metadata.allowedTools.joined(separator: ", ")
        bodyCharacterCount = detail.body.count
        fileSizes = Dictionary(uniqueKeysWithValues: detail.files.map {
            ($0.id, StorageUtility.formatSize($0.reference.size))
        })
        guideFiles = .array(detail.files.map { .dictionary([
            "path": .string($0.id), "bytes": .int(Int(clamping: $0.reference.size)), "editable": .bool($0.editableContent != nil)
        ]) })
        policyFooter = detail.executionPolicy.record.policy == .allowCurrentVersion && !detail.executionPolicy.isCurrentVersionApproved
            ? NSLocalizedString("Skill 内容已变化，先前的当前版本授权已失效；执行时会重新询问。", comment: "")
            : NSLocalizedString("读取 Skill 文件不会执行代码。脚本参数按 argv 传递，不会自动安装缺少的解释器。", comment: "")
    }
}

enum MacSkillPresentation {
    static func prepare(skills: [SkillMetadata], enabled: Set<String>, group: Bool, isolated: Bool,
                        query: String, enabledOnly: Bool) -> ([MacSkillRow], JSONValue) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = skills.filter {
            (!enabledOnly || enabled.contains($0.name)) && (query.isEmpty ||
                [$0.name, $0.description, $0.compatibility ?? ""].contains { $0.localizedCaseInsensitiveContains(query) })
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.map { skill in
            let isEnabled = enabled.contains(skill.name)
            let status: String
            if !isEnabled || !group { status = NSLocalizedString("未启用", comment: "") }
            else if isolated { status = NSLocalizedString("当前会话已屏蔽相关上下文，因此不会实际启用该工具。", comment: "") }
            else { status = NSLocalizedString("已启用", comment: "") }
            return MacSkillRow(metadata: skill, enabled: isEnabled, status: status)
        }
        return (rows, .array(rows.map { .dictionary([
            "name": .string($0.id), "enabled": .bool($0.enabled),
            "available_in_session": .bool($0.enabled && group && !isolated)
        ]) }))
    }
}
