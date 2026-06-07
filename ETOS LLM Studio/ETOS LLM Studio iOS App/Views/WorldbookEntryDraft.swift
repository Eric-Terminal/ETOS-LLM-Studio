// ============================================================================
// WorldbookEntryDraft.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 iOS 世界书条目编辑表单与持久化模型之间的草稿转换。
// ============================================================================

import Foundation
import ETOSCore

struct WorldbookEntryDraft: Identifiable {
    let id: UUID
    let entryID: UUID

    var comment: String
    var content: String
    var keysText: String
    var secondaryKeysText: String

    var secondaryKeysEnabled: Bool
    var selectiveLogic: WorldbookSelectiveLogic
    var isEnabled: Bool
    var constant: Bool

    var position: WorldbookPosition
    var role: WorldbookEntryRole
    var outletName: String
    var order: Int
    var depth: Int

    var enableEntryScanDepth: Bool
    var scanDepth: Int

    var caseSensitive: Bool
    var matchWholeWords: Bool
    var useRegex: Bool

    var useProbability: Bool
    var probability: Double

    var groupName: String
    var groupOverride: Bool
    var groupWeight: Double
    var useGroupScoring: Bool

    var enableSticky: Bool
    var sticky: Int

    var enableCooldown: Bool
    var cooldown: Int

    var enableDelay: Bool
    var delay: Int

    var excludeRecursion: Bool
    var preventRecursion: Bool
    var delayUntilRecursion: Bool

    private var metadata: [String: JSONValue]

    var primaryKeys: [String] {
        parseKeywordList(keysText)
    }

    var secondaryKeys: [String] {
        parseKeywordList(secondaryKeysText)
    }

    init(entry: WorldbookEntry) {
        self.id = UUID()
        self.entryID = entry.id
        self.comment = entry.comment
        self.content = entry.content
        self.keysText = entry.keys.joined(separator: ", ")
        self.secondaryKeysText = entry.secondaryKeys.joined(separator: ", ")
        self.secondaryKeysEnabled = entry.secondaryKeysEnabled
        self.selectiveLogic = entry.selectiveLogic
        self.isEnabled = entry.isEnabled
        self.constant = entry.constant
        self.position = entry.position
        self.role = entry.role
        self.outletName = entry.outletName ?? ""
        self.order = entry.order
        self.depth = max(0, entry.depth ?? 0)
        self.enableEntryScanDepth = entry.scanDepth != nil
        self.scanDepth = max(1, entry.scanDepth ?? 4)
        self.caseSensitive = entry.caseSensitive
        self.matchWholeWords = entry.matchWholeWords
        self.useRegex = entry.useRegex
        self.useProbability = entry.useProbability
        self.probability = max(1, min(100, entry.probability))
        self.groupName = entry.group ?? ""
        self.groupOverride = entry.groupOverride
        self.groupWeight = entry.groupWeight
        self.useGroupScoring = entry.useGroupScoring
        self.enableSticky = entry.sticky != nil
        self.sticky = max(1, entry.sticky ?? 1)
        self.enableCooldown = entry.cooldown != nil
        self.cooldown = max(1, entry.cooldown ?? 1)
        self.enableDelay = entry.delay != nil
        self.delay = max(1, entry.delay ?? 1)
        self.excludeRecursion = entry.excludeRecursion
        self.preventRecursion = entry.preventRecursion
        self.delayUntilRecursion = entry.delayUntilRecursion
        self.metadata = entry.metadata
    }

    static func new() -> WorldbookEntryDraft {
        WorldbookEntryDraft(
            id: UUID(),
            entryID: UUID(),
            comment: "",
            content: "",
            keysText: "",
            secondaryKeysText: "",
            secondaryKeysEnabled: true,
            selectiveLogic: .andAny,
            isEnabled: true,
            constant: false,
            position: .after,
            role: .user,
            outletName: "",
            order: 100,
            depth: 0,
            enableEntryScanDepth: false,
            scanDepth: 4,
            caseSensitive: false,
            matchWholeWords: false,
            useRegex: false,
            useProbability: false,
            probability: 100,
            groupName: "",
            groupOverride: false,
            groupWeight: 1,
            useGroupScoring: false,
            enableSticky: false,
            sticky: 1,
            enableCooldown: false,
            cooldown: 1,
            enableDelay: false,
            delay: 1,
            excludeRecursion: false,
            preventRecursion: false,
            delayUntilRecursion: false,
            metadata: [:]
        )
    }

    func toEntry() -> WorldbookEntry {
        let normalizedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        let normalizedOutletName = outletName.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        let normalizedGroupName = groupName.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        var updatedMetadata = metadata
        updatedMetadata[WorldbookMetadataKey.etosSecondaryKeysEnabled] = secondaryKeys.isEmpty ? nil : .bool(secondaryKeysEnabled)

        return WorldbookEntry(
            id: entryID,
            comment: normalizedComment,
            content: normalizedContent,
            keys: primaryKeys,
            secondaryKeys: secondaryKeys,
            selectiveLogic: selectiveLogic,
            isEnabled: isEnabled,
            constant: constant,
            position: position,
            outletName: normalizedOutletName.isEmpty ? nil : normalizedOutletName,
            order: order,
            depth: position == .atDepth ? depth : nil,
            scanDepth: enableEntryScanDepth ? scanDepth : nil,
            caseSensitive: caseSensitive,
            matchWholeWords: matchWholeWords,
            useRegex: useRegex,
            useProbability: useProbability,
            probability: max(1, min(100, probability)),
            group: normalizedGroupName.isEmpty ? nil : normalizedGroupName,
            groupOverride: groupOverride,
            groupWeight: groupWeight,
            useGroupScoring: useGroupScoring,
            role: role,
            sticky: enableSticky ? sticky : nil,
            cooldown: enableCooldown ? cooldown : nil,
            delay: enableDelay ? delay : nil,
            excludeRecursion: excludeRecursion,
            preventRecursion: preventRecursion,
            delayUntilRecursion: delayUntilRecursion,
            metadata: updatedMetadata
        )
    }

    private init(
        id: UUID,
        entryID: UUID,
        comment: String,
        content: String,
        keysText: String,
        secondaryKeysText: String,
        secondaryKeysEnabled: Bool,
        selectiveLogic: WorldbookSelectiveLogic,
        isEnabled: Bool,
        constant: Bool,
        position: WorldbookPosition,
        role: WorldbookEntryRole,
        outletName: String,
        order: Int,
        depth: Int,
        enableEntryScanDepth: Bool,
        scanDepth: Int,
        caseSensitive: Bool,
        matchWholeWords: Bool,
        useRegex: Bool,
        useProbability: Bool,
        probability: Double,
        groupName: String,
        groupOverride: Bool,
        groupWeight: Double,
        useGroupScoring: Bool,
        enableSticky: Bool,
        sticky: Int,
        enableCooldown: Bool,
        cooldown: Int,
        enableDelay: Bool,
        delay: Int,
        excludeRecursion: Bool,
        preventRecursion: Bool,
        delayUntilRecursion: Bool,
        metadata: [String: JSONValue]
    ) {
        self.id = id
        self.entryID = entryID
        self.comment = comment
        self.content = content
        self.keysText = keysText
        self.secondaryKeysText = secondaryKeysText
        self.secondaryKeysEnabled = secondaryKeysEnabled
        self.selectiveLogic = selectiveLogic
        self.isEnabled = isEnabled
        self.constant = constant
        self.position = position
        self.role = role
        self.outletName = outletName
        self.order = order
        self.depth = depth
        self.enableEntryScanDepth = enableEntryScanDepth
        self.scanDepth = scanDepth
        self.caseSensitive = caseSensitive
        self.matchWholeWords = matchWholeWords
        self.useRegex = useRegex
        self.useProbability = useProbability
        self.probability = probability
        self.groupName = groupName
        self.groupOverride = groupOverride
        self.groupWeight = groupWeight
        self.useGroupScoring = useGroupScoring
        self.enableSticky = enableSticky
        self.sticky = sticky
        self.enableCooldown = enableCooldown
        self.cooldown = cooldown
        self.enableDelay = enableDelay
        self.delay = delay
        self.excludeRecursion = excludeRecursion
        self.preventRecursion = preventRecursion
        self.delayUntilRecursion = delayUntilRecursion
        self.metadata = metadata
    }
}

private func parseKeywordList(_ raw: String) -> [String] {
    let normalized = raw
        .normalizedPlainQuotes()
        .replacingOccurrences(of: "，", with: ",")
    let components = normalized.components(separatedBy: CharacterSet(charactersIn: ",\n"))
    var seen = Set<String>()
    var result: [String] = []

    for component in components {
        let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let key = trimmed.lowercased()
        if seen.contains(key) { continue }
        seen.insert(key)
        result.append(trimmed)
    }

    return result
}
