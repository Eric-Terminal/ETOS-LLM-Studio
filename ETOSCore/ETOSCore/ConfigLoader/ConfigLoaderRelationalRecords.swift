// ============================================================================
// ConfigLoaderRelationalRecords.swift
// ============================================================================
// ETOS LLM Studio
//
// 提供 ConfigLoader 使用的 GRDB 关系型 Provider 记录模型。
// ============================================================================

import Foundation
import GRDB

extension ConfigLoader {
    struct RelationalProviderRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
        static let databaseTableName = "providers"

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case baseURL = "base_url"
            case apiFormat = "api_format"
            case proxyIsEnabled = "proxy_is_enabled"
            case proxyType = "proxy_type"
            case proxyHost = "proxy_host"
            case proxyPort = "proxy_port"
            case proxyUsername = "proxy_username"
            case proxyPassword = "proxy_password"
            case updatedAt = "updated_at"
        }

        var id: String
        var name: String
        var baseURL: String
        var apiFormat: String
        var proxyIsEnabled: Int?
        var proxyType: String?
        var proxyHost: String?
        var proxyPort: Int?
        var proxyUsername: String?
        var proxyPassword: String?
        var updatedAt: Double
    }

    struct RelationalProviderAPIKeyRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
        static let databaseTableName = "provider_api_keys"

        enum CodingKeys: String, CodingKey {
            case providerID = "provider_id"
            case keyIndex = "key_index"
            case apiKey = "api_key"
        }

        enum Columns {
            static let providerID = Column(CodingKeys.providerID.rawValue)
        }

        var providerID: String
        var keyIndex: Int
        var apiKey: String
    }

    struct RelationalProviderHeaderOverrideRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
        static let databaseTableName = "provider_header_overrides"

        enum CodingKeys: String, CodingKey {
            case providerID = "provider_id"
            case headerKey = "header_key"
            case headerValue = "header_value"
        }

        enum Columns {
            static let providerID = Column(CodingKeys.providerID.rawValue)
        }

        var providerID: String
        var headerKey: String
        var headerValue: String
    }

    struct RelationalProviderModelRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
        static let databaseTableName = "provider_models"

        enum CodingKeys: String, CodingKey {
            case id
            case providerID = "provider_id"
            case modelName = "model_name"
            case displayName = "display_name"
            case isActivated = "is_activated"
            case kind
            case inputModalitiesJSON = "input_modalities_json"
            case outputModalitiesJSON = "output_modalities_json"
            case requestBodyOverrideMode = "request_body_override_mode"
            case rawRequestBodyJSON = "raw_request_body_json"
            case requestBodyControlsJSON = "request_body_controls_json"
            case pricingJSON = "pricing_json"
            case sortIndex = "sort_index"
            case updatedAt = "updated_at"
        }

        enum Columns {
            static let providerID = Column(CodingKeys.providerID.rawValue)
        }

        var id: String
        var providerID: String
        var modelName: String
        var displayName: String
        var isActivated: Int
        var kind: String?
        var inputModalitiesJSON: String?
        var outputModalitiesJSON: String?
        var requestBodyOverrideMode: String?
        var rawRequestBodyJSON: String?
        var requestBodyControlsJSON: String?
        var pricingJSON: String?
        var sortIndex: Int
        var updatedAt: Double
    }

    struct RelationalProviderModelCapabilityRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
        static let databaseTableName = "provider_model_capabilities"

        enum CodingKeys: String, CodingKey {
            case modelID = "model_id"
            case capability
            case sortIndex = "sort_index"
        }

        enum Columns {
            static let modelID = Column(CodingKeys.modelID.rawValue)
        }

        var modelID: String
        var capability: String
        var sortIndex: Int
    }

    struct RelationalProviderModelOverrideParameterRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
        static let databaseTableName = "provider_model_override_parameters"

        enum CodingKeys: String, CodingKey {
            case modelID = "model_id"
            case paramKey = "param_key"
            case valueType = "value_type"
            case stringValue = "string_value"
            case numberValue = "number_value"
            case boolValue = "bool_value"
            case jsonValueText = "json_value_text"
        }

        enum Columns {
            static let modelID = Column(CodingKeys.modelID.rawValue)
        }

        var modelID: String
        var paramKey: String
        var valueType: String
        var stringValue: String?
        var numberValue: Double?
        var boolValue: Int?
        var jsonValueText: String?
    }
}
