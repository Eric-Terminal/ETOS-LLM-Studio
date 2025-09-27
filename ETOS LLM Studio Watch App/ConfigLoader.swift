// ============================================================================ 
// ConfigLoader.swift
// ============================================================================ 
// ETOS LLM Studio Watch App 配置加载文件
//
// 功能特性:
// - 从 AppConfig.json 加载和解析应用配置
// - 支持模型、背景图等设置的读取
// ============================================================================ 

import Foundation
import os.log

private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ConfigLoader")

// MARK: - Codable 数据结构

// 用于解析 apiKey 的临时结构，以兼容字符串和字符串数组
private enum APIKey: Codable, Hashable {
    case string(String)
    case array([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let arr = try? container.decode([String].self) {
            self = .array(arr)
        } else {
            throw DecodingError.typeMismatch(APIKey.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "apiKey 必须是字符串或字符串数组"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let str):
            try container.encode(str)
        case .array(let arr):
            try container.encode(arr)
        }
    }

    func toStringArray() -> [String] {
        switch self {
        case .string(let str): return [str]
        case .array(let arr): return arr
        }
    }
}

// 用于解析模型配置的临时结构
private struct ModelConfigData: Codable, Hashable {
    let name: String
    let apiKey: APIKey
    let apiURL: String
    let basePayload: [String: JSONValue]

    func toAIModelConfig() -> AIModelConfig {
        let anyPayload = basePayload.mapValues { $0.toAny() }
        return AIModelConfig(name: name, apiKeys: apiKey.toStringArray(), apiURL: apiURL, basePayload: anyPayload)
    }
}

// 匹配 AppConfig.json 顶层结构的结构
private struct AppConfigData: Codable {
    let backgroundImages: [String]
    let modelConfigs: [ModelConfigData]
}

// 用于处理 [String: Any] 这种异构字典的 Codable 辅助枚举
private enum JSONValue: Codable, Hashable {
    case string(String), int(Int), double(Double), bool(Bool)
    case dictionary([String: JSONValue])
    case array([JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .dictionary(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { throw DecodingError.typeMismatch(JSONValue.self, .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON type")) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .dictionary(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        }
    }

    func toAny() -> Any {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .dictionary(let v): return v.mapValues { $0.toAny() }
        case .array(let v): return v.map { $0.toAny() }
        }
    }
}

// MARK: - ConfigLoader 类

/// 配置加载器类
struct ConfigLoader {
    /// 从应用的 Bundle 中加载 AppConfig.json 文件
    static func load() -> (models: [AIModelConfig], backgrounds: [String]) {
        logger.info("Loading application configuration...")

        guard let url = Bundle.main.url(forResource: "AppConfig", withExtension: "json") else {
            logger.critical("FATAL ERROR: AppConfig.json not found in bundle.")
            fatalError("FATAL ERROR: AppConfig.json not found in bundle.")
        }

        logger.info("Found configuration file at: \(url.path)")

        do {
            let data = try Data(contentsOf: url)
            
            if let jsonString = String(data: data, encoding: .utf8) {
                logger.debug("Raw JSON content:\n---\n\(jsonString)\n---")
            }
            
            let appConfig = try JSONDecoder().decode(AppConfigData.self, from: data)
            
            let finalModels = appConfig.modelConfigs.map { $0.toAIModelConfig() }

            logger.info("Successfully loaded \(finalModels.count) model configurations.")
            for model in finalModels { logger.info("  - Model: \(model.name)") }
            logger.info("Successfully loaded \(appConfig.backgroundImages.count) background images.")
            logger.info("Application configuration loaded successfully.")
            
            return (finalModels, appConfig.backgroundImages)

        } catch {
            logger.critical("FATAL ERROR: Failed to load or parse AppConfig.json: \(error.localizedDescription)")
            if let decodingError = error as? DecodingError {
                logger.error("Decoding error details: \(String(describing: decodingError))")
            }
            fatalError("Failed to decode AppConfig.json: \(error.localizedDescription)")
        }
    }
}