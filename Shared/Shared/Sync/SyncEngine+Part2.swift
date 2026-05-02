import Foundation
import Combine

extension SyncEngine {
    static func mergeGlobalSystemPromptStorageKeys(
        in snapshot: inout [String: Any],
        legacyGlobalSystemPrompt: String?,
        userDefaults: UserDefaults
    ) -> (imported: Int, skipped: Int) {
        let entriesData = snapshot.removeValue(forKey: GlobalSystemPromptStore.entriesStorageKey) as? Data
        let selectedRawID = snapshot.removeValue(forKey: GlobalSystemPromptStore.selectedEntryIDStorageKey) as? String
        let activePrompt = snapshot.removeValue(forKey: legacyGlobalSystemPromptKey) as? String
        let touchedKeyCount = [entriesData as Any?, selectedRawID as Any?, activePrompt as Any?]
            .filter { $0 != nil }
            .count

        if let entriesData {
            let incomingEntries = (try? JSONDecoder().decode([GlobalSystemPromptEntry].self, from: entriesData)) ?? []
            let before = GlobalSystemPromptStore.load(userDefaults: userDefaults)
            let after = GlobalSystemPromptStore.save(
                entries: incomingEntries,
                selectedEntryID: selectedRawID.flatMap(UUID.init(uuidString:)),
                userDefaults: userDefaults
            )
            let keyCount = max(1, touchedKeyCount)
            return before == after ? (0, keyCount) : (keyCount, 0)
        }

        guard let legacyPrompt = activePrompt ?? legacyGlobalSystemPrompt else {
            return (0, 0)
        }

        let before = GlobalSystemPromptStore.load(userDefaults: userDefaults)
        if before.activeSystemPrompt == legacyPrompt {
            return (0, max(1, touchedKeyCount))
        }

        var entries = before.entries
        if let selectedID = before.selectedEntryID,
           let index = entries.firstIndex(where: { $0.id == selectedID }) {
            entries[index].content = legacyPrompt
            entries[index].updatedAt = Date()
        } else {
            let entry = GlobalSystemPromptEntry(
                title: legacyPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "历史提示词" : "同步提示词",
                content: legacyPrompt,
                updatedAt: Date()
            )
            entries.insert(entry, at: 0)
        }

        _ = GlobalSystemPromptStore.save(
            entries: entries,
            selectedEntryID: entries.first?.id,
            userDefaults: userDefaults
        )
        return (max(1, touchedKeyCount), 0)
    }

    static func isPropertyListEncodableValue(_ value: Any) -> Bool {
        PropertyListSerialization.propertyList(["value": value], isValidFor: .binary)
    }

    static func isCandidateAppStorageKey(_ key: String) -> Bool {
        // 排除系统与框架注入键，避免污染对端环境。
        if key.hasPrefix("Apple") || key.hasPrefix("NS") || key.hasPrefix("com.apple.") {
            return false
        }
        if appStorageExcludedExactKeys.contains(key) {
            return false
        }
        if appStorageExcludedPrefixes.contains(where: { key.hasPrefix($0) }) {
            return false
        }
        return true
    }

    static func appStorageValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (nil, _), (_, nil):
            return false
        default:
            break
        }

        if let lhsObject = lhs as? NSObject, let rhsObject = rhs as? NSObject {
            return lhsObject.isEqual(rhsObject)
        }

        return String(describing: lhs) == String(describing: rhs)
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
            
            let success = await memoryManager.restoreMemory(
                id: memory.id,
                content: memory.content,
                createdAt: memory.createdAt
            )
            
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
    
    static func normalizeContent(_ content: String) -> String {
        content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }
    
    // MARK: - MCP Servers
    
    static func mergeMCPServers(
        _ incoming: [MCPServerConfiguration]
    ) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }
        
        var local = MCPServerStore.loadServers()
        var imported = 0
        var skipped = 0
        
        // 预先计算本地 MCP Server 的内容哈希
        var localContentHashes = Set(local.map { computeMCPServerContentHash($0) })
        
        for var server in incoming {
            // 优先比对内容哈希，完全相同则跳过
            let incomingHash = computeMCPServerContentHash(server)
            if localContentHashes.contains(incomingHash) {
                skipped += 1
                continue
            }
            
            // 检查 UUID 是否冲突
            if local.firstIndex(where: { $0.id == server.id }) != nil {
                // ID 冲突但内容不同，生成新 UUID（不添加后缀）
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
    
    static func mergeAudioFiles(
        _ incoming: [SyncedAudio]
    ) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }
        
        var imported = 0
        var skipped = 0
        
        // 获取现有音频文件的校验和用于快速去重
        let existingFileNames = Set(Persistence.getAllAudioFileNames())
        var existingChecksums = Set<String>()
        for fileName in existingFileNames {
            if let data = Persistence.loadAudio(fileName: fileName) {
                existingChecksums.insert(data.sha256Hex)
            }
        }
        
        for audio in incoming {
            // 检查是否已存在相同校验和的文件
            if existingChecksums.contains(audio.checksum) {
                skipped += 1
                continue
            }
            
            // 文件名冲突时生成新文件名
            var targetFileName = audio.filename
            if existingFileNames.contains(audio.filename) {
                let ext = (audio.filename as NSString).pathExtension
                let name = (audio.filename as NSString).deletingPathExtension
                targetFileName = "\(name)_\(UUID().uuidString.prefix(8)).\(ext)"
            }
            
            // 保存音频文件
            if Persistence.saveAudio(audio.data, fileName: targetFileName) != nil {
                imported += 1
                existingChecksums.insert(audio.checksum)
            } else {
                skipped += 1
            }
        }
        
        return (imported, skipped)
    }

    // MARK: - Image Files

    static func mergeImageFiles(
        _ incoming: [SyncedImage]
    ) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }

        var imported = 0
        var skipped = 0

        // 获取现有图片文件的校验和用于快速去重
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

    // MARK: - Font Files

    static func mergeFontFiles(
        _ incoming: [SyncedFontFile]
    ) -> (imported: Int, skipped: Int, idMapping: [UUID: UUID]) {
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

    static func mergeSkills(
        _ incoming: [SyncedSkillBundle]
    ) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }

        var imported = 0
        var skipped = 0

        for bundle in incoming {
            let skillName = bundle.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard SkillPaths.isValidSkillName(skillName), !bundle.files.isEmpty else {
                skipped += 1
                continue
            }

            var incomingFiles: [String: String] = [:]
            var hasDuplicatePath = false
            for file in bundle.files {
                let relativePath = file.relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !relativePath.isEmpty else {
                    hasDuplicatePath = true
                    break
                }
                if incomingFiles.updateValue(file.content, forKey: relativePath) != nil {
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

            let localFiles = SkillStore.readAllSkillFiles(skillName: skillName)
            if let localFiles {
                let localBundle = SyncedSkillBundle(
                    name: skillName,
                    files: localFiles
                        .map { SyncedSkillFile(relativePath: $0.key, content: $0.value) }
                )
                if localBundle.checksum == bundle.checksum {
                    skipped += 1
                    continue
                }
            }

            if SkillStore.saveSkillFilesAtomically(skillName: skillName, files: incomingFiles) {
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

    static func mergeShortcutTools(
        _ incoming: [ShortcutToolDefinition]
    ) -> (imported: Int, skipped: Int) {
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

    static func mergeWorldbooks(
        _ incoming: [Worldbook]
    ) -> (imported: Int, skipped: Int, idMapping: [UUID: UUID]) {
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

    enum DeepMergeResult<Value> {
        case unchanged(Value)
        case merged(Value)
        case conflict
    }

    struct ProviderCompactionResult {
        var providers: [Provider]
        var updatedProviders: [Provider]
        var removedProviders: [Provider]

        var changed: Bool {
            !updatedProviders.isEmpty || !removedProviders.isEmpty
        }
    }

    static func compactProvidersByIdentity(_ providers: [Provider]) -> ProviderCompactionResult {
        guard !providers.isEmpty else {
            return ProviderCompactionResult(
                providers: [],
                updatedProviders: [],
                removedProviders: []
            )
        }

        var compacted: [Provider] = []
        var indexByIdentity: [String: Int] = [:]
        var updatedProvidersByID: [UUID: Provider] = [:]
        var removedProviders: [Provider] = []

        for provider in providers {
            let identity = providerMergeIdentity(provider)
            if let existingIndex = indexByIdentity[identity] {
                let existing = compacted[existingIndex]
                let result = mergeProviderConservatively(existing, with: provider)
                compacted[existingIndex] = result.provider
                if result.changed {
                    updatedProvidersByID[result.provider.id] = result.provider
                }
                removedProviders.append(provider)
                continue
            }

            indexByIdentity[identity] = compacted.count
            compacted.append(provider)
        }

        return ProviderCompactionResult(
            providers: compacted,
            updatedProviders: Array(updatedProvidersByID.values),
            removedProviders: removedProviders
        )
    }

    static func mergeProviderConservatively(
        _ local: Provider,
        with incoming: Provider,
        preferIncomingModelCapabilityShape: Bool = false
    ) -> (provider: Provider, changed: Bool) {
        var merged = local
        var changed = false

        let canonicalFormat = canonicalProviderAPIFormat(local.apiFormat)
        if normalizeAPIFormatToken(local.apiFormat) != canonicalFormat {
            merged.apiFormat = canonicalFormat
            changed = true
        }

        let mergedAPIKeys = mergeProviderAPIKeys(merged.apiKeys, incoming.apiKeys)
        if mergedAPIKeys != merged.apiKeys {
            merged.apiKeys = mergedAPIKeys
            changed = true
        }

        let mergedHeaders = mergeStringDictionaryConservatively(merged.headerOverrides, incoming.headerOverrides)
        if mergedHeaders != merged.headerOverrides {
            merged.headerOverrides = mergedHeaders
            changed = true
        }

        let mergedProxyConfiguration = mergeProviderProxyConfigurationConservatively(
            merged.proxyConfiguration,
            incoming.proxyConfiguration
        )
        if mergedProxyConfiguration != merged.proxyConfiguration {
            merged.proxyConfiguration = mergedProxyConfiguration
            changed = true
        }

        let mergedModelsResult = mergeProviderModelsConservatively(
            merged.models,
            incoming.models,
            preferIncomingCapabilityShape: preferIncomingModelCapabilityShape
        )
        if mergedModelsResult.changed {
            merged.models = mergedModelsResult.models
            changed = true
        }

        return (merged, changed)
    }

    static func mergeProviderModelsConservatively(
        _ localModels: [Model],
        _ incomingModels: [Model],
        preferIncomingCapabilityShape: Bool = false
    ) -> (models: [Model], changed: Bool) {
        var merged = localModels
        var changed = false
        var modelIDs = Set(merged.map(\.id))

        for incomingModel in incomingModels {
            if let existingIndex = merged.firstIndex(where: {
                normalizedModelIdentity($0) == normalizedModelIdentity(incomingModel)
            }) {
                switch mergeModelDeep(merged[existingIndex], with: incomingModel) {
                case .unchanged(let model):
                    merged[existingIndex] = model
                case .merged(let model):
                    merged[existingIndex] = model
                    changed = true
                case .conflict:
                    let conservative = mergeModelConservatively(
                        merged[existingIndex],
                        with: incomingModel,
                        preferIncomingCapabilityShape: preferIncomingCapabilityShape
                    )
                    if conservative.changed {
                        merged[existingIndex] = conservative.model
                        changed = true
                    }
                }
                continue
            }

            var appended = incomingModel
            if modelIDs.contains(appended.id) {
                appended.id = UUID()
            }
            merged.append(appended)
            modelIDs.insert(appended.id)
            changed = true
        }

        return (merged, changed)
    }

    static func mergeModelConservatively(
        _ local: Model,
        with incoming: Model,
        preferIncomingCapabilityShape: Bool = false
    ) -> (model: Model, changed: Bool) {
        var merged = local
        var changed = false

        if merged.displayName == merged.modelName,
           incoming.displayName != incoming.modelName,
           incoming.displayName != merged.displayName {
            merged.displayName = incoming.displayName
            changed = true
        }

        let mergedIsActivated = merged.isActivated || incoming.isActivated
        if mergedIsActivated != merged.isActivated {
            merged.isActivated = mergedIsActivated
            changed = true
        }

        let mergedKind = preferIncomingCapabilityShape ? incoming.kind : mergeModelKind(merged.kind, incoming.kind)
        if mergedKind != merged.kind {
            merged.kind = mergedKind
            changed = true
        }

        let mergedInputModalities = preferIncomingCapabilityShape
            ? incoming.inputModalities
            : mergeModelModalities(merged.inputModalities, incoming.inputModalities)
        if mergedInputModalities != merged.inputModalities {
            merged.inputModalities = mergedInputModalities
            changed = true
        }

        let mergedOutputModalities = preferIncomingCapabilityShape
            ? incoming.outputModalities
            : mergeModelModalities(merged.outputModalities, incoming.outputModalities)
        if mergedOutputModalities != merged.outputModalities {
            merged.outputModalities = mergedOutputModalities
            changed = true
        }

        let mergedCapabilities = preferIncomingCapabilityShape
            ? incoming.capabilities
            : mergeCapabilities(merged.capabilities, incoming.capabilities)
        if mergedCapabilities != merged.capabilities {
            merged.capabilities = mergedCapabilities
            changed = true
        }

        let mergedOverrideParameters = mergeJSONDictionaryConservatively(
            merged.overrideParameters,
            incoming.overrideParameters
        )
        if mergedOverrideParameters != merged.overrideParameters {
            merged.overrideParameters = mergedOverrideParameters
            changed = true
        }

        if let mergedRequestBodyMode = mergeRequestBodyOverrideMode(local: merged, incoming: incoming),
           mergedRequestBodyMode != merged.requestBodyOverrideMode {
            merged.requestBodyOverrideMode = mergedRequestBodyMode
            changed = true
        }

        let normalizedLocalRaw = normalizeOptionalJSONString(merged.rawRequestBodyJSON)
        let normalizedIncomingRaw = normalizeOptionalJSONString(incoming.rawRequestBodyJSON)
        if normalizedLocalRaw == nil, let normalizedIncomingRaw {
            merged.rawRequestBodyJSON = normalizedIncomingRaw
            changed = true
        }

        return (merged, changed)
    }

    static func mergeStringDictionaryConservatively(
        _ local: [String: String],
        _ incoming: [String: String]
    ) -> [String: String] {
        var merged = local
        for (key, incomingValue) in incoming {
            guard merged[key] == nil else { continue }
            merged[key] = incomingValue
        }
        return merged
    }

    static func mergeProviderProxyConfigurationConservatively(
        _ local: NetworkProxyConfiguration?,
        _ incoming: NetworkProxyConfiguration?
    ) -> NetworkProxyConfiguration? {
        switch (local, incoming) {
        case (nil, nil):
            return nil
        case (let local?, nil):
            return local
        case (nil, let incoming?):
            return incoming
        case (let local?, let incoming?):
            if local == incoming {
                return local
            }
            if !local.isEnabled && incoming.isEnabled {
                return incoming
            }
            return local
        }
    }

}
