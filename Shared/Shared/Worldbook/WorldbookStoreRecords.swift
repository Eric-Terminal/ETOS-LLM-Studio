// ============================================================================
// WorldbookStoreRecords.swift
// ============================================================================
// ETOS LLM Studio
//
// 世界书 SQLite 关系表记录模型。
// ============================================================================

import Foundation
import GRDB

struct RelationalWorldbookRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "worldbooks"

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case isEnabled = "is_enabled"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case scanDepth = "scan_depth"
        case maxRecursionDepth = "max_recursion_depth"
        case maxInjectedEntries = "max_injected_entries"
        case maxInjectedCharacters = "max_injected_characters"
        case fallbackPosition = "fallback_position"
        case sourceFileName = "source_file_name"
    }

    var id: String
    var name: String
    var description: String
    var isEnabled: Int
    var createdAt: Double
    var updatedAt: Double
    var scanDepth: Int
    var maxRecursionDepth: Int
    var maxInjectedEntries: Int
    var maxInjectedCharacters: Int
    var fallbackPosition: String
    var sourceFileName: String?
}

struct RelationalWorldbookMetadataRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "worldbook_metadata"

    enum CodingKeys: String, CodingKey {
        case worldbookID = "worldbook_id"
        case metaKey = "meta_key"
        case valueType = "value_type"
        case stringValue = "string_value"
        case numberValue = "number_value"
        case boolValue = "bool_value"
        case jsonValueText = "json_value_text"
    }

    var worldbookID: String
    var metaKey: String
    var valueType: String
    var stringValue: String?
    var numberValue: Double?
    var boolValue: Int?
    var jsonValueText: String?
}

struct RelationalWorldbookEntryRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "worldbook_entries"

    enum CodingKeys: String, CodingKey {
        case id
        case worldbookID = "worldbook_id"
        case uid
        case comment
        case content
        case selectiveLogic = "selective_logic"
        case isEnabled = "is_enabled"
        case constantFlag = "constant_flag"
        case position
        case outletName = "outlet_name"
        case entryOrder = "entry_order"
        case depth
        case scanDepth = "scan_depth"
        case caseSensitive = "case_sensitive"
        case matchWholeWords = "match_whole_words"
        case useRegex = "use_regex"
        case useProbability = "use_probability"
        case probability
        case groupName = "group_name"
        case groupOverride = "group_override"
        case groupWeight = "group_weight"
        case useGroupScoring = "use_group_scoring"
        case role
        case sticky
        case cooldown
        case delay
        case excludeRecursion = "exclude_recursion"
        case preventRecursion = "prevent_recursion"
        case delayUntilRecursion = "delay_until_recursion"
        case sortIndex = "sort_index"
    }

    var id: String
    var worldbookID: String
    var uid: Int?
    var comment: String
    var content: String
    var selectiveLogic: String
    var isEnabled: Int
    var constantFlag: Int
    var position: String
    var outletName: String?
    var entryOrder: Int
    var depth: Int?
    var scanDepth: Int?
    var caseSensitive: Int
    var matchWholeWords: Int
    var useRegex: Int
    var useProbability: Int
    var probability: Double
    var groupName: String?
    var groupOverride: Int
    var groupWeight: Double
    var useGroupScoring: Int
    var role: String
    var sticky: Int?
    var cooldown: Int?
    var delay: Int?
    var excludeRecursion: Int
    var preventRecursion: Int
    var delayUntilRecursion: Int
    var sortIndex: Int
}

struct RelationalWorldbookEntryKeyRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "worldbook_entry_keys"

    enum CodingKeys: String, CodingKey {
        case entryID = "entry_id"
        case keyValue = "key_value"
        case keyKind = "key_kind"
        case sortIndex = "sort_index"
    }

    var entryID: String
    var keyValue: String
    var keyKind: String
    var sortIndex: Int
}

struct RelationalWorldbookEntryMetadataRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "worldbook_entry_metadata"

    enum CodingKeys: String, CodingKey {
        case entryID = "entry_id"
        case metaKey = "meta_key"
        case valueType = "value_type"
        case stringValue = "string_value"
        case numberValue = "number_value"
        case boolValue = "bool_value"
        case jsonValueText = "json_value_text"
    }

    var entryID: String
    var metaKey: String
    var valueType: String
    var stringValue: String?
    var numberValue: Double?
    var boolValue: Int?
    var jsonValueText: String?
}
