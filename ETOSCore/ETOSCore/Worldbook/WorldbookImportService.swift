// ============================================================================
// WorldbookImportService.swift
// ============================================================================
// 世界书导入：支持 JSON / PNG(naidata) / 多种兼容格式转换。
// ============================================================================

import Foundation

public enum WorldbookImportError: LocalizedError {
    case invalidPayload
    case unsupportedFormat
    case missingEntries
    case missingPNGPayload

    public var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return NSLocalizedString("导入失败：文件内容不是有效的世界书数据。", comment: "Worldbook import invalid payload error")
        case .unsupportedFormat:
            return NSLocalizedString("导入失败：暂不支持该文件格式。", comment: "Worldbook import unsupported format error")
        case .missingEntries:
            return NSLocalizedString("导入失败：未找到可用条目。", comment: "Worldbook import missing entries error")
        case .missingPNGPayload:
            return NSLocalizedString("导入失败：PNG 内未找到 naidata 世界书数据。", comment: "Worldbook import missing PNG payload error")
        }
    }
}

public struct WorldbookImportResult {
    public var worldbook: Worldbook
    public var diagnostics: WorldbookImportDiagnostics

    public init(worldbook: Worldbook, diagnostics: WorldbookImportDiagnostics) {
        self.worldbook = worldbook
        self.diagnostics = diagnostics
    }
}

public struct WorldbookImportService {
    public init() {}

    public func importWorldbook(from url: URL) throws -> Worldbook {
        let data = try Data(contentsOf: url)
        return try importWorldbook(from: data, fileName: url.lastPathComponent)
    }

    public func importWorldbook(from data: Data, fileName: String) throws -> Worldbook {
        try importWorldbookWithReport(from: data, fileName: fileName).worldbook
    }

    public func importWorldbookWithReport(from data: Data, fileName: String) throws -> WorldbookImportResult {
        let jsonData: Data
        if Self.isPNG(data) {
            guard let embedded = Self.extractNaiDataJSON(fromPNG: data) else {
                throw WorldbookImportError.missingPNGPayload
            }
            jsonData = embedded
        } else {
            jsonData = data
        }

        let payload = try JSONSerialization.jsonObject(with: jsonData)
        let parsed = try parseJSONPayload(payload, fileName: fileName)
        guard !parsed.entries.isEmpty else {
            throw WorldbookImportError.missingEntries
        }

        let worldbook = Worldbook(
            id: UUID(),
            name: parsed.name,
            description: parsed.description,
            isEnabled: true,
            createdAt: Date(),
            updatedAt: Date(),
            entries: parsed.entries,
            settings: parsed.settings,
            sourceFileName: fileName,
            metadata: parsed.metadata
        )
        let diagnostics = WorldbookImportDiagnostics(
            failedEntries: parsed.failedEntries,
            failureReasons: parsed.failureReasons
        )
        return WorldbookImportResult(worldbook: worldbook, diagnostics: diagnostics)
    }

    private func parseJSONPayload(_ payload: Any, fileName: String) throws -> ParsedBook {
        if let root = payload as? [String: Any] {
            return try parseRoot(root, fileName: fileName)
        }
        if let entries = payload as? [Any] {
            return try parseSillyTavernArray(entries: entries, root: [:], fileName: fileName)
        }
        if let text = payload as? String,
           let nestedData = decodeJSONStringPayload(text) {
            let nestedPayload = try JSONSerialization.jsonObject(with: nestedData)
            return try parseJSONPayload(nestedPayload, fileName: fileName)
        }
        throw WorldbookImportError.invalidPayload
    }

    private func parseRoot(_ root: [String: Any], fileName: String) throws -> ParsedBook {
        if let type = stringValue(root["type"])?.lowercased(), type == "lorebook" {
            if let nested = root["data"] as? [String: Any] {
                return try parseRoot(nested, fileName: fileName)
            }
            if let nestedText = stringValue(root["data"]),
               let nestedData = decodeJSONStringPayload(nestedText) {
                let nestedPayload = try JSONSerialization.jsonObject(with: nestedData)
                return try parseJSONPayload(nestedPayload, fileName: fileName)
            }
        }

        if let characterBook = root["character_book"] as? [String: Any] {
            return try parseCharacterBook(characterBook, root: root, fileName: fileName)
        }
        if let nestedData = root["data"] as? [String: Any],
           let characterBook = nestedData["character_book"] as? [String: Any] {
            return try parseCharacterBook(characterBook, root: nestedData, fileName: fileName)
        }

        if let entries = root["entries"] as? [String: Any] {
            return try parseSillyTavernLike(entriesContainer: entries, root: root, fileName: fileName)
        }
        if let entries = root["entries"] as? [Any] {
            if root["lorebookVersion"] != nil {
                return try parseNovel(entries: entries, root: root, fileName: fileName)
            }
            if let kind = root["kind"] as? String, kind.lowercased() == "memory" {
                return try parseAgnai(entries: entries, root: root, fileName: fileName)
            }
            if let type = root["type"] as? String, type.lowercased() == "risu" {
                return try parseRisu(entries: entries, root: root, fileName: fileName)
            }
            // 宽松回退：按 ST-like 解析数组 entries
            return try parseSillyTavernArray(entries: entries, root: root, fileName: fileName)
        }

        // 兼容部分导出会把实体放在 data/lorebook 字段
        if let nested = root["data"] as? [String: Any] {
            return try parseRoot(nested, fileName: fileName)
        }
        if let nested = root["lorebook"] as? [String: Any] {
            return try parseRoot(nested, fileName: fileName)
        }

        throw WorldbookImportError.invalidPayload
    }

    private func parseCharacterBook(_ characterBook: [String: Any], root: [String: Any], fileName: String) throws -> ParsedBook {
        guard let entries = characterBook["entries"] as? [Any] else {
            throw WorldbookImportError.missingEntries
        }

        var parsed: [WorldbookEntry] = []
        var failedEntries = 0
        var failureReasons: [String] = []

        for (index, item) in entries.enumerated() {
            guard var dict = item as? [String: Any] else {
                failedEntries += 1
                appendFailureReason(
                    String(format: NSLocalizedString("角色卡条目 #%d 结构无效，已跳过。", comment: "Worldbook character card entry invalid structure"), index),
                    to: &failureReasons
                )
                continue
            }

            if dict["key"] == nil, let keys = dict["keys"] {
                dict["key"] = keys
            }
            if dict["keysecondary"] == nil, let secondary = dict["secondary_keys"] {
                dict["keysecondary"] = secondary
            }
            if dict["order"] == nil, let insertionOrder = dict["insertion_order"] {
                dict["order"] = insertionOrder
            }
            if let enabled = boolValue(dict["enabled"]) {
                dict["isEnabled"] = enabled
                dict["disable"] = !enabled
            }

            let uid = intValue(dict["uid"]) ?? intValue(dict["id"]) ?? index
            if let entry = parseEntry(dict, uidHint: uid) {
                parsed.append(entry)
            } else {
                failedEntries += 1
                appendFailureReason(
                    String(format: NSLocalizedString("角色卡条目 %@ 缺少有效 content，已跳过。", comment: "Worldbook character card entry missing content"), String(uid)),
                    to: &failureReasons
                )
            }
        }

        var normalizedRoot = root
        if normalizedRoot["name"] == nil {
            normalizedRoot["name"] = stringValue(characterBook["name"]) ?? stringValue(root["name"])
        }
        if normalizedRoot["entries"] == nil {
            normalizedRoot["entries"] = entries
        }

        return buildParsedBook(
            entries: parsed,
            root: normalizedRoot,
            fileName: fileName,
            failedEntries: failedEntries,
            failureReasons: failureReasons
        )
    }

    private func parseSillyTavernLike(entriesContainer: [String: Any], root: [String: Any], fileName: String) throws -> ParsedBook {
        var entries: [WorldbookEntry] = []
        var failedEntries = 0
        var failureReasons: [String] = []
        for (key, value) in entriesContainer {
            guard let dict = value as? [String: Any] else {
                failedEntries += 1
                appendFailureReason(
                    String(format: NSLocalizedString("条目 %@ 结构无效，已跳过。", comment: "Worldbook entry invalid structure"), key),
                    to: &failureReasons
                )
                continue
            }
            let uidHint = Int(key)
            if let entry = parseEntry(dict, uidHint: uidHint) {
                entries.append(entry)
            } else {
                failedEntries += 1
                appendFailureReason(
                    String(format: NSLocalizedString("条目 %@ 缺少有效 content，已跳过。", comment: "Worldbook entry missing content"), uidHint.map(String.init) ?? key),
                    to: &failureReasons
                )
            }
        }
        return buildParsedBook(entries: entries, root: root, fileName: fileName, failedEntries: failedEntries, failureReasons: failureReasons)
    }

    private func parseSillyTavernArray(entries: [Any], root: [String: Any], fileName: String) throws -> ParsedBook {
        var parsed: [WorldbookEntry] = []
        var failedEntries = 0
        var failureReasons: [String] = []
        for (index, item) in entries.enumerated() {
            guard let dict = item as? [String: Any] else {
                failedEntries += 1
                appendFailureReason(
                    String(format: NSLocalizedString("条目 #%d 结构无效，已跳过。", comment: "Worldbook indexed entry invalid structure"), index),
                    to: &failureReasons
                )
                continue
            }
            let uid = intValue(dict["uid"])
            if let entry = parseEntry(dict, uidHint: uid) {
                parsed.append(entry)
            } else {
                failedEntries += 1
                appendFailureReason(
                    String(format: NSLocalizedString("条目 %@ 缺少有效 content，已跳过。", comment: "Worldbook entry missing content"), uid.map(String.init) ?? "#\(index)"),
                    to: &failureReasons
                )
            }
        }
        return buildParsedBook(entries: parsed, root: root, fileName: fileName, failedEntries: failedEntries, failureReasons: failureReasons)
    }

    private func parseNovel(entries: [Any], root: [String: Any], fileName: String) throws -> ParsedBook {
        var parsed: [WorldbookEntry] = []
        var failedEntries = 0
        var failureReasons: [String] = []
        for (index, item) in entries.enumerated() {
            guard let dict = item as? [String: Any] else {
                failedEntries += 1
                appendFailureReason(
                    String(format: NSLocalizedString("Novel 条目 #%d 结构无效，已跳过。", comment: "Worldbook Novel entry invalid structure"), index),
                    to: &failureReasons
                )
                continue
            }
            var converted = dict
            if converted["content"] == nil {
                converted["content"] = dict["text"]
            }
            if converted["key"] == nil {
                converted["key"] = dict["keys"]
            }
            if converted["comment"] == nil {
                converted["comment"] = dict["displayName"] ?? dict["name"]
            }
            if converted["position"] == nil {
                converted["position"] = dict["position"] ?? "after"
            }
            let uid = intValue(dict["id"])
            if let entry = parseEntry(converted, uidHint: uid) {
                parsed.append(entry)
            } else {
                failedEntries += 1
                appendFailureReason(
                    String(format: NSLocalizedString("Novel 条目 %@ 缺少有效 content，已跳过。", comment: "Worldbook Novel entry missing content"), uid.map(String.init) ?? "#\(index)"),
                    to: &failureReasons
                )
            }
        }
        return buildParsedBook(entries: parsed, root: root, fileName: fileName, failedEntries: failedEntries, failureReasons: failureReasons)
    }

    private func parseAgnai(entries: [Any], root: [String: Any], fileName: String) throws -> ParsedBook {
        var parsed: [WorldbookEntry] = []
        var failedEntries = 0
        var failureReasons: [String] = []
        for (index, item) in entries.enumerated() {
            guard let dict = item as? [String: Any] else {
                failedEntries += 1
                appendFailureReason(
                    String(format: NSLocalizedString("Agnai 条目 #%d 结构无效，已跳过。", comment: "Worldbook Agnai entry invalid structure"), index),
                    to: &failureReasons
                )
                continue
            }
            var converted = dict
            if converted["content"] == nil {
                converted["content"] = dict["value"] ?? dict["text"]
            }
            if converted["key"] == nil {
                converted["key"] = dict["key"] ?? dict["keys"]
            }
            if converted["comment"] == nil {
                converted["comment"] = dict["name"] ?? dict["memo"]
            }
            let uid = intValue(dict["uid"]) ?? intValue(dict["id"])
            if let entry = parseEntry(converted, uidHint: uid) {
                parsed.append(entry)
            } else {
                failedEntries += 1
                appendFailureReason(
                    String(format: NSLocalizedString("Agnai 条目 %@ 缺少有效 content，已跳过。", comment: "Worldbook Agnai entry missing content"), uid.map(String.init) ?? "#\(index)"),
                    to: &failureReasons
                )
            }
        }
        return buildParsedBook(entries: parsed, root: root, fileName: fileName, failedEntries: failedEntries, failureReasons: failureReasons)
    }

    private func parseRisu(entries: [Any], root: [String: Any], fileName: String) throws -> ParsedBook {
        var parsed: [WorldbookEntry] = []
        var failedEntries = 0
        var failureReasons: [String] = []
        for (index, item) in entries.enumerated() {
            guard let dict = item as? [String: Any] else {
                failedEntries += 1
                appendFailureReason(
                    String(format: NSLocalizedString("Risu 条目 #%d 结构无效，已跳过。", comment: "Worldbook Risu entry invalid structure"), index),
                    to: &failureReasons
                )
                continue
            }
            var converted = dict
            if converted["content"] == nil {
                converted["content"] = dict["content"] ?? dict["text"] ?? dict["value"]
            }
            if converted["key"] == nil {
                converted["key"] = dict["keys"] ?? dict["key"]
            }
            if converted["comment"] == nil {
                converted["comment"] = dict["comment"] ?? dict["name"]
            }
            let uid = intValue(dict["uid"]) ?? intValue(dict["id"])
            if let entry = parseEntry(converted, uidHint: uid) {
                parsed.append(entry)
            } else {
                failedEntries += 1
                appendFailureReason(
                    String(format: NSLocalizedString("Risu 条目 %@ 缺少有效 content，已跳过。", comment: "Worldbook Risu entry missing content"), uid.map(String.init) ?? "#\(index)"),
                    to: &failureReasons
                )
            }
        }
        return buildParsedBook(entries: parsed, root: root, fileName: fileName, failedEntries: failedEntries, failureReasons: failureReasons)
    }

    private func buildParsedBook(
        entries: [WorldbookEntry],
        root: [String: Any],
        fileName: String,
        failedEntries: Int,
        failureReasons: [String]
    ) -> ParsedBook {
        let defaultName = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let name = stringValue(root["name"]) ?? stringValue(root["title"]) ?? (defaultName.isEmpty ? NSLocalizedString("导入世界书", comment: "Imported worldbook fallback name") : defaultName)
        let description = stringValue(root["description"]) ?? stringValue(root["desc"]) ?? ""
        let nestedSettings = root["settings"] as? [String: Any]

        let settings = WorldbookSettings(
            scanDepth: intValue(root["scanDepth"]) ??
                intValue(root["scan_depth"]) ??
                intValue(nestedSettings?["scanDepth"]) ??
                intValue(nestedSettings?["scan_depth"]) ??
                4,
            maxRecursionDepth: intValue(root["maxRecursionDepth"]) ??
                intValue(root["max_recursion_depth"]) ??
                intValue(nestedSettings?["maxRecursionDepth"]) ??
                intValue(nestedSettings?["max_recursion_depth"]) ??
                2,
            maxInjectedEntries: intValue(root["maxEntries"]) ??
                intValue(root["max_entries"]) ??
                intValue(root["maxInjectedEntries"]) ??
                intValue(root["max_injected_entries"]) ??
                intValue(nestedSettings?["maxEntries"]) ??
                intValue(nestedSettings?["max_entries"]) ??
                intValue(nestedSettings?["maxInjectedEntries"]) ??
                intValue(nestedSettings?["max_injected_entries"]) ??
                WorldbookSettings.unlimitedInjectedEntries,
            maxInjectedCharacters: intValue(root["maxChars"]) ??
                intValue(root["max_chars"]) ??
                intValue(root["maxInjectedCharacters"]) ??
                intValue(root["max_injected_characters"]) ??
                intValue(nestedSettings?["maxChars"]) ??
                intValue(nestedSettings?["max_chars"]) ??
                intValue(nestedSettings?["maxInjectedCharacters"]) ??
                intValue(nestedSettings?["max_injected_characters"]) ??
                WorldbookSettings.unlimitedInjectedCharacters,
            fallbackPosition: positionFromRaw(root["position"] ?? nestedSettings?["fallbackPosition"])
        )

        let metadata = jsonDictionary(from: root)
        return ParsedBook(
            name: name,
            description: description,
            entries: entries,
            settings: settings,
            metadata: metadata,
            failedEntries: failedEntries,
            failureReasons: failureReasons
        )
    }

    private func parseEntry(_ dict: [String: Any], uidHint: Int?) -> WorldbookEntry? {
        let extensionDict = dict["extensions"] as? [String: Any]
        let content = stringValue(dict["content"]) ?? stringValue(dict["text"]) ?? stringValue(dict["value"]) ?? ""
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return nil }

        let primaryKeys = stringArrayValue(dict["keys"]) + stringArrayValue(dict["key"]) + stringArrayValue(dict["keywords"])
        let dedupPrimary = deduplicateStrings(primaryKeys)

        let secondaryKeys = stringArrayValue(dict["secondaryKeys"]) + stringArrayValue(dict["keysecondary"]) + stringArrayValue(dict["secondary_keys"])
        let dedupSecondary = deduplicateStrings(secondaryKeys)

        let rawPositionValue: Any? =
            dict["position"] ??
            extensionDict?["position"] ??
            dict["insertPosition"] ??
            "after"
        let position = positionFromRaw(rawPositionValue)

        let order = intValue(dict["priority"]) ?? intValue(dict["order"]) ?? 100
        let probabilityRaw = doubleValue(dict["probability"]) ?? 100
        let probability = probabilityRaw <= 1 ? probabilityRaw * 100 : probabilityRaw
        let outletName =
            stringValue(dict["outletName"]) ??
            stringValue(dict["outlet"]) ??
            stringValue(extensionDict?["outlet"]) ??
            stringValue(extensionDict?["outlet_name"])

        var logic = WorldbookSelectiveLogic(
            rawOrLegacyValue:
                stringValue(dict["selectiveLogic"]) ??
                stringValue(extensionDict?["selectiveLogic"]) ??
                stringValue(extensionDict?["selective_logic"])
        )
        if let legacyLogic = intValue(dict["selectiveLogic"]) ?? intValue(extensionDict?["selectiveLogic"]) ?? intValue(extensionDict?["selective_logic"]) {
            switch legacyLogic {
            case 1: logic = .notAll
            case 2: logic = .notAny
            case 3: logic = .andAll
            default: logic = .andAny
            }
        }

        let enabled: Bool
        if let disable = boolValue(dict["disable"]) {
            enabled = !disable
        } else if let directEnabled = boolValue(dict["isEnabled"]) {
            enabled = directEnabled
        } else if let legacyEnabled = boolValue(dict["enabled"]) {
            enabled = legacyEnabled
        } else {
            enabled = true
        }

        var metadata = jsonDictionary(from: dict)
        if !dedupSecondary.isEmpty,
           metadata[WorldbookMetadataKey.etosSecondaryKeysEnabled] == nil {
            let usesSillyTavernSecondaryKeys = dict[WorldbookMetadataKey.sillyTavernSecondaryKeys] != nil ||
                dict[WorldbookMetadataKey.characterBookSecondaryKeys] != nil
            let secondaryKeysEnabled = boolValue(dict[WorldbookMetadataKey.selective]) ?? !usesSillyTavernSecondaryKeys
            metadata[WorldbookMetadataKey.etosSecondaryKeysEnabled] = .bool(secondaryKeysEnabled)
        }
        let rawRole =
            stringValue(dict["role"]) ??
            stringValue(extensionDict?["role"]) ??
            intValue(dict["role"]).map { String($0) } ??
            intValue(extensionDict?["role"]).map { String($0) }
        let usesSillyTavernRoleDefault =
            dict["key"] != nil ||
            dict[WorldbookMetadataKey.sillyTavernSecondaryKeys] != nil ||
            dict[WorldbookMetadataKey.characterBookSecondaryKeys] != nil ||
            dict[WorldbookMetadataKey.selective] != nil ||
            dict["disable"] != nil ||
            extensionDict != nil
        let role: WorldbookEntryRole = {
            if rawRole == nil, position == .atDepth, usesSillyTavernRoleDefault {
                return .system
            }
            return WorldbookEntryRole(rawOrLegacyValue: rawRole)
        }()

        return WorldbookEntry(
            id: UUID(),
            uid: uidHint ?? intValue(dict["uid"]) ?? intValue(dict["id"]),
            comment: stringValue(dict["comment"]) ?? stringValue(dict["memo"]) ?? stringValue(dict["name"]) ?? "",
            content: trimmedContent,
            keys: dedupPrimary,
            secondaryKeys: dedupSecondary,
            selectiveLogic: logic,
            isEnabled: enabled,
            constant: boolValue(dict["constant"]) ?? boolValue(dict["constantActive"]) ?? false,
            position: position,
            outletName: outletName,
            order: order,
            depth: intValue(dict["injectDepth"]) ?? intValue(dict["depth"]) ?? intValue(extensionDict?["depth"]),
            scanDepth: intValue(dict["scanDepth"]) ?? intValue(dict["scan_depth"]) ?? intValue(extensionDict?["scan_depth"]) ?? intValue(extensionDict?["scanDepth"]),
            caseSensitive: boolValue(dict["caseSensitive"]) ?? boolValue(dict["case_sensitive"]) ?? boolValue(extensionDict?["case_sensitive"]) ?? false,
            matchWholeWords: boolValue(dict["matchWholeWords"]) ?? boolValue(dict["wholeWords"]) ?? boolValue(dict["match_whole_words"]) ?? boolValue(extensionDict?["match_whole_words"]) ?? false,
            useRegex: boolValue(dict["useRegex"]) ?? boolValue(dict["keyRegex"]) ?? boolValue(dict["regex"]) ?? false,
            useProbability: boolValue(dict["useProbability"]) ?? boolValue(extensionDict?["useProbability"]) ?? (probability < 100),
            probability: max(0, min(100, probability)),
            group: stringValue(dict["group"]) ?? stringValue(extensionDict?["group"]),
            groupOverride: boolValue(dict["groupOverride"]) ?? boolValue(extensionDict?["group_override"]) ?? false,
            groupWeight: doubleValue(dict["groupWeight"]) ?? doubleValue(extensionDict?["group_weight"]) ?? 1,
            useGroupScoring: boolValue(dict["useGroupScoring"]) ?? boolValue(extensionDict?["use_group_scoring"]) ?? false,
            role: role,
            sticky: intValue(dict["sticky"]) ?? intValue(extensionDict?["sticky"]),
            cooldown: intValue(dict["cooldown"]) ?? intValue(extensionDict?["cooldown"]),
            delay: intValue(dict["delay"]) ?? intValue(extensionDict?["delay"]),
            excludeRecursion: boolValue(dict["excludeRecursion"]) ?? boolValue(extensionDict?["exclude_recursion"]) ?? false,
            preventRecursion: boolValue(dict["preventRecursion"]) ?? boolValue(extensionDict?["prevent_recursion"]) ?? false,
            delayUntilRecursion: boolValue(dict["delayUntilRecursion"]) ?? boolValue(extensionDict?["delay_until_recursion"]) ?? false,
            metadata: metadata
        )
    }
}
