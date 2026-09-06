// ============================================================================
// OfficialDataActions.swift
// ============================================================================
// 官方数据操作协议与同步预览模型。
// ============================================================================

import Foundation

public enum OfficialDataSyncTrigger: String, Sendable {
    case initialSync = "initial_sync"
    case manualSync = "manual_sync"
}

public struct OfficialDataActionSummary: Sendable, Equatable {
    public let insertedCount: Int
    public let updatedCount: Int
    public let restoredCount: Int
    public let skippedCount: Int
    public let failedCount: Int

    public init(
        insertedCount: Int = 0,
        updatedCount: Int = 0,
        restoredCount: Int = 0,
        skippedCount: Int = 0,
        failedCount: Int = 0
    ) {
        self.insertedCount = insertedCount
        self.updatedCount = updatedCount
        self.restoredCount = restoredCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
    }

    public static let empty = OfficialDataActionSummary()

    public var changedCount: Int {
        insertedCount + updatedCount + restoredCount
    }

    func adding(_ outcome: OfficialProviderActionOutcome) -> OfficialDataActionSummary {
        OfficialDataActionSummary(
            insertedCount: insertedCount + (outcome == .inserted ? 1 : 0),
            updatedCount: updatedCount + (outcome == .updated ? 1 : 0),
            restoredCount: restoredCount + (outcome == .restored ? 1 : 0),
            skippedCount: skippedCount + (outcome == .skipped ? 1 : 0),
            failedCount: failedCount + (outcome == .failed ? 1 : 0)
        )
    }
}

public struct OfficialDataPreviewFile: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let fileName: String
    public let destinationPath: String
    public let size: Int64
}

public enum OfficialDataPreviewOperationKind: String, Sendable {
    case insert
    case update
    case restore
    case unchanged
    case unavailable
}

public struct OfficialDataPreviewOperation: Identifiable, Sendable {
    public let id: String
    public let providerName: String
    public let providerBaseURL: String
    public let kind: OfficialDataPreviewOperationKind
    public let modelNamesToAdd: [String]
    public let modelNamesToUpdate: [String]
    public let modelNamesToRemove: [String]
    public let changesProviderConfiguration: Bool
    public let preservesLocalCredentials: Bool
    public let preservesLocalProxy: Bool
    public let preservesLocalModelActivation: Bool
    public let detail: String?
}

public struct OfficialDataSyncPreview: Identifiable, @unchecked Sendable {
    public let id: UUID
    public let files: [OfficialDataPreviewFile]
    public let operations: [OfficialDataPreviewOperation]
    public let unavailableOperationCount: Int
    public let preparationFailures: [String]

    let manifestURL: URL
    let manifest: ConfigLoader.OfficialDataManifest
    let preparedActions: [PreparedOfficialDataAction]

    init(
        manifestURL: URL,
        manifest: ConfigLoader.OfficialDataManifest,
        files: [OfficialDataPreviewFile],
        operations: [OfficialDataPreviewOperation],
        preparedActions: [PreparedOfficialDataAction],
        preparationFailures: [String] = []
    ) {
        self.id = UUID()
        self.manifestURL = manifestURL
        self.manifest = manifest
        self.files = files
        self.operations = operations
        self.preparedActions = preparedActions
        self.preparationFailures = preparationFailures
        self.unavailableOperationCount = operations.filter { $0.kind == .unavailable }.count
    }

    public var isEmpty: Bool {
        files.isEmpty && operations.isEmpty
    }
}

struct OfficialDataActionEntry: Decodable, Sendable {
    let id: String
    let revision: Int
    let kind: String
    let applyOn: [OfficialDataActionApplyOn]
    let minimumAppBuild: Int?
    let platforms: [OfficialDataActionPlatform]
    let url: String
    let fileName: String
    let sha256: String
    let size: Int64
    let mergePolicy: OfficialProviderMergePolicy

    enum CodingKeys: String, CodingKey {
        case id, revision, kind, platforms
        case applyOn = "apply_on"
        case minimumAppBuild = "minimum_app_build"
        case url = "payload_url"
        case fileName = "payload_file_name"
        case sha256 = "payload_sha256"
        case size = "payload_size"
        case mergePolicy = "merge_policy"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        revision = try container.decode(Int.self, forKey: .revision)
        kind = try container.decode(String.self, forKey: .kind)
        applyOn = try container.decode([OfficialDataActionApplyOn].self, forKey: .applyOn)
        minimumAppBuild = try container.decodeIfPresent(Int.self, forKey: .minimumAppBuild)
        platforms = try container.decodeIfPresent([OfficialDataActionPlatform].self, forKey: .platforms) ?? []
        url = try container.decode(String.self, forKey: .url)
        fileName = try container.decode(String.self, forKey: .fileName)
        sha256 = try container.decode(String.self, forKey: .sha256)
        size = try container.decode(Int64.self, forKey: .size)
        mergePolicy = try container.decode(OfficialProviderMergePolicy.self, forKey: .mergePolicy)
    }
}

/// 未识别的未来操作不应阻断同一份清单中的普通文件下载。
struct OfficialDataActionEnvelope: Decodable {
    let action: OfficialDataActionEntry?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: OfficialDataActionEntry.CodingKeys.self)
        let kind = try container.decodeIfPresent(String.self, forKey: .kind)
        guard kind == OfficialDataActionKind.providerUpsert.rawValue else {
            action = nil
            return
        }
        action = try? OfficialDataActionEntry(from: decoder)
    }
}

struct PreparedOfficialDataAction: @unchecked Sendable {
    let entry: OfficialDataActionEntry
    let payload: Data
    let bundle: OfficialDataActionBundle
}

enum OfficialDataActionKind: String, Codable, Equatable, Sendable {
    case providerUpsert = "provider.upsert"
}

enum OfficialDataActionApplyOn: String, Codable, Equatable, Sendable {
    case initialSync = "initial_sync"
    case manualSync = "manual_sync"
}

enum OfficialDataActionPlatform: String, Codable, Equatable, Sendable {
    case iOS = "ios"
    case watchOS = "watchos"
}

struct OfficialDataActionBundle: Codable, @unchecked Sendable {
    let schemaVersion: Int
    let id: String
    let revision: Int
    let kind: OfficialDataActionKind
    let applyOn: [OfficialDataActionApplyOn]
    let minimumAppBuild: Int?
    let platforms: [OfficialDataActionPlatform]
    let provider: Provider
    let mergePolicy: OfficialProviderMergePolicy

    enum CodingKeys: String, CodingKey {
        case id, revision, kind, platforms, provider
        case schemaVersion = "schema_version"
        case applyOn = "apply_on"
        case minimumAppBuild = "minimum_app_build"
        case mergePolicy = "merge_policy"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(String.self, forKey: .id)
        revision = try container.decode(Int.self, forKey: .revision)
        kind = try container.decode(OfficialDataActionKind.self, forKey: .kind)
        applyOn = try container.decode([OfficialDataActionApplyOn].self, forKey: .applyOn)
        minimumAppBuild = try container.decodeIfPresent(Int.self, forKey: .minimumAppBuild)
        platforms = try container.decodeIfPresent([OfficialDataActionPlatform].self, forKey: .platforms) ?? []
        provider = try container.decode(Provider.self, forKey: .provider)
        mergePolicy = try container.decode(OfficialProviderMergePolicy.self, forKey: .mergePolicy)
    }
}

enum OfficialProviderFieldPolicy: String, Codable, Equatable, Sendable {
    case updateIfUnmodified = "update_if_unmodified"
    case serverWins = "server_wins"
    case preserveLocal = "preserve_local"
}

enum OfficialProviderAPIKeyPolicy: String, Codable, Equatable, Sendable {
    case preserveLocalIfNonempty = "preserve_local_if_nonempty"
    case serverWins = "server_wins"
    case appendUnique = "append_unique"
    case updateIfUnmodified = "update_if_unmodified"
}

enum OfficialProviderDictionaryPolicy: String, Codable, Equatable, Sendable {
    case updateIfUnmodified = "update_if_unmodified"
    case serverWins = "server_wins"
    case preserveLocal = "preserve_local"
    case mergeServerWins = "merge_server_wins"
}

enum OfficialProviderMissingModelPolicy: String, Codable, Equatable, Sendable {
    case insert
    case skip
}

enum OfficialProviderRemovedModelPolicy: String, Codable, Equatable, Sendable {
    case preserve
    case deleteIfUnmodified = "delete_if_unmodified"
}

enum OfficialProviderUserModelPolicy: String, Codable, Equatable, Sendable {
    case preserve
    case delete
}

enum OfficialProviderDeletedPolicy: String, Codable, Equatable, Sendable {
    case keepDeleted = "keep_deleted"
    case restoreOnManualSync = "restore_on_manual_sync"
    case forceRestore = "force_restore"
}

struct OfficialProviderMergePolicy: Codable, Equatable, Sendable {
    let providerFields: OfficialProviderFieldPolicy
    let apiKeys: OfficialProviderAPIKeyPolicy
    let headerOverrides: OfficialProviderDictionaryPolicy
    let proxyConfiguration: OfficialProviderFieldPolicy
    let models: OfficialProviderModelMergePolicy
    let ifUserDeleted: OfficialProviderDeletedPolicy

    enum CodingKeys: String, CodingKey {
        case models
        case providerFields = "provider_fields"
        case apiKeys = "api_keys"
        case headerOverrides = "header_overrides"
        case proxyConfiguration = "proxy_configuration"
        case ifUserDeleted = "if_user_deleted"
    }
}

struct OfficialProviderModelMergePolicy: Codable, Equatable, Sendable {
    let fields: OfficialProviderFieldPolicy
    let isActivated: OfficialProviderFieldPolicy
    let onMissing: OfficialProviderMissingModelPolicy
    let onRemoved: OfficialProviderRemovedModelPolicy
    let userModels: OfficialProviderUserModelPolicy

    enum CodingKeys: String, CodingKey {
        case fields
        case isActivated = "is_activated"
        case onMissing = "on_missing"
        case onRemoved = "on_removed"
        case userModels = "user_models"
    }
}

enum OfficialProviderActionOutcome: Equatable {
    case inserted
    case updated
    case restored
    case skipped
    case failed
}
