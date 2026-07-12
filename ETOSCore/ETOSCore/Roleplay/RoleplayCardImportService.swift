// ============================================================================
// RoleplayCardImportService.swift
// ============================================================================
// ETOS LLM Studio
//
// 导入 SillyTavern Character Card V2/V3 JSON 与 PNG 文本块。
// ============================================================================

import Foundation
import ZIPFoundation

public enum RoleplayCardImportError: LocalizedError {
    case invalidPayload
    case missingCharacterData
    case missingPNGCharacterData

    public var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return NSLocalizedString("角色卡不是有效的 JSON 数据。", comment: "Invalid roleplay card JSON")
        case .missingCharacterData:
            return NSLocalizedString("没有找到有效的角色卡资料。", comment: "Missing roleplay character data")
        case .missingPNGCharacterData:
            return NSLocalizedString("PNG 中没有找到 chara 或 ccv3 角色卡数据。", comment: "Missing roleplay PNG metadata")
        }
    }
}

public struct RoleplayCardImportResult: Sendable {
    public var character: RoleplayCharacter
    public var embeddedWorldbook: Worldbook?
    public var avatarPNGData: Data?
    public var assets: [RoleplayImportedCardAsset]

    public init(
        character: RoleplayCharacter,
        embeddedWorldbook: Worldbook?,
        avatarPNGData: Data?,
        assets: [RoleplayImportedCardAsset] = []
    ) {
        self.character = character
        self.embeddedWorldbook = embeddedWorldbook
        self.avatarPNGData = avatarPNGData
        self.assets = assets
    }
}

public struct RoleplayImportedCardAsset: Sendable {
    public var asset: RoleplayCardAsset
    public var data: Data?

    public init(asset: RoleplayCardAsset, data: Data?) {
        self.asset = asset
        self.data = data
    }
}

public struct RoleplayCardImportService {
    public init() {}

    public func importCard(from url: URL) throws -> RoleplayCardImportResult {
        try importCard(from: Data(contentsOf: url), fileName: url.lastPathComponent)
    }

    public func importCard(from data: Data, fileName: String) throws -> RoleplayCardImportResult {
        let jsonData: Data
        let avatarPNGData: Data?
        let packagedAssets: [String: Data]
        if WorldbookImportService.isPNG(data) {
            guard let embedded = extractCharacterJSON(fromPNG: data) else {
                throw RoleplayCardImportError.missingPNGCharacterData
            }
            jsonData = embedded
            avatarPNGData = data
            packagedAssets = extractPNGAssets(data)
        } else if fileName.lowercased().hasSuffix(".charx") {
            let archive = try Archive(data: data, accessMode: .read)
            guard let cardEntry = archive["card.json"] else { throw RoleplayCardImportError.invalidPayload }
            jsonData = try archiveData(cardEntry, in: archive)
            avatarPNGData = nil
            packagedAssets = try Dictionary(uniqueKeysWithValues: archive.compactMap { entry in
                guard entry.type == .file, entry.path != "card.json" else { return nil }
                return (entry.path, try archiveData(entry, in: archive))
            })
        } else {
            jsonData = data
            avatarPNGData = nil
            packagedAssets = [:]
        }

        guard let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw RoleplayCardImportError.invalidPayload
        }
        let cardData = (root["data"] as? [String: Any]) ?? root
        guard let name = string(cardData["name"] ?? root["name"]), !name.isEmpty else {
            throw RoleplayCardImportError.missingCharacterData
        }

        let extensions = (cardData["extensions"] as? [String: Any]) ?? [:]
        let regexRules = parseRegexRules(from: extensions)
        let helperScripts = parseHelperScripts(from: extensions)
        let initialVariables = parseInitialVariables(from: extensions)
        let embeddedWorldbook = parseEmbeddedWorldbook(from: cardData, characterName: name, fileName: fileName)
        let report = makeCompatibilityReport(regexRules: regexRules, helperScripts: helperScripts)
        let assets = parseAssets(
            cardData["assets"],
            sourceSpec: string(root["spec"]),
            defaultAsset: avatarPNGData,
            packagedAssets: packagedAssets
        )

        var character = RoleplayCharacter(
            name: name,
            description: string(cardData["description"]) ?? "",
            personality: string(cardData["personality"]) ?? "",
            scenario: string(cardData["scenario"]) ?? "",
            firstMessage: string(cardData["first_mes"] ?? cardData["firstMessage"]) ?? "",
            alternateGreetings: strings(cardData["alternate_greetings"] ?? cardData["alternateGreetings"]),
            messageExamples: string(cardData["mes_example"] ?? cardData["messageExamples"]) ?? "",
            creatorNotes: string(cardData["creator_notes"] ?? cardData["creatorNotes"]) ?? "",
            systemPrompt: string(cardData["system_prompt"] ?? cardData["systemPrompt"]) ?? "",
            postHistoryInstructions: string(cardData["post_history_instructions"] ?? cardData["postHistoryInstructions"]) ?? "",
            tags: strings(cardData["tags"]),
            creator: string(cardData["creator"]) ?? "",
            characterVersion: string(cardData["character_version"] ?? cardData["characterVersion"]) ?? "",
            sourceFileName: fileName,
            sourceSpec: string(root["spec"]),
            sourceSpecVersion: string(root["spec_version"]),
            regexRules: regexRules,
            helperScripts: helperScripts,
            assets: assets.map(\.asset),
            initialVariables: initialVariables,
            extensions: jsonDictionary(extensions),
            rawCardData: jsonDictionary(cardData),
            compatibilityReport: report
        )
        character.embeddedWorldbookID = embeddedWorldbook?.id

        return RoleplayCardImportResult(
            character: character,
            embeddedWorldbook: embeddedWorldbook,
            avatarPNGData: avatarPNGData,
            assets: assets
        )
    }

    private func archiveData(_ entry: Entry, in archive: Archive) throws -> Data {
        var output = Data()
        _ = try archive.extract(entry) { output.append($0) }
        return output
    }

    private func extractPNGAssets(_ data: Data) -> [String: Data] {
        var result: [String: Data] = [:]
        var offset = 8
        while offset + 12 <= data.count {
            let length = Int(WorldbookImportService.readUInt32BigEndian(data, offset: offset))
            let typeStart = offset + 4
            let chunkStart = typeStart + 4
            let chunkEnd = chunkStart + length
            let crcEnd = chunkEnd + 4
            guard crcEnd <= data.count else { break }
            let type = String(data: data[typeStart..<(typeStart + 4)], encoding: .ascii) ?? ""
            if let values = WorldbookImportService.decodePNGTextChunk(
                type: type,
                data: Data(data[chunkStart..<chunkEnd])
            ) {
                for (key, value) in values where key.hasPrefix("chara-ext-asset_:") {
                    let path = String(key.dropFirst("chara-ext-asset_:".count))
                    if let decoded = Data(base64Encoded: value) { result[path] = decoded }
                }
            }
            offset = crcEnd
            if type == "IEND" { break }
        }
        return result
    }

    private func parseAssets(
        _ raw: Any?,
        sourceSpec: String?,
        defaultAsset: Data?,
        packagedAssets: [String: Data]
    ) -> [RoleplayImportedCardAsset] {
        let values: [[String: Any]]
        if let raw = raw as? [[String: Any]] {
            values = raw
        } else if sourceSpec == "chara_card_v3" {
            values = [["type": "icon", "uri": "ccdefault:", "name": "main", "ext": "png"]]
        } else {
            values = []
        }
        return values.compactMap { value in
            guard let type = string(value["type"]),
                  let uri = string(value["uri"]),
                  let name = string(value["name"]),
                  let ext = string(value["ext"]) else { return nil }
            let normalizedExtension = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let data: Data?
            if uri == "ccdefault:" {
                data = defaultAsset
            } else if uri.hasPrefix("embeded://") {
                data = packagedAssets[String(uri.dropFirst("embeded://".count))]
            } else if uri.hasPrefix("__asset:") {
                data = packagedAssets[String(uri.dropFirst("__asset:".count))]
            } else if uri.hasPrefix("data:"), let separator = uri.firstIndex(of: ",") {
                let header = uri[..<separator]
                let payload = String(uri[uri.index(after: separator)...])
                data = header.contains(";base64") ? Data(base64Encoded: payload) : payload.removingPercentEncoding?.data(using: .utf8)
            } else {
                data = nil
            }
            return RoleplayImportedCardAsset(
                asset: RoleplayCardAsset(type: type, uri: uri, name: name, fileExtension: normalizedExtension),
                data: data
            )
        }
    }

    private func extractCharacterJSON(fromPNG data: Data) -> Data? {
        var offset = 8
        var legacyPayload: String?
        while offset + 12 <= data.count {
            let length = Int(WorldbookImportService.readUInt32BigEndian(data, offset: offset))
            let typeStart = offset + 4
            let chunkStart = typeStart + 4
            let chunkEnd = chunkStart + length
            let crcEnd = chunkEnd + 4
            guard crcEnd <= data.count else { break }

            let type = String(data: data[typeStart..<(typeStart + 4)], encoding: .ascii) ?? ""
            let chunkData = Data(data[chunkStart..<chunkEnd])
            if let values = WorldbookImportService.decodePNGTextChunk(type: type, data: chunkData) {
                if let payload = values["ccv3"], let decoded = decodeCharacterPayload(payload) {
                    return decoded
                }
                if let payload = values["chara"] {
                    legacyPayload = payload
                }
            }
            if type == "IEND" { break }
            offset = crcEnd
        }
        return legacyPayload.flatMap(decodeCharacterPayload)
    }

    private func decodeCharacterPayload(_ payload: String) -> Data? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: direct)) != nil {
            return direct
        }
        let normalized = trimmed
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard let decoded = Data(base64Encoded: normalized),
              (try? JSONSerialization.jsonObject(with: decoded)) != nil else { return nil }
        return decoded
    }

    private func parseEmbeddedWorldbook(
        from cardData: [String: Any],
        characterName: String,
        fileName: String
    ) -> Worldbook? {
        guard let characterBook = cardData["character_book"] as? [String: Any] else { return nil }
        let wrapper: [String: Any] = [
            "name": characterBook["name"] ?? "\(characterName) Lorebook",
            "character_book": characterBook
        ]
        guard JSONSerialization.isValidJSONObject(wrapper),
              let data = try? JSONSerialization.data(withJSONObject: wrapper) else { return nil }
        return try? WorldbookImportService().importWorldbook(from: data, fileName: fileName)
    }

    private func parseRegexRules(from extensions: [String: Any]) -> [RoleplayRegexRule] {
        guard let rawRules = extensions["regex_scripts"] as? [Any] else { return [] }
        return rawRules.compactMap { raw in
            guard let dictionary = raw as? [String: Any] else { return nil }
            let placements = integers(dictionary["placement"]).compactMap(RoleplayRegexPlacement.init(rawValue:))
            return RoleplayRegexRule(
                id: uuid(dictionary["id"]) ?? UUID(),
                scriptName: string(dictionary["scriptName"] ?? dictionary["name"]) ?? "",
                findRegex: string(dictionary["findRegex"] ?? dictionary["pattern"]) ?? "",
                replaceString: string(dictionary["replaceString"] ?? dictionary["replacement"]) ?? "",
                trimStrings: strings(dictionary["trimStrings"]),
                placements: placements.isEmpty ? [.aiOutput] : placements,
                scope: .character,
                disabled: bool(dictionary["disabled"]) ?? false,
                markdownOnly: bool(dictionary["markdownOnly"]) ?? false,
                promptOnly: bool(dictionary["promptOnly"]) ?? false,
                runOnEdit: bool(dictionary["runOnEdit"]) ?? false,
                minDepth: integer(dictionary["minDepth"]),
                maxDepth: integer(dictionary["maxDepth"]),
                substituteRegex: integer(dictionary["substituteRegex"]) ?? 0,
                metadata: jsonDictionary(dictionary)
            )
        }
    }

    private func parseHelperScripts(from extensions: [String: Any]) -> [RoleplayHelperScript] {
        var candidates: [Any] = []
        if let legacy = extensions["TavernHelper_scripts"] as? [Any] {
            candidates.append(contentsOf: legacy)
        }
        if let settings = normalizedHelperSettings(extensions["tavern_helper"]),
           let scripts = settings["scripts"] as? [Any] {
            candidates.append(contentsOf: scripts)
        }
        var scripts: [RoleplayHelperScript] = []
        var indexesByID: [UUID: Int] = [:]
        for script in candidates.flatMap(parseScriptTree) {
            if let index = indexesByID[script.id] {
                // 新版 tavern_helper 位于旧字段之后，保留信息更完整的新版本。
                scripts[index] = script
            } else {
                indexesByID[script.id] = scripts.count
                scripts.append(script)
            }
        }
        return scripts
    }

    private func parseInitialVariables(from extensions: [String: Any]) -> [String: JSONValue] {
        if let legacy = extensions["TavernHelper_characterScriptVariables"] as? [String: Any] {
            return jsonDictionary(legacy)
        }
        guard let settings = normalizedHelperSettings(extensions["tavern_helper"]),
              let variables = settings["variables"] as? [String: Any] else { return [:] }
        return jsonDictionary(variables)
    }

    private func normalizedHelperSettings(_ raw: Any?) -> [String: Any]? {
        if let dictionary = raw as? [String: Any] { return dictionary }
        guard let pairs = raw as? [Any] else { return nil }
        var dictionary: [String: Any] = [:]
        for rawPair in pairs {
            guard let pair = rawPair as? [Any], pair.count == 2, let key = pair.first as? String else { continue }
            dictionary[key] = pair.last
        }
        return dictionary
    }

    private func parseScriptTree(_ raw: Any) -> [RoleplayHelperScript] {
        guard let dictionary = raw as? [String: Any] else { return [] }
        if let value = dictionary["value"] {
            return parseScriptTree(value)
        }
        if string(dictionary["type"]) == "folder" {
            guard bool(dictionary["enabled"]) ?? true,
                  let children = dictionary["scripts"] as? [Any] else { return [] }
            return children.flatMap(parseScriptTree)
        }
        let rawButton = dictionary["button"] as? [String: Any]
        let buttonsEnabled = bool(rawButton?["enabled"]) ?? true
        let buttons = (buttonsEnabled ? (rawButton?["buttons"] as? [Any] ?? dictionary["buttons"] as? [Any] ?? []) : []).compactMap { raw -> RoleplayScriptButton? in
            guard let button = raw as? [String: Any], let name = string(button["name"]) else { return nil }
            return RoleplayScriptButton(
                name: name,
                visible: bool(button["visible"]) ?? true,
                metadata: jsonDictionary(button)
            )
        }
        return [RoleplayHelperScript(
            id: uuid(dictionary["id"]) ?? UUID(),
            name: string(dictionary["name"]) ?? "",
            content: string(dictionary["content"]) ?? "",
            info: string(dictionary["info"]) ?? "",
            enabled: bool(dictionary["enabled"]) ?? false,
            buttons: buttons,
            metadata: jsonDictionary(dictionary)
        )]
    }

    private func makeCompatibilityReport(
        regexRules: [RoleplayRegexRule],
        helperScripts: [RoleplayHelperScript]
    ) -> RoleplayCompatibilityReport {
        let scripts = helperScripts.map(\.content).joined(separator: "\n")
        let replacements = regexRules.map(\.replaceString).joined(separator: "\n")
        let detectsHTML = replacements.range(of: #"<(?:html|head|body|div|style|script)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        let detectsDOM = scripts.range(
            of: #"window\.parent|parent\.document|\$\s*\(\s*['\"]#chat|#chat\s*>|\.mes\[|\.mes(?:\W|$)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        let detectsNetwork = scripts.range(
            of: #"\b(?:fetch|XMLHttpRequest|WebSocket)\s*\("#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        let detectsMVU = scripts.range(of: #"\bMvu\b|UpdateVariable|stat_data"#, options: [.regularExpression, .caseInsensitive]) != nil

        var items = [
            RoleplayCompatibilityItem(
                id: "character",
                title: NSLocalizedString("角色资料", comment: "Roleplay compatibility character data"),
                status: .supported
            ),
            RoleplayCompatibilityItem(
                id: "regex",
                title: NSLocalizedString("角色正则", comment: "Roleplay compatibility regex"),
                status: regexRules.isEmpty ? .supported : .translated,
                detail: "\(regexRules.count)"
            ),
            RoleplayCompatibilityItem(
                id: "html",
                title: NSLocalizedString("HTML 渲染", comment: "Roleplay compatibility HTML rendering"),
                status: detectsHTML ? .supported : .supported
            )
        ]
        if !helperScripts.isEmpty {
            items.append(RoleplayCompatibilityItem(
                id: "scripts",
                title: NSLocalizedString("酒馆助手脚本", comment: "Roleplay compatibility helper scripts"),
                status: .supported,
                detail: "\(helperScripts.count)"
            ))
        }
        if detectsDOM {
            items.append(RoleplayCompatibilityItem(
                id: "dom",
                title: NSLocalizedString("酒馆页面 DOM", comment: "Roleplay compatibility Tavern DOM"),
                status: .translated
            ))
        }
        return RoleplayCompatibilityReport(
            items: items,
            detectedDOMAccess: detectsDOM,
            detectedNetworkAccess: detectsNetwork,
            detectedMVUUsage: detectsMVU
        )
    }

    private func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private func strings(_ value: Any?) -> [String] {
        if let values = value as? [String] { return values }
        if let values = value as? [Any] { return values.compactMap(string) }
        if let value = string(value) { return [value] }
        return []
    }

    private func integers(_ value: Any?) -> [Int] {
        if let values = value as? [Any] { return values.compactMap(integer) }
        if let value = integer(value) { return [value] }
        return []
    }

    private func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            if ["true", "1"].contains(value.lowercased()) { return true }
            if ["false", "0"].contains(value.lowercased()) { return false }
        }
        return nil
    }

    private func uuid(_ value: Any?) -> UUID? {
        string(value).flatMap(UUID.init(uuidString:))
    }

    private func jsonDictionary(_ dictionary: [String: Any]) -> [String: JSONValue] {
        dictionary.compactMapValues(JSONValue.init(anyJSONValue:))
    }
}
