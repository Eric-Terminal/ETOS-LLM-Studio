// ============================================================================
// SyncEngineCollections.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载记忆、MCP、媒体、字体、技能、快捷工具与世界书同步逻辑。
// ============================================================================

import Foundation
import Combine

extension SyncEngine {
    // MARK: - Session Tags

    static func mergeSessionTags(
        _ incoming: [SessionTag],
        chatService: ChatService
    ) -> (imported: Int, skipped: Int, idMapping: [UUID: UUID]) {
        guard !incoming.isEmpty else { return (0, 0, [:]) }

        var local = chatService.sessionTagsSubject.value
        var imported = 0
        var skipped = 0
        var idMapping: [UUID: UUID] = [:]
        var changed = false

        for incomingTag in incoming {
            let trimmedName = incomingTag.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                skipped += 1
                continue
            }

            var tag = incomingTag
            tag.name = trimmedName

            if let existingIndex = local.firstIndex(where: { $0.id == tag.id }) {
                idMapping[tag.id] = local[existingIndex].id
                if shouldAdoptIncomingSessionTag(local: local[existingIndex], incoming: tag),
                   !local.contains(where: { candidate in
                       candidate.id != tag.id
                           && shouldMergeSessionTagsByName(candidate, tag)
                   }) {
                    local[existingIndex].name = tag.name
                    local[existingIndex].color = tag.color
                    local[existingIndex].updatedAt = tag.updatedAt
                    imported += 1
                    changed = true
                } else {
                    skipped += 1
                }
                continue
            }

            if let sameNameIndex = local.firstIndex(where: { shouldMergeSessionTagsByName($0, tag) }) {
                idMapping[tag.id] = local[sameNameIndex].id
                if shouldAdoptIncomingSessionTag(local: local[sameNameIndex], incoming: tag) {
                    local[sameNameIndex].color = tag.color
                    local[sameNameIndex].updatedAt = tag.updatedAt
                    imported += 1
                    changed = true
                } else {
                    skipped += 1
                }
                continue
            }

            local.append(tag)
            idMapping[tag.id] = tag.id
            imported += 1
            changed = true
        }

        if changed {
            local = local.sorted { left, right in
                let order = left.name.localizedStandardCompare(right.name)
                if order != .orderedSame {
                    return order == .orderedAscending
                }
                return left.id.uuidString < right.id.uuidString
            }
            Persistence.saveSessionTags(local)
            chatService.sessionTagsSubject.send(local)
        }

        return (imported, skipped, idMapping)
    }

    static func remapSessionTagReferences(
        _ sessions: [SyncedSession],
        idMapping: [UUID: UUID]
    ) -> [SyncedSession] {
        guard !idMapping.isEmpty else { return sessions }
        return sessions.map { payload in
            var updated = payload
            var seen = Set<UUID>()
            updated.session.tagIDs = payload.session.tagIDs.compactMap { tagID in
                let mapped = idMapping[tagID] ?? tagID
                return seen.insert(mapped).inserted ? mapped : nil
            }
            return updated
        }
    }

    static func shouldAdoptIncomingSessionTag(local: SessionTag, incoming: SessionTag) -> Bool {
        guard incoming.updatedAt > local.updatedAt else { return false }
        return local.name != incoming.name || local.color != incoming.color
    }

    static func shouldMergeSessionTagsByName(_ local: SessionTag, _ incoming: SessionTag) -> Bool {
        local.isSystemColorTag == incoming.isSystemColorTag
            && normalizedSessionTagName(local.name) == normalizedSessionTagName(incoming.name)
    }

    static func normalizedSessionTagName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Memories

    static func mergeMemories(
        _ incoming: [MemoryItem],
        memoryManager: MemoryManager
    ) async -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }

        let existingMemories = await memoryManager.getAllMemories()
        var normalizedContents = Set(existingMemories.map { normalizeContent($0.content) })
        var existingIDs = Set(existingMemories.map { $0.id })
        var imported = 0
        var skipped = 0

        for var memory in incoming {
            let normalized = normalizeContent(memory.content)
            guard !normalized.isEmpty else {
                skipped += 1
                continue
            }

            if normalizedContents.contains(normalized) {
                skipped += 1
                continue
            }

            if existingIDs.contains(memory.id) {
                memory.id = UUID()
            }

            let success = await memoryManager.restoreMemory(memory)

            if success {
                imported += 1
                normalizedContents.insert(normalized)
                existingIDs.insert(memory.id)
            } else {
                skipped += 1
            }
        }

        return (imported, skipped)
    }

    static func mergeConversationUserProfile(
        _ incoming: ConversationUserProfile?
    ) -> (imported: Int, skipped: Int) {
        guard let incoming else { return (0, 0) }
        let incomingContent = incoming.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incomingContent.isEmpty || !incoming.facts.isEmpty else { return (0, 1) }

        guard let local = ConversationMemoryManager.loadUserProfile() else {
            do {
                try ConversationMemoryManager.saveUserProfile(incoming)
                return (1, 0)
            } catch {
                return (0, 1)
            }
        }

        let localContent = local.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizeContent(localContent) == normalizeContent(incomingContent),
           local.needsLLMDedup == incoming.needsLLMDedup,
           local.facts == incoming.facts {
            return (0, 1)
        }

        let mergedProfile = mergeConversationUserProfile(local: local, incoming: incoming)
        do {
            try ConversationMemoryManager.saveUserProfile(mergedProfile)
            return (1, 0)
        } catch {
            return (0, 1)
        }
    }

    static func mergeConversationUserProfile(
        local: ConversationUserProfile,
        incoming: ConversationUserProfile
    ) -> ConversationUserProfile {
        let localContent = local.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingContent = incoming.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let latestUpdatedAt = max(local.updatedAt, incoming.updatedAt)
        let sourceSessionID = incoming.updatedAt >= local.updatedAt
            ? incoming.sourceSessionID ?? local.sourceSessionID
            : local.sourceSessionID ?? incoming.sourceSessionID
        let mergedFacts = mergedConversationProfileFacts(local.facts, incoming.facts)

        if localContent.isEmpty {
            return ConversationUserProfile(
                content: incomingContent,
                updatedAt: latestUpdatedAt,
                sourceSessionID: sourceSessionID,
                needsLLMDedup: incoming.needsLLMDedup,
                facts: mergedFacts
            )
        }
        if incomingContent.isEmpty || normalizeContent(localContent) == normalizeContent(incomingContent) {
            return ConversationUserProfile(
                content: localContent,
                updatedAt: latestUpdatedAt,
                sourceSessionID: sourceSessionID,
                needsLLMDedup: local.needsLLMDedup || incoming.needsLLMDedup,
                facts: mergedFacts
            )
        }

        let stitchedSegments = mergedConversationProfileSegments(localContent, incomingContent)
        let stitched = stitchedSegments.joined(separator: "\n\n")
        return ConversationUserProfile(
            content: stitched,
            updatedAt: latestUpdatedAt,
            sourceSessionID: sourceSessionID,
            needsLLMDedup: stitchedSegments.count > 1 || local.needsLLMDedup || incoming.needsLLMDedup,
            facts: mergedFacts
        )
    }

    static func mergedConversationProfileFacts(
        _ local: [ConversationProfileFact],
        _ incoming: [ConversationProfileFact]
    ) -> [ConversationProfileFact] {
        var merged: [String: ConversationProfileFact] = [:]
        for fact in local + incoming {
            let key = "\(fact.category.rawValue)|\(normalizeContent(fact.statement))"
            guard !key.hasSuffix("|") else { continue }
            if let existing = merged[key] {
                merged[key] = ConversationProfileFact(
                    id: existing.id,
                    category: fact.category,
                    statement: fact.lastObservedAt >= existing.lastObservedAt ? fact.statement : existing.statement,
                    confidence: max(existing.confidence, fact.confidence),
                    evidenceCount: max(existing.evidenceCount, fact.evidenceCount),
                    firstObservedAt: min(existing.firstObservedAt, fact.firstObservedAt),
                    lastObservedAt: max(existing.lastObservedAt, fact.lastObservedAt),
                    sourceSessionIDs: existing.sourceSessionIDs + fact.sourceSessionIDs
                )
            } else {
                merged[key] = fact
            }
        }
        return merged.values.sorted {
            if $0.category == $1.category {
                return $0.statement.localizedStandardCompare($1.statement) == .orderedAscending
            }
            return $0.category.rawValue < $1.category.rawValue
        }
    }

    static func mergedConversationProfileSegments(_ local: String, _ incoming: String) -> [String] {
        var uniqueSegments: [String: String] = [:]
        for segment in conversationProfileSegments(local) + conversationProfileSegments(incoming) {
            let normalized = normalizeContent(segment)
            guard !normalized.isEmpty else { continue }
            uniqueSegments[normalized] = segment
        }
        return uniqueSegments
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map(\.value)
    }

    static func conversationProfileSegments(_ content: String) -> [String] {
        content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func normalizeContent(_ content: String) -> String {
        content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    // MARK: - MCP Servers

    static func mergeMCPServers(_ incoming: [MCPServerConfiguration]) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }

        var local = MCPServerStore.loadServers()
        var imported = 0
        var skipped = 0
        var localContentHashes = Set(local.map { computeMCPServerContentHash($0) })

        for var server in incoming {
            let incomingHash = computeMCPServerContentHash(server)
            if localContentHashes.contains(incomingHash) {
                skipped += 1
                continue
            }

            if local.firstIndex(where: { $0.id == server.id }) != nil {
                server.id = UUID()
            }

            MCPServerStore.save(server)
            local.append(server)
            localContentHashes.insert(incomingHash)
            imported += 1
        }

        return (imported, skipped)
    }

    // MARK: - Audio Files

    static func mergeAudioFiles(_ incoming: [SyncedAudio]) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }

        var imported = 0
        var skipped = 0
        let existingFileNames = Set(Persistence.getAllAudioFileNames())
        var existingChecksums = Set<String>()
        for fileName in existingFileNames {
            if let data = Persistence.loadAudio(fileName: fileName) {
                existingChecksums.insert(data.sha256Hex)
            }
        }

        for audio in incoming {
            if existingChecksums.contains(audio.checksum) {
                skipped += 1
                continue
            }

            var targetFileName = audio.filename
            if existingFileNames.contains(audio.filename) {
                let ext = (audio.filename as NSString).pathExtension
                let name = (audio.filename as NSString).deletingPathExtension
                targetFileName = "\(name)_\(UUID().uuidString.prefix(8)).\(ext)"
            }

            if Persistence.saveAudio(audio.data, fileName: targetFileName) != nil {
                imported += 1
                existingChecksums.insert(audio.checksum)
            } else {
                skipped += 1
            }
        }

        return (imported, skipped)
    }

    static func mergeImageFiles(_ incoming: [SyncedImage]) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }

        var imported = 0
        var skipped = 0
        let existingFileNames = Set(Persistence.getAllImageFileNames())
        var existingChecksums = Set<String>()
        for fileName in existingFileNames {
            if let data = Persistence.loadImage(fileName: fileName) {
                existingChecksums.insert(data.sha256Hex)
            }
        }

        for image in incoming {
            if existingChecksums.contains(image.checksum) {
                skipped += 1
                continue
            }

            var targetFileName = image.filename
            if existingFileNames.contains(image.filename) {
                let ext = (image.filename as NSString).pathExtension
                let name = (image.filename as NSString).deletingPathExtension
                targetFileName = "\(name)_\(UUID().uuidString.prefix(8)).\(ext)"
            }

            if Persistence.saveImage(image.data, fileName: targetFileName) != nil {
                imported += 1
                existingChecksums.insert(image.checksum)
            } else {
                skipped += 1
            }
        }

        return (imported, skipped)
    }

    static func remapSessionMediaReferences(
        _ sessions: [SyncedSession],
        audioFiles: [SyncedAudio],
        imageFiles: [SyncedImage]
    ) -> [SyncedSession] {
        guard !sessions.isEmpty else { return sessions }
        let audioMapping = existingAudioFileNameByIncomingName(audioFiles)
        let imageMapping = existingImageFileNameByIncomingName(imageFiles)
        guard !audioMapping.isEmpty || !imageMapping.isEmpty else { return sessions }

        return sessions.map { payload in
            var messages = payload.messages
            for index in messages.indices {
                if let audioFileName = messages[index].audioFileName,
                   let mappedAudioFileName = audioMapping[audioFileName] {
                    messages[index].audioFileName = mappedAudioFileName
                }
                if let imageFileNames = messages[index].imageFileNames {
                    let mappedImageFileNames = imageFileNames.map { imageMapping[$0] ?? $0 }
                    messages[index].imageFileNames = mappedImageFileNames
                }
            }
            return SyncedSession(session: payload.session, messages: messages)
        }
    }

    static func existingAudioFileNameByIncomingName(_ incoming: [SyncedAudio]) -> [String: String] {
        guard !incoming.isEmpty else { return [:] }
        let existingByChecksum = existingMediaFileNameByChecksum(
            fileNames: Persistence.getAllAudioFileNames(),
            loader: { Persistence.loadAudio(fileName: $0) }
        )
        return mediaFileNameMapping(
            incoming.map { (fileName: $0.filename, checksum: $0.checksum) },
            existingByChecksum: existingByChecksum
        )
    }

    static func existingImageFileNameByIncomingName(_ incoming: [SyncedImage]) -> [String: String] {
        guard !incoming.isEmpty else { return [:] }
        let existingByChecksum = existingMediaFileNameByChecksum(
            fileNames: Persistence.getAllImageFileNames(),
            loader: { Persistence.loadImage(fileName: $0) }
        )
        return mediaFileNameMapping(
            incoming.map { (fileName: $0.filename, checksum: $0.checksum) },
            existingByChecksum: existingByChecksum
        )
    }

    static func existingMediaFileNameByChecksum(
        fileNames: [String],
        loader: (String) -> Data?
    ) -> [String: String] {
        var result: [String: String] = [:]
        for fileName in fileNames {
            guard let data = loader(fileName) else { continue }
            result[data.sha256Hex] = fileName
        }
        return result
    }

    static func mediaFileNameMapping(
        _ incoming: [(fileName: String, checksum: String)],
        existingByChecksum: [String: String]
    ) -> [String: String] {
        var mapping: [String: String] = [:]
        for item in incoming {
            guard let existingFileName = existingByChecksum[item.checksum],
                  existingFileName != item.fileName else {
                continue
            }
            mapping[item.fileName] = existingFileName
        }
        return mapping
    }

    // MARK: - Font Files

    static func mergeFontFiles(_ incoming: [SyncedFontFile]) -> (imported: Int, skipped: Int, idMapping: [UUID: UUID]) {
        guard !incoming.isEmpty else { return (0, 0, [:]) }

        var imported = 0
        var skipped = 0
        var idMapping: [UUID: UUID] = [:]
        let existingAssets = FontLibrary.loadAssets()
        var knownChecksums = Set(existingAssets.map(\.checksum))
        var knownEnabledStatesByChecksum = Dictionary(uniqueKeysWithValues: existingAssets.map { ($0.checksum, $0.isEnabled) })

        for fontFile in incoming {
            do {
                let existedBefore = knownChecksums.contains(fontFile.checksum)
                let previousEnabledState = knownEnabledStatesByChecksum[fontFile.checksum]
                let record = try FontLibrary.importFont(
                    data: fontFile.data,
                    fileName: fontFile.filename,
                    preferredDisplayName: fontFile.displayName
                )

                _ = FontLibrary.setAssetEnabled(id: record.id, isEnabled: fontFile.isEnabled)
                idMapping[fontFile.assetID] = record.id
                knownChecksums.insert(record.checksum)
                knownEnabledStatesByChecksum[record.checksum] = fontFile.isEnabled

                if existedBefore, previousEnabledState == fontFile.isEnabled {
                    skipped += 1
                } else {
                    imported += 1
                }
            } catch {
                skipped += 1
            }
        }

        return (imported, skipped, idMapping)
    }

    static func mergeFontRouteConfiguration(
        _ incomingData: Data?,
        idMapping: [UUID: UUID]
    ) -> (imported: Int, skipped: Int) {
        guard let incomingData else { return (0, 0) }
        guard let incoming = try? JSONDecoder().decode(FontRouteConfiguration.self, from: incomingData) else {
            return (0, 1)
        }

        let existingIDs = Set(FontLibrary.loadAssets().map(\.id))
        var normalized = FontRouteConfiguration(
            body: normalizeRouteIDs(incoming.body, idMapping: idMapping, validIDs: existingIDs),
            emphasis: normalizeRouteIDs(incoming.emphasis, idMapping: idMapping, validIDs: existingIDs),
            strong: normalizeRouteIDs(incoming.strong, idMapping: idMapping, validIDs: existingIDs),
            code: normalizeRouteIDs(incoming.code, idMapping: idMapping, validIDs: existingIDs),
            languageBuckets: [:]
        )

        for (bucketKey, bucketValue) in incoming.languageBuckets {
            normalized.languageBuckets[bucketKey] = FontRouteConfiguration.LanguageBucketConfiguration(
                body: normalizeRouteIDs(bucketValue.body, idMapping: idMapping, validIDs: existingIDs),
                emphasis: normalizeRouteIDs(bucketValue.emphasis, idMapping: idMapping, validIDs: existingIDs),
                strong: normalizeRouteIDs(bucketValue.strong, idMapping: idMapping, validIDs: existingIDs),
                code: normalizeRouteIDs(bucketValue.code, idMapping: idMapping, validIDs: existingIDs)
            )
        }

        let current = FontLibrary.loadRouteConfiguration()
        if current == normalized {
            return (0, 1)
        }

        _ = FontLibrary.saveRouteConfiguration(normalized)
        return (1, 0)
    }

    static func normalizeRouteIDs(
        _ ids: [UUID],
        idMapping: [UUID: UUID],
        validIDs: Set<UUID>
    ) -> [UUID] {
        var seen = Set<UUID>()
        var normalized: [UUID] = []

        for id in ids {
            let mapped = idMapping[id] ?? id
            guard validIDs.contains(mapped) else { continue }
            guard seen.insert(mapped).inserted else { continue }
            normalized.append(mapped)
        }

        return normalized
    }

    // MARK: - Skills

    static func mergeSkills(_ incoming: [SyncedSkillBundle]) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }

        var imported = 0
        var skipped = 0

        for bundle in incoming {
            let skillName = bundle.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard SkillPaths.isValidSkillName(skillName), !bundle.files.isEmpty else {
                skipped += 1
                continue
            }

            var incomingFiles: [String: Data] = [:]
            var hasDuplicatePath = false
            for file in bundle.files {
                let relativePath = file.relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !relativePath.isEmpty else {
                    hasDuplicatePath = true
                    break
                }
                if incomingFiles.updateValue(file.fileData, forKey: relativePath) != nil {
                    hasDuplicatePath = true
                    break
                }
            }
            guard !hasDuplicatePath else {
                skipped += 1
                continue
            }
            guard incomingFiles.keys.contains("SKILL.md") else {
                skipped += 1
                continue
            }

            let localFiles = SkillStore.readAllSkillFileData(skillName: skillName)
            if let localFiles {
                let localBundle = SyncedSkillBundle(
                    name: skillName,
                    files: localFiles
                        .map { SyncedSkillFile(relativePath: $0.key, data: $0.value) }
                )
                if localBundle.checksum == bundle.checksum {
                    skipped += 1
                    continue
                }
            }

            if SkillStore.saveSkillDataFilesAtomically(skillName: skillName, files: incomingFiles) {
                imported += 1
            } else {
                skipped += 1
            }
        }

        if imported > 0 {
            Task { @MainActor in
                SkillManager.shared.reloadFromDisk()
            }
        }

        return (imported, skipped)
    }

    // MARK: - Shortcut Tools

    static func mergeShortcutTools(_ incoming: [ShortcutToolDefinition]) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }

        var local = ShortcutToolStore.loadTools()
        var imported = 0
        var skipped = 0

        for incomingTool in incoming {
            if local.contains(where: { $0.isEquivalent(to: incomingTool) }) {
                skipped += 1
                continue
            }

            let incomingName = ShortcutToolNaming.normalizeExecutableName(incomingTool.name)
            if local.contains(where: { ShortcutToolNaming.normalizeExecutableName($0.name) == incomingName }) {
                skipped += 1
                continue
            }

            var copied = incomingTool
            copied.id = UUID()
            copied.createdAt = Date()
            copied.updatedAt = Date()
            copied.lastImportedAt = Date()
            local.append(copied)
            imported += 1
        }

        if imported > 0 {
            ShortcutToolStore.saveTools(local)
            Task { @MainActor in
                ShortcutToolManager.shared.reloadFromDisk()
            }
        }

        return (imported, skipped)
    }

    // MARK: - Worldbooks

    static func mergeWorldbooks(_ incoming: [Worldbook]) -> (imported: Int, skipped: Int, idMapping: [UUID: UUID]) {
        guard !incoming.isEmpty else { return (0, 0, [:]) }

        let store = WorldbookStore.shared
        var local = store.loadWorldbooks()
        var imported = 0
        var skipped = 0
        var idMapping: [UUID: UUID] = [:]

        var localHashes = Set(local.map(\.contentHash))
        var globalEntrySignatures = Set(
            local.flatMap { book in
                book.entries.map { worldbookEntrySignature($0) }
            }
        )

        for var incomingBook in incoming {
            let originalIncomingID = incomingBook.id
            if localHashes.contains(incomingBook.contentHash) {
                if let existing = local.first(where: { $0.contentHash == incomingBook.contentHash }) {
                    idMapping[originalIncomingID] = existing.id
                }
                skipped += 1
                continue
            }

            if local.contains(where: { $0.id == incomingBook.id }) {
                incomingBook.id = UUID()
            }

            var dedupedEntries = deduplicateWorldbookEntries(incomingBook.entries)
            dedupedEntries = dedupedEntries.filter { entry in
                let signature = worldbookEntrySignature(entry)
                if globalEntrySignatures.contains(signature) {
                    return false
                }
                globalEntrySignatures.insert(signature)
                return true
            }
            incomingBook.entries = dedupedEntries
            guard !incomingBook.entries.isEmpty else {
                if let sameName = local.first(where: {
                    $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        .localizedCaseInsensitiveCompare(incomingBook.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
                }) {
                    idMapping[originalIncomingID] = sameName.id
                }
                skipped += 1
                continue
            }

            let hasSameName = local.contains(where: {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare(incomingBook.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            })
            if hasSameName {
                incomingBook.name = WorldbookStore.uniqueSyncName(baseName: incomingBook.name, existing: local.map(\.name))
            }

            incomingBook.updatedAt = Date()
            local.append(incomingBook)
            localHashes.insert(incomingBook.contentHash)
            idMapping[originalIncomingID] = incomingBook.id
            imported += 1
        }

        if imported > 0 {
            store.saveWorldbooks(local)
        }
        return (imported, skipped, idMapping)
    }

    static func worldbookEntrySignature(_ entry: WorldbookEntry) -> String {
        let normalizedContent = WorldbookStore.normalizedContent(entry.content)
        let keys = entry.keys.map { $0.lowercased() }.sorted().joined(separator: "|")
        return "\(normalizedContent)::\(keys)"
    }

    static func deduplicateWorldbookEntries(_ entries: [WorldbookEntry]) -> [WorldbookEntry] {
        var result: [WorldbookEntry] = []
        var seen = Set<String>()
        for var entry in entries {
            let signature = worldbookEntrySignature(entry)
            if seen.contains(signature) {
                continue
            }
            if result.contains(where: { $0.id == entry.id }) {
                entry.id = UUID()
            }
            seen.insert(signature)
            result.append(entry)
        }
        return result
    }

    static func remapWorldbookIDsInSessions(
        _ idMapping: [UUID: UUID],
        chatService: ChatService
    ) {
        guard !idMapping.isEmpty else { return }
        var sessions = chatService.chatSessionsSubject.value
        var changed = false

        for index in sessions.indices {
            let oldIDs = sessions[index].lorebookIDs
            guard !oldIDs.isEmpty else { continue }
            let mapped = oldIDs.map { idMapping[$0] ?? $0 }
            var deduped: [UUID] = []
            var seen = Set<UUID>()
            for id in mapped where !seen.contains(id) {
                seen.insert(id)
                deduped.append(id)
            }
            if deduped != oldIDs {
                sessions[index].lorebookIDs = deduped
                changed = true
            }
        }

        guard changed else { return }
        Persistence.saveChatSessions(sessions)
        chatService.chatSessionsSubject.send(sessions)
        if let current = chatService.currentSessionSubject.value,
           let mappedCurrent = sessions.first(where: { $0.id == current.id }) {
            chatService.currentSessionSubject.send(mappedCurrent)
        }
    }
}
