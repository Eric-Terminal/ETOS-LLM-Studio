// ============================================================================
// SyncEngine.swift
// ============================================================================
// 负责根据选项收集同步数据并执行合并逻辑
// - 构建 SyncPackage 供跨设备传输
// - 解析并合并来自对端的数据，处理冲突与去重
// ============================================================================

import Foundation
import Combine

public enum SyncEngine {
    
    // MARK: - 打包导出
    
    /// 根据同步选项构建完整同步包
    public static func buildPackage(
        options: SyncOptions,
        chatService: ChatService = .shared
    ) -> SyncPackage {
        var providers: [Provider] = []
        var sessions: [SyncedSession] = []
        var backgrounds: [SyncedBackground] = []
        var memories: [MemoryItem] = []
        var mcpServers: [MCPServerConfiguration] = []
        var audioFiles: [SyncedAudio] = []
        var imageFiles: [SyncedImage] = []
        var referencedAudioFileNames = Set<String>()
        var referencedImageFileNames = Set<String>()
        
        if options.contains(.providers) {
            providers = ConfigLoader.loadProviders()
        }
        
        if options.contains(.sessions) {
            let allSessions = chatService.chatSessionsSubject.value.filter { !$0.isTemporary }
            for session in allSessions {
                let messages = Persistence.loadMessages(for: session.id)
                sessions.append(SyncedSession(session: session, messages: messages))
                for message in messages {
                    if let audioFileName = message.audioFileName {
                        referencedAudioFileNames.insert(audioFileName)
                    }
                    if let imageFileNames = message.imageFileNames {
                        referencedImageFileNames.formUnion(imageFileNames)
                    }
                }
            }
        }
        
        if options.contains(.backgrounds) {
            ConfigLoader.setupBackgroundsDirectory()
            let directory = ConfigLoader.getBackgroundsDirectory()
            let fileManager = FileManager.default
            if let fileURLs = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                backgrounds = fileURLs.compactMap { url in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return SyncedBackground(filename: url.lastPathComponent, data: data)
                }
            }
        }
        
        if options.contains(.memories) {
            let rawStore = MemoryRawStore()
            memories = rawStore.loadMemories()
        }
        
        if options.contains(.mcpServers) {
            mcpServers = MCPServerStore.loadServers()
        }
        
        // 音频文件同步：会话引用的音频 + 可选全量音频文件
        var audioFileNamesToInclude = referencedAudioFileNames
        if options.contains(.audioFiles) {
            let directory = Persistence.getAudioDirectory()
            let fileManager = FileManager.default
            if let fileURLs = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for url in fileURLs {
                    audioFileNamesToInclude.insert(url.lastPathComponent)
                }
            }
        }
        if !audioFileNamesToInclude.isEmpty {
            audioFiles = audioFileNamesToInclude.compactMap { fileName in
                guard let data = Persistence.loadAudio(fileName: fileName) else { return nil }
                return SyncedAudio(filename: fileName, data: data)
            }
        }

        // 图片文件同步：会话引用的图片 + 可选全量图片文件
        var imageFileNamesToInclude = referencedImageFileNames
        if options.contains(.imageFiles) {
            let directory = Persistence.getImageDirectory()
            let fileManager = FileManager.default
            if let fileURLs = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for url in fileURLs {
                    imageFileNamesToInclude.insert(url.lastPathComponent)
                }
            }
        }
        if !imageFileNamesToInclude.isEmpty {
            imageFiles = imageFileNamesToInclude.compactMap { fileName in
                guard let data = Persistence.loadImage(fileName: fileName) else { return nil }
                return SyncedImage(filename: fileName, data: data)
            }
        }
        
        return SyncPackage(
            options: options,
            providers: providers,
            sessions: sessions,
            backgrounds: backgrounds,
            memories: memories,
            mcpServers: mcpServers,
            audioFiles: audioFiles,
            imageFiles: imageFiles
        )
    }
    
    // MARK: - 合并导入
    
    /// 将对端发来的同步包合并到本地数据
    @discardableResult
    public static func apply(
        package: SyncPackage,
        chatService: ChatService = .shared,
        memoryManager: MemoryManager? = nil
    ) async -> SyncMergeSummary {
        var summary = SyncMergeSummary.empty
        
        if package.options.contains(.providers) {
            let result = mergeProviders(package.providers, chatService: chatService)
            summary.importedProviders = result.imported
            summary.skippedProviders = result.skipped
        }
        
        if package.options.contains(.sessions) {
            let result = mergeSessions(package.sessions, chatService: chatService)
            summary.importedSessions = result.imported
            summary.skippedSessions = result.skipped
        }
        
        if package.options.contains(.backgrounds) {
            let result = mergeBackgrounds(package.backgrounds)
            summary.importedBackgrounds = result.imported
            summary.skippedBackgrounds = result.skipped
            if result.imported > 0 {
                NotificationCenter.default.post(name: .syncBackgroundsUpdated, object: nil)
            }
        }
        
        if package.options.contains(.memories) {
            let manager = memoryManager ?? .shared
            let result = await mergeMemories(package.memories, memoryManager: manager)
            summary.importedMemories = result.imported
            summary.skippedMemories = result.skipped
        }
        
        if package.options.contains(.mcpServers) {
            let result = mergeMCPServers(package.mcpServers)
            summary.importedMCPServers = result.imported
            summary.skippedMCPServers = result.skipped
        }
        
        // 音频文件同步
        if package.options.contains(.audioFiles) {
            let result = mergeAudioFiles(package.audioFiles)
            summary.importedAudioFiles = result.imported
            summary.skippedAudioFiles = result.skipped
        }

        if package.options.contains(.imageFiles) {
            let result = mergeImageFiles(package.imageFiles)
            summary.importedImageFiles = result.imported
            summary.skippedImageFiles = result.skipped
        }
        
        return summary
    }
    
    // MARK: - Providers
    
    private static func mergeProviders(
        _ incoming: [Provider],
        chatService: ChatService
    ) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }
        
        var local = ConfigLoader.loadProviders()
        var imported = 0
        var skipped = 0
        
        // 预先计算本地 Provider 的内容哈希
        var localContentHashes = Set(local.map { computeProviderContentHash($0) })
        
        for var provider in incoming {
            // 优先比对内容哈希，完全相同则跳过
            let incomingHash = computeProviderContentHash(provider)
            if localContentHashes.contains(incomingHash) {
                skipped += 1
                continue
            }
            
            // 检查 UUID 是否冲突
            if local.firstIndex(where: { $0.id == provider.id }) != nil {
                // ID 冲突但内容不同，生成新 UUID（不添加后缀）
                provider.id = UUID()
                provider.models = provider.models.map {
                    var clone = $0
                    clone.id = UUID()
                    return clone
                }
            }
            
            ConfigLoader.saveProvider(provider)
            local.append(provider)
            localContentHashes.insert(incomingHash)
            imported += 1
        }
        
        if imported > 0 {
            chatService.reloadProviders()
        }
        
        return (imported, skipped)
    }
    
    // MARK: - Sessions
    
    private static func mergeSessions(
        _ incoming: [SyncedSession],
        chatService: ChatService
    ) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }
        
        var sessions = chatService.chatSessionsSubject.value
        var imported = 0
        var skipped = 0
        
        // 预先计算所有本地会话的内容哈希，用于快速去重
        var localContentHashes: [String: UUID] = [:]
        for localSession in sessions {
            let localMessages = Persistence.loadMessages(for: localSession.id)
            let hash = computeSessionContentHash(session: localSession, messages: localMessages)
            localContentHashes[hash] = localSession.id
        }
        
        for payload in incoming {
            var session = payload.session
            session.isTemporary = false
            
            // 优先使用内容哈希比较：如果内容完全相同，直接跳过
            let incomingHash = computeSessionContentHash(session: session, messages: payload.messages)
            if localContentHashes[incomingHash] != nil {
                skipped += 1
                continue
            }
            
            // 检查 UUID 是否冲突
            if sessions.firstIndex(where: { $0.id == session.id }) != nil {
                // UUID 冲突但内容不同（已经通过哈希检查），生成新 UUID
                session = makeNewSession(from: session)
            } else if sessions.first(where: { $0.isEquivalentIgnoringSyncSuffix(to: session) }) != nil {
                // 名称等价但内容不同，也生成新 UUID（不再叠加后缀）
                session = makeNewSession(from: session)
            }
            
            // 写入消息文件
            Persistence.saveMessages(payload.messages, for: session.id)
            sessions.insert(session, at: 0)
            localContentHashes[incomingHash] = session.id
            imported += 1
        }
        
        if imported > 0 {
            Persistence.saveChatSessions(sessions)
            chatService.chatSessionsSubject.send(sessions)
            if chatService.currentSessionSubject.value == nil {
                chatService.currentSessionSubject.send(sessions.first)
            }
        }
        
        return (imported, skipped)
    }
    
    // MARK: - Backgrounds
    
    private static func mergeBackgrounds(_ incoming: [SyncedBackground]) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }
        
        ConfigLoader.setupBackgroundsDirectory()
        let directory = ConfigLoader.getBackgroundsDirectory()
        let fileManager = FileManager.default
        var checksumMap: [String: URL] = [:]
        
        if let localFiles = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in localFiles {
                if let data = try? Data(contentsOf: url) {
                    checksumMap[data.sha256Hex] = url
                }
            }
        }
        
        var imported = 0
        var skipped = 0
        
        for background in incoming {
            if checksumMap[background.checksum] != nil {
                skipped += 1
                continue
            }
            
            var targetName = background.filename
            var targetURL = directory.appendingPathComponent(targetName)
            
            // 若存在同名文件且内容不同，则生成新的文件名
            while fileManager.fileExists(atPath: targetURL.path) {
                let name = targetName.replacingOccurrences(of: ".\(targetURL.pathExtension)", with: "")
                targetName = "\(name)-sync-\(background.checksum.prefix(6)).\(targetURL.pathExtension)"
                targetURL = directory.appendingPathComponent(targetName)
            }
            
            do {
                try background.data.write(to: targetURL, options: [.atomic])
                checksumMap[background.checksum] = targetURL
                imported += 1
            } catch {
                // 写入失败视为跳过，避免中断同步流程
                skipped += 1
            }
        }
        
        return (imported, skipped)
    }
    
    // MARK: - Memories
    
    private static func mergeMemories(
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
    
    private static func normalizeContent(_ content: String) -> String {
        content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }
    
    // MARK: - MCP Servers
    
    private static func mergeMCPServers(
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
    
    private static func mergeAudioFiles(
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

    private static func mergeImageFiles(
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

    // MARK: - Helpers

    /// 创建带有新 UUID 的会话副本（保留原名称，不添加后缀）
    private static func makeNewSession(from session: ChatSession) -> ChatSession {
        return ChatSession(
            id: UUID(),
            name: session.name,
            topicPrompt: session.topicPrompt,
            enhancedPrompt: session.enhancedPrompt,
            isTemporary: false
        )
    }
    
    /// 计算会话内容的哈希值，用于快速比较
    /// 包含：会话基础名称（去除同步后缀）、系统提示、消息内容
    private static func computeSessionContentHash(session: ChatSession, messages: [ChatMessage]) -> String {
        var hasher = Hasher()
        // 使用去除同步后缀的基础名称
        hasher.combine(session.baseNameWithoutSyncSuffix)
        hasher.combine(session.topicPrompt ?? "")
        hasher.combine(session.enhancedPrompt ?? "")
        // 对消息进行哈希
        for message in messages {
            hasher.combine(message.role.rawValue)
            hasher.combine(message.content)
            // 附件数量和类型也参与比较
            hasher.combine(message.imageFileNames?.count ?? 0)
            hasher.combine(message.audioFileName ?? "")
        }
        return String(hasher.finalize())
    }
    
    /// 计算 Provider 内容的哈希值，用于快速比较
    /// 包含：基础名称（去除同步后缀）、URL、API 格式、模型配置
    private static func computeProviderContentHash(_ provider: Provider) -> String {
        var hasher = Hasher()
        hasher.combine(provider.baseNameWithoutSyncSuffix)
        hasher.combine(provider.baseURL)
        hasher.combine(provider.apiFormat)
        // API Keys 不参与哈希（可能是敏感信息且易变）
        for (key, value) in provider.headerOverrides.sorted(by: { $0.key < $1.key }) {
            hasher.combine(key)
            hasher.combine(value)
        }
        for model in provider.models {
            hasher.combine(model.modelName)
            hasher.combine(model.displayName)
            hasher.combine(model.isActivated)
        }
        return String(hasher.finalize())
    }
    
    /// 计算 MCP Server 内容的哈希值，用于快速比较
    private static func computeMCPServerContentHash(_ server: MCPServerConfiguration) -> String {
        var hasher = Hasher()
        hasher.combine(server.baseNameWithoutSyncSuffix)
        hasher.combine(server.notes ?? "")
        hasher.combine(server.isSelectedForChat)
        // Transport 配置
        switch server.transport {
        case .http(let endpoint, let apiKey, let headers):
            hasher.combine("http")
            hasher.combine(endpoint.absoluteString)
            hasher.combine(apiKey ?? "")
            for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
                hasher.combine(key)
                hasher.combine(value)
            }
        case .httpSSE(let messageEndpoint, let sseEndpoint, let apiKey, let headers):
            hasher.combine("httpSSE")
            hasher.combine(messageEndpoint.absoluteString)
            hasher.combine(sseEndpoint.absoluteString)
            hasher.combine(apiKey ?? "")
            for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
                hasher.combine(key)
                hasher.combine(value)
            }
        case .oauth(let endpoint, let tokenEndpoint, let clientID, _, let scope):
            hasher.combine("oauth")
            hasher.combine(endpoint.absoluteString)
            hasher.combine(tokenEndpoint.absoluteString)
            hasher.combine(clientID)
            hasher.combine(scope ?? "")
        }
        return String(hasher.finalize())
    }
}
