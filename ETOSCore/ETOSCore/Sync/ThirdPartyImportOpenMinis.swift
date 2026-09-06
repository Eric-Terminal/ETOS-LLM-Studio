// ============================================================================
// ThirdPartyImportOpenMinis.swift
// ============================================================================
// ETOS LLM Studio
//
// 解析 OpenMinis iOS/Android 导出的会话 ZIP/JSON、Provider JSON 与 MCP
// JSON。归档只读取安全路径和受限大小的相关文件；Skill 包只识别，不恢复执行状态。
// ============================================================================

import Foundation
import ZIPFoundation

extension ThirdPartyImportService {
    struct OpenMinisParsedPayload {
        var payload: ParsedPayload
        var mcpServers: [MCPServerConfiguration]
        var skills: [SyncedSkillBundle]
        var recognizedSkillNames: [String]
        var containsSensitiveCredentials: Bool
        var messageCount: Int
        var attachmentPlaceholderCount: Int
        var degradedItemCount: Int
    }

    private struct OpenMinisInputFile {
        let path: String
        let data: Data
    }

    static func parseOpenMinis(fileURL: URL) throws -> OpenMinisParsedPayload {
        let files = try loadOpenMinisInputFiles(fileURL)
        var providers: [Provider] = []
        var sessions: [SyncedSession] = []
        var mcpServers: [MCPServerConfiguration] = []
        var warnings: [String] = []
        var containsSensitiveCredentials = false

        let skills = parseOpenMinisSkills(files)

        let metadataByDirectory = openMinisSessionMetadata(files)
        for file in files {
            let lowerPath = file.path.lowercased()
            if lowerPath.hasSuffix("/skill.md") || lowerPath == "skill.md" {
                continue
            }
            guard lowerPath.hasSuffix(".json"),
                  let json = try? JSONSerialization.jsonObject(with: file.data) else {
                continue
            }

            if let root = json as? [String: Any], root["mcpServers"] != nil {
                if let imported = try? MCPServerConfigurationTransferService.importConfigurations(from: file.data) {
                    mcpServers.append(contentsOf: imported.servers)
                    containsSensitiveCredentials = containsSensitiveCredentials || !imported.sensitiveServerNames.isEmpty
                    if !imported.skippedNames.isEmpty {
                        warnings.append(
                            String(
                                format: NSLocalizedString("OpenMinis MCP 配置中有 %d 个 Server 无法识别，已跳过。", comment: "OpenMinis skipped MCP servers warning"),
                                imported.skippedNames.count
                            )
                        )
                    }
                }
                continue
            }

            if let root = json as? [String: Any],
               let provider = parseOpenMinisProvider(root, containsSensitiveCredentials: &containsSensitiveCredentials, warnings: &warnings) {
                providers.append(provider)
                continue
            }

            if let parsedSessions = parseOpenMinisIOSSessions(json), !parsedSessions.isEmpty {
                sessions.append(contentsOf: parsedSessions)
                continue
            }

            if lowerPath.hasSuffix("messages.json"), let messages = json as? [[String: Any]] {
                let directory = (file.path as NSString).deletingLastPathComponent
                let metadata = metadataByDirectory[directory] ?? [:]
                if let session = parseOpenMinisAndroidSession(
                    messages: messages,
                    metadata: metadata,
                    directory: directory
                ) {
                    sessions.append(session)
                }
            }
        }

        if !skills.isEmpty {
            warnings.append(
                String(
                    format: NSLocalizedString("识别到 %d 个 OpenMinis Skill；只有勾选后才导入文件，导入过程不会执行其中的脚本或安装依赖。", comment: "OpenMinis skills recognized warning"),
                    skills.count
                )
            )
        }
        if providers.isEmpty && sessions.isEmpty && mcpServers.isEmpty && skills.isEmpty {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: NSLocalizedString("未识别到 OpenMinis 会话、Provider、MCP 或 Skill 内容。", comment: "OpenMinis no recognized data")
            )
        }

        let deduplicatedSessions = dedupeOpenMinisSessions(sessions)
        let historyCounts = openMinisHistoryCounts(deduplicatedSessions)
        return OpenMinisParsedPayload(
            payload: ParsedPayload(
                providers: dedupeProviders(providers),
                sessions: deduplicatedSessions,
                warnings: warnings
            ),
            mcpServers: dedupeOpenMinisMCPServers(mcpServers),
            skills: skills,
            recognizedSkillNames: skills.map(\.name).sorted(),
            containsSensitiveCredentials: containsSensitiveCredentials,
            messageCount: historyCounts.messages,
            attachmentPlaceholderCount: historyCounts.attachments,
            degradedItemCount: historyCounts.degraded
        )
    }

    private static func loadOpenMinisInputFiles(_ fileURL: URL) throws -> [OpenMinisInputFile] {
        if isDirectory(fileURL) {
            return try loadOpenMinisDirectory(fileURL)
        }
        if isLikelyCompressedBackup(fileURL) {
            return try loadOpenMinisArchive(fileURL)
        }
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard values.fileSize ?? 0 <= OpenMinisImportBoundary.maximumRelevantFileBytes,
              let data = try? Data(contentsOf: fileURL) else {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: NSLocalizedString("OpenMinis 文件过大或无法读取。", comment: "OpenMinis file too large")
            )
        }
        return [OpenMinisInputFile(path: fileURL.lastPathComponent, data: data)]
    }

    private static func loadOpenMinisDirectory(_ directoryURL: URL) throws -> [OpenMinisInputFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { throw ThirdPartyImportError.fileNotReadable }
        var candidates: [(url: URL, path: String, size: Int)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isDirectory != true, values.isSymbolicLink != true else { continue }
            let relativePath = String(url.path.dropFirst(directoryURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard isSafeOpenMinisArchivePath(relativePath) else { continue }
            let fileSize = values.fileSize ?? 0
            candidates.append((url, relativePath, fileSize))
        }

        let skillRoots = openMinisSkillRoots(paths: candidates.map(\.path))
        var files: [OpenMinisInputFile] = []
        var relevantBytes = 0
        for candidate in candidates where isOpenMinisRelevantPath(candidate.path, skillRoots: skillRoots) {
            let fileSize = candidate.size
            guard fileSize <= OpenMinisImportBoundary.maximumRelevantFileBytes else {
                throw ThirdPartyImportError.unsupportedBackupFormat(
                    reason: NSLocalizedString("OpenMinis 备份中的单个相关文件超过安全大小。", comment: "OpenMinis relevant file too large")
                )
            }
            relevantBytes += fileSize
            guard relevantBytes <= OpenMinisImportBoundary.maximumRelevantBytes else {
                throw ThirdPartyImportError.unsupportedBackupFormat(
                    reason: NSLocalizedString("OpenMinis 备份展开后的相关数据过大。", comment: "OpenMinis expanded data too large")
                )
            }
            files.append(OpenMinisInputFile(path: candidate.path, data: try Data(contentsOf: candidate.url)))
        }
        return files
    }

    private static func loadOpenMinisArchive(_ archiveURL: URL) throws -> [OpenMinisInputFile] {
        let archive = try Archive(url: archiveURL, accessMode: .read)
        let entries = Array(archive)
        guard entries.count <= OpenMinisImportBoundary.maximumArchiveEntries else {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: NSLocalizedString("OpenMinis ZIP 文件数量异常，已拒绝导入。", comment: "OpenMinis excessive ZIP entries")
            )
        }
        guard entries.filter({ $0.type == .file }).allSatisfy({ isSafeOpenMinisArchivePath($0.path) }) else {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: NSLocalizedString("OpenMinis ZIP 包含不安全路径，已拒绝导入。", comment: "OpenMinis ZIP unsafe path")
            )
        }
        let skillRoots = openMinisSkillRoots(paths: entries.filter { $0.type == .file }.map(\.path))
        var files: [OpenMinisInputFile] = []
        var expandedBytes: UInt64 = 0
        var relevantBytes = 0

        for entry in entries {
            expandedBytes += UInt64(entry.uncompressedSize)
            guard expandedBytes <= UInt64(OpenMinisImportBoundary.maximumExpandedBytes) else {
                throw ThirdPartyImportError.unsupportedBackupFormat(
                    reason: NSLocalizedString("OpenMinis ZIP 展开体积超过安全限制。", comment: "OpenMinis ZIP expanded size limit")
                )
            }
            guard entry.type == .file,
                  isSafeOpenMinisArchivePath(entry.path),
                  isOpenMinisRelevantPath(entry.path, skillRoots: skillRoots) else { continue }
            guard Int(entry.uncompressedSize) <= OpenMinisImportBoundary.maximumRelevantFileBytes else {
                throw ThirdPartyImportError.unsupportedBackupFormat(
                    reason: NSLocalizedString("OpenMinis ZIP 中的单个相关文件超过安全大小。", comment: "OpenMinis ZIP relevant file too large")
                )
            }
            var data = Data()
            data.reserveCapacity(Int(entry.uncompressedSize))
            _ = try archive.extract(entry) { chunk in
                data.append(chunk)
            }
            relevantBytes += data.count
            guard relevantBytes <= OpenMinisImportBoundary.maximumRelevantBytes else {
                throw ThirdPartyImportError.unsupportedBackupFormat(
                    reason: NSLocalizedString("OpenMinis ZIP 中的相关数据超过安全限制。", comment: "OpenMinis ZIP relevant data limit")
                )
            }
            files.append(OpenMinisInputFile(path: entry.path, data: data))
        }
        return files
    }

    private static func isOpenMinisRelevantPath(_ path: String, skillRoots: Set<String>) -> Bool {
        let lower = path.lowercased()
        if lower.hasSuffix(".json") { return true }
        return skillRoots.contains { root in
            root.isEmpty || path == root || path.hasPrefix(root + "/")
        }
    }

    private static func openMinisSkillRoots(paths: [String]) -> Set<String> {
        Set(paths.compactMap { path in
            let lower = path.lowercased()
            guard lower == "skill.md" || lower.hasSuffix("/skill.md") else { return nil }
            return (path as NSString).deletingLastPathComponent
        })
    }

    private static func isSafeOpenMinisArchivePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func parseOpenMinisIOSSessions(_ json: Any) -> [SyncedSession]? {
        let rawSessions: [[String: Any]]
        if let array = json as? [[String: Any]], array.contains(where: { $0["messages"] != nil }) {
            rawSessions = array
        } else if let root = json as? [String: Any], let sessions = root["sessions"] as? [[String: Any]] {
            rawSessions = sessions
        } else {
            return nil
        }

        return rawSessions.enumerated().compactMap { index, raw in
            let sessionSeed = nonEmpty(string(raw["id"]))
                ?? nonEmpty(string(raw["title"]))
                ?? "index-\(index)"
            let messages = normalizeJSONArray(raw["messages"]).enumerated().compactMap { messageIndex, message in
                parseOpenMinisIOSMessage(
                    message,
                    sessionSeed: sessionSeed,
                    messageIndex: messageIndex
                )
            }
            guard !messages.isEmpty else { return nil }
            let session = ChatSession(
                id: stableUUID(from: "openminis-ios-session:\(sessionSeed)") ?? UUID(),
                name: nonEmpty(string(raw["title"]))
                    ?? String(format: NSLocalizedString("OpenMinis 对话 %d", comment: "OpenMinis session fallback title"), index + 1),
                preferredModelIdentifier: nonEmpty(string(raw["modelId"])),
                isTemporary: false
            )
            return SyncedSession(session: session, messages: messages)
        }
    }

    private static func parseOpenMinisIOSMessage(
        _ raw: Any,
        sessionSeed: String,
        messageIndex: Int
    ) -> ChatMessage? {
        guard let message = dictionary(raw) else { return nil }
        let role = mapMessageRole(string(message["role"]))
        let parts = normalizeJSONArray(message["parts"])
        var contentParts: [String] = []
        for rawPart in parts {
            guard let part = dictionary(rawPart) else { continue }
            switch normalizedTypeString(string(part["type"])) {
            case "text":
                if let text = nonEmpty(string(part["text"]) ?? string(part["value"])) { contentParts.append(text) }
            case "tool-use", "tool_use":
                let name = nonEmpty(string(part["name"])) ?? NSLocalizedString("未知工具", comment: "Unknown imported tool")
                contentParts.append(String(format: NSLocalizedString("[工具调用：%@]", comment: "Imported tool use placeholder"), name))
            case "tool-result", "tool_result":
                let output = nonEmpty(string(part["output"]) ?? string(part["snapshot"]))
                contentParts.append(output.map { String(format: NSLocalizedString("[工具结果]\n%@", comment: "Imported tool result placeholder"), $0) }
                    ?? NSLocalizedString("[工具结果]", comment: "Imported empty tool result placeholder"))
            case "media":
                contentParts.append(NSLocalizedString("[附件未包含在 OpenMinis 导出中]", comment: "OpenMinis missing attachment placeholder"))
            default:
                if let text = flattenText(part) { contentParts.append(text) }
            }
        }
        if contentParts.isEmpty, let content = flattenText(message["content"]) {
            contentParts.append(content)
        }
        let content = contentParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        let messageSeed = nonEmpty(string(message["id"])) ?? "index-\(messageIndex)"
        return ChatMessage(
            id: stableUUID(from: "openminis-ios-message:\(sessionSeed):\(messageSeed)") ?? UUID(),
            role: role,
            content: content,
            requestedAt: parseDate(message["createdAt"] ?? message["created_at"]),
            reasoningContent: nonEmpty(string(message["reasoning"])),
            tokenUsage: openMinisTokenUsage(message["tokenUsage"])
        )
    }

    private static func openMinisSessionMetadata(_ files: [OpenMinisInputFile]) -> [String: [String: Any]] {
        files.reduce(into: [:]) { result, file in
            guard file.path.lowercased().hasSuffix("session.json"),
                  let root = tryParseDictionaryJSON(file.data) else { return }
            result[(file.path as NSString).deletingLastPathComponent] = root
        }
    }

    private static func parseOpenMinisAndroidSession(
        messages: [[String: Any]],
        metadata: [String: Any],
        directory: String
    ) -> SyncedSession? {
        let sessionSeed = nonEmpty(string(metadata["id"]))
            ?? nonEmpty(directory)
            ?? nonEmpty(string(metadata["title"]))
            ?? "root"
        let parsedMessages = messages.enumerated().compactMap { messageIndex, raw -> ChatMessage? in
            let role = mapMessageRole(string(raw["role"]))
            let rawContent = string(raw["content"]) ?? ""
            let content: String
            if let data = rawContent.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data),
               let parts = decoded as? [Any] {
                let flattened = parts.compactMap(openMinisAndroidPartText).joined(separator: "\n")
                content = flattened.isEmpty ? rawContent : flattened
            } else {
                content = rawContent
            }
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let messageSeed = nonEmpty(string(raw["id"])) ?? "index-\(messageIndex)"
            return ChatMessage(
                id: stableUUID(from: "openminis-android-message:\(sessionSeed):\(messageSeed)") ?? UUID(),
                role: role,
                content: content,
                requestedAt: parseDate(raw["created_at"])
            )
        }
        guard !parsedMessages.isEmpty else { return nil }
        let id = stableUUID(from: "openminis-android-session:\(sessionSeed)") ?? UUID()
        let title = nonEmpty(string(metadata["title"])) ?? NSLocalizedString("OpenMinis Android 对话", comment: "OpenMinis Android session fallback title")
        return SyncedSession(
            session: ChatSession(
                id: id,
                name: title,
                preferredModelIdentifier: nonEmpty(string(metadata["model_id"])),
                isTemporary: false
            ),
            messages: parsedMessages
        )
    }

    private static func openMinisTokenUsage(_ raw: Any?) -> MessageTokenUsage? {
        guard let usage = dictionary(raw) else { return nil }
        let parsed = MessageTokenUsage(
            promptTokens: int(usage["inputTokens"]),
            completionTokens: int(usage["outputTokens"]),
            totalTokens: nil,
            cacheWriteTokens: int(usage["cacheCreationTokens"]),
            cacheReadTokens: int(usage["cacheReadTokens"])
        )
        return parsed.hasAnyData ? parsed : nil
    }

    private static func openMinisAndroidPartText(_ raw: Any) -> String? {
        guard let part = dictionary(raw) else { return flattenText(raw) }
        let type = normalizedTypeString(string(part["type"]))
        let value = part["value"]
        switch type {
        case "text":
            return flattenText(value)
        case "mediaref":
            let media = dictionary(value) ?? [:]
            let name = nonEmpty(string(media["originalFileName"]))
                ?? nonEmpty(string(media["relativePath"]))
                ?? NSLocalizedString("附件", comment: "OpenMinis Android attachment fallback name")
            let mime = nonEmpty(string(media["mimeType"]))
            if let mime {
                return String(
                    format: NSLocalizedString("[附件未包含在 OpenMinis 导出中：%@（%@）]", comment: "OpenMinis Android missing attachment placeholder"),
                    name,
                    mime
                )
            }
            return String(
                format: NSLocalizedString("[附件未包含在 OpenMinis 导出中：%@]", comment: "OpenMinis Android missing attachment placeholder"),
                name
            )
        case "tooluse":
            let tool = dictionary(value) ?? [:]
            let name = nonEmpty(string(tool["name"])) ?? NSLocalizedString("未知工具", comment: "Unknown imported tool")
            let input = nonEmpty(string(tool["input"]))
            let title = String(format: NSLocalizedString("[工具调用：%@]", comment: "Imported tool use placeholder"), name)
            return input.map { title + "\n" + $0 } ?? title
        case "toolresult":
            let result = dictionary(value) ?? [:]
            let output = nonEmpty(string(result["output"]))
            return output.map {
                String(format: NSLocalizedString("[工具结果]\n%@", comment: "Imported tool result placeholder"), $0)
            } ?? NSLocalizedString("[工具结果]", comment: "Imported empty tool result placeholder")
        default:
            return flattenText(value ?? part)
        }
    }

    private static func parseOpenMinisProvider(
        _ root: [String: Any],
        containsSensitiveCredentials: inout Bool,
        warnings: inout [String]
    ) -> Provider? {
        let config = dictionary(root["config"]) ?? root
        guard let rawType = nonEmpty(string(config["providerType"])),
              let label = nonEmpty(string(config["label"])) else { return nil }

        let rawModels = normalizeJSONArray(config["models"]).compactMap(dictionary)
        let modelIDs = rawModels.compactMap { nonEmpty(string($0["modelId"]) ?? string($0["id"])) }
        let apiFormat: String
        switch normalizedTypeString(rawType) {
        case "openairesponses", "openai-responses": apiFormat = "openai-responses"
        case "anthropic", "claude": apiFormat = "anthropic"
        case "gemini", "google": apiFormat = "gemini"
        default: apiFormat = normalizeProviderFormat(typeHint: rawType, modelIDs: modelIDs)
        }
        let providerSeed = nonEmpty(string(root["instanceId"])) ?? label
        let models = rawModels.compactMap { raw -> Model? in
            guard let modelID = nonEmpty(string(raw["modelId"]) ?? string(raw["id"])) else { return nil }
            let overrides = dictionary(raw["overrides"]) ?? [:]
            let modalityRaw = int(overrides["modalityOverride"] ?? raw["modalityOverride"])
            let supportsReasoning = boolValue(overrides["supportsReasoning"] ?? raw["supportsReasoning"])
            var capabilities = Model.defaultCapabilities
            if supportsReasoning == true { capabilities.append(.reasoning) }
            var model = importedModel(
                modelName: modelID,
                displayName: nonEmpty(string(overrides["displayName"]))
                    ?? nonEmpty(string(raw["displayName"]))
                    ?? modelID,
                isActivated: !bool(raw["isHidden"], defaultValue: false),
                useResponsesAPI: apiFormat == "openai-responses",
                kind: .chat,
                inputModalities: openMinisInputModalities(rawValue: modalityRaw),
                outputModalities: openMinisOutputModalities(rawValue: modalityRaw),
                capabilities: capabilities
            ).applyingInferredCapabilityHints()
            model.id = stableUUID(from: "openminis-model:\(providerSeed):\(modelID)") ?? model.id
            return model
        }

        var apiKeys: [String] = []
        if let encoded = nonEmpty(string(config["apiKey"])) {
            containsSensitiveCredentials = true
            if let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty {
                apiKeys = [decoded]
            } else {
                apiKeys = [encoded]
            }
        }
        if ["manualOAuthToken", "oauthToken", "oauthEmail", "oauthGcpProject"].contains(where: { config[$0] != nil }) {
            containsSensitiveCredentials = true
            warnings.append(
                String(
                    format: NSLocalizedString("OpenMinis Provider“%@”包含 OAuth 凭据；ELS 不会恢复该登录状态，请在导入后重新登录。", comment: "OpenMinis OAuth provider warning"),
                    label
                )
            )
        }
        let baseURL = nonEmpty(string(config["customBaseURL"])) ?? openMinisDefaultBaseURL(rawType)
        return Provider(
            id: stableUUID(from: "openminis-provider:\(providerSeed)") ?? UUID(),
            name: label,
            baseURL: normalizeBaseURL(baseURL, for: apiFormat),
            apiKeys: apiKeys,
            apiFormat: apiFormat,
            models: normalizeModelsForProviderFormat(models, apiFormat: apiFormat)
        )
    }

    private static func openMinisDefaultBaseURL(_ rawType: String) -> String {
        switch normalizedTypeString(rawType) {
        case "anthropic", "claude": return "https://api.anthropic.com"
        case "gemini", "google": return "https://generativelanguage.googleapis.com"
        case "openrouter": return "https://openrouter.ai/api/v1"
        case "deepseek": return "https://api.deepseek.com"
        case "xai": return "https://api.x.ai/v1"
        case "groq": return "https://api.groq.com/openai/v1"
        case "mistral": return "https://api.mistral.ai/v1"
        default: return "https://api.openai.com"
        }
    }

    private static func parseOpenMinisSkills(_ files: [OpenMinisInputFile]) -> [SyncedSkillBundle] {
        let roots = openMinisSkillRoots(paths: files.map(\.path))
        var seenNames = Set<String>()
        return roots.sorted().compactMap { root in
            let manifestPath = root.isEmpty ? "SKILL.md" : root + "/SKILL.md"
            guard let manifestFile = files.first(where: {
                $0.path.caseInsensitiveCompare(manifestPath) == .orderedSame
            }), let content = String(data: manifestFile.data, encoding: .utf8) else {
                return nil
            }
            let fallbackName = root.isEmpty ? nil : (root as NSString).lastPathComponent
            guard let manifest = try? SkillManifestResolver.resolve(content: content, fallbackName: fallbackName),
                  seenNames.insert(manifest.name).inserted else {
                return nil
            }

            let nestedRoots = roots.filter { $0 != root && ($0.hasPrefix(root + "/") || root.isEmpty) }
            let skillFiles = files.compactMap { file -> SyncedSkillFile? in
                let relativePath: String
                if root.isEmpty {
                    relativePath = file.path
                } else {
                    let prefix = root + "/"
                    guard file.path.hasPrefix(prefix) else { return nil }
                    relativePath = String(file.path.dropFirst(prefix.count))
                }
                guard !nestedRoots.contains(where: { nested in
                    let nestedPrefix = root.isEmpty ? nested + "/" : String(nested.dropFirst(root.count + 1)) + "/"
                    return relativePath.hasPrefix(nestedPrefix)
                }), let normalized = SkillResourcePolicy.normalizeRelativePath(relativePath) else {
                    return nil
                }
                return SyncedSkillFile(relativePath: normalized, data: file.data)
            }
            guard skillFiles.contains(where: { $0.relativePath == "SKILL.md" }) else { return nil }
            return SyncedSkillBundle(name: manifest.name, files: skillFiles)
        }
    }

    private static func dedupeOpenMinisSessions(_ sessions: [SyncedSession]) -> [SyncedSession] {
        var seen = Set<UUID>()
        return sessions.filter { seen.insert($0.session.id).inserted }
    }

    private static func dedupeOpenMinisMCPServers(_ servers: [MCPServerConfiguration]) -> [MCPServerConfiguration] {
        var seen = Set<String>()
        return servers.filter { server in
            let key = "\(server.displayName.lowercased())|\(server.humanReadableEndpoint.lowercased())"
            return seen.insert(key).inserted
        }
    }

    private static func openMinisInputModalities(rawValue: Int?) -> [ModelModality]? {
        guard let rawValue else { return nil }
        var result: [ModelModality] = []
        if rawValue & (1 << 0) != 0 { result.append(.text) }
        if rawValue & (1 << 2) != 0 { result.append(.image) }
        if rawValue & (1 << 3) != 0 { result.append(.file) }
        if rawValue & (1 << 4) != 0 { result.append(.audio) }
        if rawValue & (1 << 5) != 0 { result.append(.video) }
        return result.isEmpty ? nil : result
    }

    private static func openMinisOutputModalities(rawValue: Int?) -> [ModelModality]? {
        guard let rawValue else { return nil }
        var result: [ModelModality] = []
        if rawValue & (1 << 1) != 0 { result.append(.text) }
        if rawValue & (1 << 6) != 0 { result.append(.image) }
        if rawValue & (1 << 7) != 0 { result.append(.audio) }
        return result.isEmpty ? nil : result
    }

    private static func boolValue(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let value = raw as? NSNumber { return value.boolValue }
        return nil
    }

    private static func openMinisHistoryCounts(
        _ sessions: [SyncedSession]
    ) -> (messages: Int, attachments: Int, degraded: Int) {
        let attachmentMarkers = [
            NSLocalizedString("[附件未包含在 OpenMinis 导出中", comment: "OpenMinis missing attachment marker")
        ]
        let degradedMarkers = attachmentMarkers + [
            NSLocalizedString("[工具调用：", comment: "OpenMinis imported tool use marker"),
            NSLocalizedString("[工具结果]", comment: "OpenMinis imported tool result marker")
        ]
        let contents = sessions.flatMap(\.messages).map(\.content)
        let attachments = contents.reduce(0) { total, content in
            total + attachmentMarkers.reduce(0) { $0 + content.numberOfOccurrences(of: $1) }
        }
        let degraded = contents.reduce(0) { total, content in
            total + degradedMarkers.reduce(0) { $0 + content.numberOfOccurrences(of: $1) }
        }
        return (contents.count, attachments, degraded)
    }
}

private extension String {
    func numberOfOccurrences(of value: String) -> Int {
        guard !value.isEmpty else { return 0 }
        return components(separatedBy: value).count - 1
    }
}

private enum OpenMinisImportBoundary {
    static let maximumArchiveEntries = 10_000
    static let maximumExpandedBytes = 512 * 1_024 * 1_024
    static let maximumRelevantBytes = 256 * 1_024 * 1_024
    static let maximumRelevantFileBytes = 128 * 1_024 * 1_024
}
