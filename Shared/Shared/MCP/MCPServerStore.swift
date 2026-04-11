// ============================================================================
// MCPServerStore.swift
// ============================================================================
// 管理 MCP Server 配置的增删改查（优先关系化 SQLite，失败时回退 JSON 文件）。
// ============================================================================

import Foundation
import GRDB
import os.log

private let mcpStoreLogger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "MCPServerStore")

public struct MCPServerMetadataCache: Codable, Hashable {
    public var cachedAt: Date
    public var info: MCPServerInfo?
    public var tools: [MCPToolDescription]
    public var resources: [MCPResourceDescription]
    public var resourceTemplates: [MCPResourceTemplate]
    public var prompts: [MCPPromptDescription]
    public var roots: [MCPRoot]

    public init(
        cachedAt: Date = Date(),
        info: MCPServerInfo?,
        tools: [MCPToolDescription],
        resources: [MCPResourceDescription],
        resourceTemplates: [MCPResourceTemplate],
        prompts: [MCPPromptDescription],
        roots: [MCPRoot]
    ) {
        self.cachedAt = cachedAt
        self.info = info
        self.tools = tools
        self.resources = resources
        self.resourceTemplates = resourceTemplates
        self.prompts = prompts
        self.roots = roots
    }

    private enum CodingKeys: String, CodingKey {
        case cachedAt
        case info
        case tools
        case resources
        case resourceTemplates
        case prompts
        case roots
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cachedAt = try container.decodeIfPresent(Date.self, forKey: .cachedAt) ?? Date()
        info = try container.decodeIfPresent(MCPServerInfo.self, forKey: .info)
        tools = try container.decodeIfPresent([MCPToolDescription].self, forKey: .tools) ?? []
        resources = try container.decodeIfPresent([MCPResourceDescription].self, forKey: .resources) ?? []
        resourceTemplates = try container.decodeIfPresent([MCPResourceTemplate].self, forKey: .resourceTemplates) ?? []
        prompts = try container.decodeIfPresent([MCPPromptDescription].self, forKey: .prompts) ?? []
        roots = try container.decodeIfPresent([MCPRoot].self, forKey: .roots) ?? []
    }
}

public struct MCPServerStore {
    private static let lock = NSLock()
    private static let legacyBlobKey = "mcp_servers_records_v1"
    private static var didBootstrapRelationalStore = false

    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static var serversDirectory: URL {
        documentsDirectory.appendingPathComponent("MCPServers")
    }

    @discardableResult
    public static func setupDirectoryIfNeeded() -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: serversDirectory.path) {
            do {
                try fm.createDirectory(at: serversDirectory, withIntermediateDirectories: true)
                mcpStoreLogger.info("MCPServers 目录已创建: \(serversDirectory.path, privacy: .public)")
            } catch {
                mcpStoreLogger.error("创建 MCPServers 目录失败: \(error.localizedDescription, privacy: .public)")
            }
        }
        return serversDirectory
    }

    public static func loadServers() -> [MCPServerConfiguration] {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            if let servers = loadServersFromRelationalStore() {
                return servers
            }
            return loadLegacyRecords(usingBlobCache: true).map(\.server)
        }
    }

    public static func save(_ server: MCPServerConfiguration) {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            if saveServerToRelationalStore(server) {
                cleanupLegacyArtifactsAfterRelationalSave()
                return
            }

            var records = loadLegacyRecords(usingBlobCache: true)
            if let index = records.firstIndex(where: { $0.server.id == server.id }) {
                let existingRecord = records[index]
                let shouldPreserveMetadata = existingRecord.server.transport == server.transport
                let metadata = shouldPreserveMetadata ? existingRecord.metadata : nil
                records[index] = MCPServerStoredRecord(server: server, metadata: metadata)
            } else {
                records.append(MCPServerStoredRecord(server: server, metadata: nil))
            }
            saveLegacyRecords(records)
        }
    }

    public static func delete(_ server: MCPServerConfiguration) {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            if deleteServerFromRelationalStore(serverID: server.id) {
                mcpStoreLogger.info("已删除 MCP Server: \(server.displayName, privacy: .public)")
                cleanupLegacyArtifactsAfterRelationalSave()
                return
            }

            var records = loadLegacyRecords(usingBlobCache: true)
            records.removeAll { $0.server.id == server.id }
            saveLegacyRecords(records)
            mcpStoreLogger.info("已删除 MCP Server: \(server.displayName, privacy: .public)")
        }
    }

    public static func loadMetadata(for serverID: UUID, includeTools: Bool = true) -> MCPServerMetadataCache? {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            if let metadata = loadMetadataFromRelationalStore(serverID: serverID, includeTools: includeTools) {
                return metadata
            }
            var metadata = loadLegacyRecords(usingBlobCache: true)
                .first(where: { $0.server.id == serverID })?
                .metadata
            if includeTools == false {
                metadata?.tools = []
            }
            return metadata
        }
    }

    public static func saveMetadata(_ metadata: MCPServerMetadataCache?, for serverID: UUID) {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            if saveMetadataToRelationalStore(metadata, for: serverID) {
                cleanupLegacyArtifactsAfterRelationalSave()
                return
            }

            var records = loadLegacyRecords(usingBlobCache: true)
            guard let index = records.firstIndex(where: { $0.server.id == serverID }) else { return }
            records[index].metadata = metadata
            records[index].schemaVersion = 3
            saveLegacyRecords(records)
        }
    }

    /// 仅按需加载某个服务的工具列表，避免解码整份 Server 元数据。
    public static func loadTools(for serverID: UUID) -> [MCPToolDescription] {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            if let tools = loadToolsFromRelationalStore(serverID: serverID) {
                return tools
            }
            return loadLegacyRecords(usingBlobCache: true)
                .first(where: { $0.server.id == serverID })?
                .metadata?
                .tools ?? []
        }
    }

    /// 返回用于快速判断配置是否变化的签名。
    /// 仅抓取 mcp_servers 轻量列，避免深层 JSON 反序列化带来的 CPU 抖动。
    public static func configurationSnapshotSignature() -> String {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            if let relationalSignature = configurationSignatureFromRelationalStore() {
                return relationalSignature
            }
            return configurationSignatureFromLegacyRecords()
        }
    }

    /// 基于 GRDB ValueObservation 监听配置变化（仅在真实写入时触发）。
    public static func observeConfigurationSignature(
        onError: @escaping @Sendable (Error) -> Void,
        onChange: @escaping @Sendable (String) -> Void
    ) -> AnyDatabaseCancellable? {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
        }

        let observation = ValueObservation
            .tracking { db in
                try configurationSignatureFromRelationalDatabase(db)
            }
            .removeDuplicates()

        return Persistence.observeConfigDatabase(
            observation,
            onError: onError,
            onChange: onChange
        )
    }

    // MARK: - 关系化存储

    private static func bootstrapRelationalStoreIfNeeded() {
        guard !didBootstrapRelationalStore else { return }
        guard Persistence.withConfigDatabaseRead({ _ in true }) == true else { return }

        migrateLegacyRecordsToRelationalStoreIfNeeded()
        didBootstrapRelationalStore = true
    }

    private static func migrateLegacyRecordsToRelationalStoreIfNeeded() {
        guard let existingServerCount = Persistence.withConfigDatabaseRead({ db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mcp_servers") ?? 0
        }) else {
            return
        }

        guard existingServerCount == 0 else { return }

        let legacyRecords = loadLegacyRecords(usingBlobCache: false)
        guard !legacyRecords.isEmpty else { return }

        let migrateSucceeded = Persistence.withConfigDatabaseWrite { db in
            let now = Date().timeIntervalSince1970
            for legacyRecord in legacyRecords {
                var serverRecord = try MCPServerRecord(
                    server: legacyRecord.server,
                    status: .idle,
                    updatedAt: now
                )

                if let metadata = legacyRecord.metadata {
                    try serverRecord.applyMetadata(metadata)
                }

                try serverRecord.save(db)

                try MCPToolRecord
                    .filter(MCPToolRecord.Columns.serverID == legacyRecord.server.id.uuidString)
                    .deleteAll(db)

                if let metadata = legacyRecord.metadata {
                    let toolsTimestamp = metadata.cachedAt.timeIntervalSince1970
                    for (index, tool) in metadata.tools.enumerated() {
                        var toolRecord = try MCPToolRecord(
                            serverID: legacyRecord.server.id.uuidString,
                            tool: tool,
                            sortIndex: index,
                            updatedAt: toolsTimestamp
                        )
                        try toolRecord.save(db)
                    }
                }
            }
            return true
        } ?? false

        guard migrateSucceeded else {
            mcpStoreLogger.error("MCP 关系化迁移失败：未能写入 mcp_servers/mcp_tools。")
            return
        }

        _ = Persistence.removeAuxiliaryBlob(forKey: legacyBlobKey)
        cleanupLegacyFileArtifacts()
        mcpStoreLogger.info("MCP 配置已自动迁移到关系化表：servers=\(legacyRecords.count)")
    }

    private static func loadServersFromRelationalStore() -> [MCPServerConfiguration]? {
        Persistence.withConfigDatabaseRead { db in
            let records = try MCPServerRecord.fetchAll(db)
            let servers = records.compactMap { record -> MCPServerConfiguration? in
                guard let server = record.decodeConfiguration() else {
                    mcpStoreLogger.error("读取 MCP 服务器失败：配置数据损坏 id=\(record.id, privacy: .public)")
                    return nil
                }
                return server
            }

            return servers.sorted {
                let lhsName = $0.displayName.lowercased()
                let rhsName = $1.displayName.lowercased()
                if lhsName == rhsName {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return lhsName < rhsName
            }
        }
    }

    private static func saveServerToRelationalStore(_ server: MCPServerConfiguration) -> Bool {
        let serverID = server.id.uuidString
        let didSave = Persistence.withConfigDatabaseWrite { db in
            let existing = try MCPServerRecord.fetchOne(db, key: serverID)
            var record = existing ?? try MCPServerRecord(server: server, status: .idle, updatedAt: Date().timeIntervalSince1970)

            let shouldPreserveMetadata: Bool
            if let existing,
               let previousServer = existing.decodeConfiguration() {
                shouldPreserveMetadata = previousServer.transport == server.transport
            } else {
                shouldPreserveMetadata = false
            }

            try record.applyConfiguration(server)
            if !shouldPreserveMetadata {
                record.clearMetadata(status: .idle)
                try MCPToolRecord
                    .filter(MCPToolRecord.Columns.serverID == serverID)
                    .deleteAll(db)
            }

            try record.save(db)
            return true
        } ?? false

        return didSave
    }

    private static func deleteServerFromRelationalStore(serverID: UUID) -> Bool {
        Persistence.withConfigDatabaseWrite { db in
            _ = try MCPServerRecord.deleteOne(db, key: serverID.uuidString)
            return true
        } ?? false
    }

    private static func loadMetadataFromRelationalStore(serverID: UUID, includeTools: Bool) -> MCPServerMetadataCache? {
        Persistence.withConfigDatabaseRead { db in
            guard let serverRecord = try MCPServerRecord.fetchOne(db, key: serverID.uuidString) else {
                return nil
            }

            let toolRecords: [MCPToolRecord]
            if includeTools {
                toolRecords = try MCPToolRecord
                    .filter(MCPToolRecord.Columns.serverID == serverID.uuidString)
                    .order(MCPToolRecord.Columns.sortIndex.asc)
                    .fetchAll(db)
            } else {
                toolRecords = []
            }

            return serverRecord.makeMetadata(toolRecords: toolRecords)
        } ?? nil
    }

    private static func loadToolsFromRelationalStore(serverID: UUID) -> [MCPToolDescription]? {
        Persistence.withConfigDatabaseRead { db in
            try MCPToolRecord
                .filter(MCPToolRecord.Columns.serverID == serverID.uuidString)
                .order(MCPToolRecord.Columns.sortIndex.asc)
                .fetchAll(db)
                .compactMap { $0.toToolDescription() }
        }
    }

    private static func saveMetadataToRelationalStore(_ metadata: MCPServerMetadataCache?, for serverID: UUID) -> Bool {
        Persistence.withConfigDatabaseWrite { db in
            guard var serverRecord = try MCPServerRecord.fetchOne(db, key: serverID.uuidString) else {
                return true
            }

            try MCPToolRecord
                .filter(MCPToolRecord.Columns.serverID == serverID.uuidString)
                .deleteAll(db)

            if let metadata {
                try serverRecord.applyMetadata(metadata)

                let updatedAt = metadata.cachedAt.timeIntervalSince1970
                for (index, tool) in metadata.tools.enumerated() {
                    var toolRecord = try MCPToolRecord(
                        serverID: serverID.uuidString,
                        tool: tool,
                        sortIndex: index,
                        updatedAt: updatedAt
                    )
                    try toolRecord.save(db)
                }
            } else {
                serverRecord.clearMetadata(status: .idle)
            }

            try serverRecord.save(db)
            return true
        } ?? false
    }

    private static func configurationSignatureFromRelationalStore() -> String? {
        Persistence.withConfigDatabaseRead { db in
            try configurationSignatureFromRelationalDatabase(db)
        }
    }

    private static func configurationSignatureFromRelationalDatabase(_ db: Database) throws -> String {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT
                s.id AS id,
                s.name AS name,
                s.status AS status,
                s.updated_at AS updated_at,
                COALESCE(MAX(t.updated_at), 0) AS tools_updated_at,
                COUNT(t.id) AS tools_count
            FROM mcp_servers s
            LEFT JOIN mcp_tools t ON t.server_id = s.id
            GROUP BY s.id, s.name, s.status, s.updated_at
            ORDER BY s.id ASC
            """
        )

        let signatures = rows.map { row -> String in
            let id: String = row["id"]
            let name: String = row["name"]
            let status: String = row["status"]
            let updatedAt: Double = row["updated_at"]
            let toolsUpdatedAt: Double = row["tools_updated_at"]
            let toolsCount: Int = row["tools_count"]
            return "\(id)|\(name)|\(status)|\(updatedAt)|\(toolsUpdatedAt)|\(toolsCount)"
        }
        return signatures.joined(separator: ";")
    }

    private static func cleanupLegacyArtifactsAfterRelationalSave() {
        _ = Persistence.removeAuxiliaryBlob(forKey: legacyBlobKey)
        cleanupLegacyFileArtifacts()
    }

    // MARK: - 旧版数据（JSON Blob / 文件）

    private static func loadLegacyRecords(usingBlobCache: Bool) -> [MCPServerStoredRecord] {
        if Persistence.auxiliaryBlobExists(forKey: legacyBlobKey) {
            let records = Persistence.loadAuxiliaryBlob([MCPServerStoredRecord].self, forKey: legacyBlobKey) ?? []
            return records.sorted { $0.server.displayName.lowercased() < $1.server.displayName.lowercased() }
        }

        let fileRecords = loadRecordsFromFiles()
        guard !fileRecords.isEmpty else { return [] }

        if usingBlobCache,
           Persistence.saveAuxiliaryBlob(fileRecords, forKey: legacyBlobKey) {
            cleanupLegacyFileArtifacts()
        }

        return fileRecords.sorted { $0.server.displayName.lowercased() < $1.server.displayName.lowercased() }
    }

    private static func saveLegacyRecords(_ records: [MCPServerStoredRecord]) {
        let sortedRecords = records.sorted { $0.server.displayName.lowercased() < $1.server.displayName.lowercased() }
        if Persistence.saveAuxiliaryBlob(sortedRecords, forKey: legacyBlobKey) {
            cleanupLegacyFileArtifacts()
            return
        }
        saveRecordsToFiles(sortedRecords)
    }

    private static func configurationSignatureFromLegacyRecords() -> String {
        let signatures: [String] = loadLegacyRecords(usingBlobCache: true)
            .map { record in
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let serverData = (try? encoder.encode(record.server)) ?? Data()
                let serverJSON = String(data: serverData, encoding: .utf8) ?? "{}"
                return "\(record.server.id.uuidString)|\(serverJSON)"
            }
            .sorted()
        return signatures.joined(separator: ";")
    }

    private static func loadRecordsFromFiles() -> [MCPServerStoredRecord] {
        setupDirectoryIfNeeded()
        let fm = FileManager.default
        var records: [MCPServerStoredRecord] = []
        do {
            let files = try fm.contentsOfDirectory(at: serversDirectory, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "json" {
                guard let record = loadRecord(from: file) else { continue }
                records.append(record)
            }
        } catch {
            mcpStoreLogger.error("读取 MCPServers 目录失败: \(error.localizedDescription, privacy: .public)")
        }
        return records
    }

    private static func saveRecordsToFiles(_ records: [MCPServerStoredRecord]) {
        setupDirectoryIfNeeded()
        let fm = FileManager.default

        for record in records {
            writeRecord(record, fileName: record.server.id.uuidString)
        }

        do {
            let files = try fm.contentsOfDirectory(at: serversDirectory, includingPropertiesForKeys: nil)
            let desired = Set(records.map { "\($0.server.id.uuidString).json".lowercased() })
            for file in files where file.pathExtension == "json" {
                if desired.contains(file.lastPathComponent.lowercased()) {
                    continue
                }
                try? fm.removeItem(at: file)
            }
        } catch {
            mcpStoreLogger.error("清理 MCP Server 旧配置文件失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func cleanupLegacyFileArtifacts() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: serversDirectory.path) else { return }
        do {
            let files = try fm.contentsOfDirectory(at: serversDirectory, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "json" {
                try? fm.removeItem(at: file)
            }
            let remaining = try fm.contentsOfDirectory(atPath: serversDirectory.path)
            if remaining.isEmpty {
                try? fm.removeItem(at: serversDirectory)
            }
        } catch {
            mcpStoreLogger.error("清理 MCP Server 遗留 JSON 失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadRecord(from url: URL) -> MCPServerStoredRecord? {
        do {
            let data = try Data(contentsOf: url)
            let record = try JSONDecoder().decode(MCPServerStoredRecord.self, from: data)
            return record
        } catch {
            mcpStoreLogger.error("解析 MCP Server 文件失败 \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func writeRecord(_ record: MCPServerStoredRecord, fileName: String) {
        let url = serversDirectory.appendingPathComponent("\(fileName).json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(record)
            try data.write(to: url, options: [.atomicWrite, .completeFileProtection])
            mcpStoreLogger.info("已保存 MCP Server: \(record.server.displayName, privacy: .public)")
        } catch {
            mcpStoreLogger.error("保存 MCP Server 失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    private struct MCPServerStoredRecord: Codable {
        var schemaVersion: Int
        var server: MCPServerConfiguration
        var metadata: MCPServerMetadataCache?

        init(schemaVersion: Int = 3, server: MCPServerConfiguration, metadata: MCPServerMetadataCache?) {
            self.schemaVersion = schemaVersion
            self.server = server
            self.metadata = metadata
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case server
            case metadata
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.server) {
                schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 3
                server = try container.decode(MCPServerConfiguration.self, forKey: .server)
                metadata = try container.decodeIfPresent(MCPServerMetadataCache.self, forKey: .metadata)
            } else {
                server = try MCPServerConfiguration(from: decoder)
                schemaVersion = 1
                metadata = nil
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(server, forKey: .server)
            try container.encodeIfPresent(metadata, forKey: .metadata)
        }
    }
}

// MARK: - GRDB Records

private struct MCPServerRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "mcp_servers"

    enum Status: String {
        case idle
        case ready
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case configurationData = "configuration_data"
        case metadataCachedAt = "metadata_cached_at"
        case infoData = "info_data"
        case resourcesData = "resources_data"
        case resourceTemplatesData = "resource_templates_data"
        case promptsData = "prompts_data"
        case rootsData = "roots_data"
        case updatedAt = "updated_at"
    }

    enum Columns {
        static let id = Column(CodingKeys.id.rawValue)
        static let name = Column(CodingKeys.name.rawValue)
        static let status = Column(CodingKeys.status.rawValue)
        static let updatedAt = Column(CodingKeys.updatedAt.rawValue)
    }

    static let tools = hasMany(MCPToolRecord.self, using: ForeignKey(["server_id"]))

    var id: String
    var name: String
    var status: String
    var configurationData: Data
    var metadataCachedAt: Double?
    var infoData: Data?
    var resourcesData: Data?
    var resourceTemplatesData: Data?
    var promptsData: Data?
    var rootsData: Data?
    var updatedAt: Double

    init(server: MCPServerConfiguration, status: Status, updatedAt: Double) throws {
        self.id = server.id.uuidString
        self.name = server.displayName
        self.status = status.rawValue
        self.configurationData = try MCPServerStoreCodec.encode(server)
        self.metadataCachedAt = nil
        self.infoData = nil
        self.resourcesData = nil
        self.resourceTemplatesData = nil
        self.promptsData = nil
        self.rootsData = nil
        self.updatedAt = updatedAt
    }

    mutating func applyConfiguration(_ server: MCPServerConfiguration) throws {
        id = server.id.uuidString
        name = server.displayName
        configurationData = try MCPServerStoreCodec.encode(server)
        updatedAt = Date().timeIntervalSince1970
    }

    mutating func applyMetadata(_ metadata: MCPServerMetadataCache) throws {
        status = Status.ready.rawValue
        metadataCachedAt = metadata.cachedAt.timeIntervalSince1970
        infoData = try MCPServerStoreCodec.encodeIfPresent(metadata.info)
        resourcesData = try metadata.resources.isEmpty ? nil : MCPServerStoreCodec.encode(metadata.resources)
        resourceTemplatesData = try metadata.resourceTemplates.isEmpty ? nil : MCPServerStoreCodec.encode(metadata.resourceTemplates)
        promptsData = try metadata.prompts.isEmpty ? nil : MCPServerStoreCodec.encode(metadata.prompts)
        rootsData = try metadata.roots.isEmpty ? nil : MCPServerStoreCodec.encode(metadata.roots)
    }

    mutating func clearMetadata(status: Status = .idle) {
        self.status = status.rawValue
        metadataCachedAt = nil
        infoData = nil
        resourcesData = nil
        resourceTemplatesData = nil
        promptsData = nil
        rootsData = nil
    }

    func decodeConfiguration() -> MCPServerConfiguration? {
        try? MCPServerStoreCodec.decode(MCPServerConfiguration.self, from: configurationData)
    }

    func makeMetadata(toolRecords: [MCPToolRecord]) -> MCPServerMetadataCache? {
        let tools = toolRecords.compactMap { $0.toToolDescription() }
        let info = MCPServerStoreCodec.decodeIfPresent(MCPServerInfo.self, from: infoData)
        let resources = MCPServerStoreCodec.decodeIfPresent([MCPResourceDescription].self, from: resourcesData) ?? []
        let resourceTemplates = MCPServerStoreCodec.decodeIfPresent([MCPResourceTemplate].self, from: resourceTemplatesData) ?? []
        let prompts = MCPServerStoreCodec.decodeIfPresent([MCPPromptDescription].self, from: promptsData) ?? []
        let roots = MCPServerStoreCodec.decodeIfPresent([MCPRoot].self, from: rootsData) ?? []

        if info == nil,
           tools.isEmpty,
           resources.isEmpty,
           resourceTemplates.isEmpty,
           prompts.isEmpty,
           roots.isEmpty {
            return nil
        }

        let cachedAtTimestamp = metadataCachedAt ?? updatedAt
        let cachedAt = Date(timeIntervalSince1970: cachedAtTimestamp)

        return MCPServerMetadataCache(
            cachedAt: cachedAt,
            info: info,
            tools: tools,
            resources: resources,
            resourceTemplates: resourceTemplates,
            prompts: prompts,
            roots: roots
        )
    }
}

private struct MCPToolRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "mcp_tools"

    enum CodingKeys: String, CodingKey {
        case id
        case serverID = "server_id"
        case name
        case description
        case inputSchemaData = "input_schema_data"
        case examplesData = "examples_data"
        case sortIndex = "sort_index"
        case updatedAt = "updated_at"
    }

    enum Columns {
        static let id = Column(CodingKeys.id.rawValue)
        static let serverID = Column(CodingKeys.serverID.rawValue)
        static let name = Column(CodingKeys.name.rawValue)
        static let sortIndex = Column(CodingKeys.sortIndex.rawValue)
    }

    static let server = belongsTo(MCPServerRecord.self, using: ForeignKey([CodingKeys.serverID.rawValue]))

    var id: String
    var serverID: String
    var name: String
    var description: String?
    var inputSchemaData: Data?
    var examplesData: Data?
    var sortIndex: Int
    var updatedAt: Double

    init(serverID: String, tool: MCPToolDescription, sortIndex: Int, updatedAt: Double) throws {
        self.id = Self.makePrimaryID(serverID: serverID, toolName: tool.toolId)
        self.serverID = serverID
        self.name = tool.toolId
        self.description = tool.description
        self.inputSchemaData = try MCPServerStoreCodec.encodeIfPresent(tool.inputSchema)
        if let examples = tool.examples, !examples.isEmpty {
            self.examplesData = try MCPServerStoreCodec.encode(examples)
        } else {
            self.examplesData = nil
        }
        self.sortIndex = sortIndex
        self.updatedAt = updatedAt
    }

    func toToolDescription() -> MCPToolDescription? {
        let inputSchema = MCPServerStoreCodec.decodeIfPresent(JSONValue.self, from: inputSchemaData)
        let examples = MCPServerStoreCodec.decodeIfPresent([JSONValue].self, from: examplesData)
        return MCPToolDescription(
            toolId: name,
            description: description,
            inputSchema: inputSchema,
            examples: examples
        )
    }

    private static func makePrimaryID(serverID: String, toolName: String) -> String {
        "\(serverID)::\(toolName)"
    }
}

private enum MCPServerStoreCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try makeEncoder().encode(value)
    }

    static func encodeIfPresent<T: Encodable>(_ value: T?) throws -> Data? {
        guard let value else { return nil }
        return try makeEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(type, from: data)
    }

    static func decodeIfPresent<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? makeDecoder().decode(type, from: data)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension NSLock {
    func withLock<T>(_ block: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try block()
    }
}
