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
class ConfigLoader {
    
    /// 从应用的 Bundle 中加载 AppConfig.json 文件
    static func load() -> (models: [AIModelConfig], backgrounds: [String]) {
        print("⚙️ [ConfigLoader] 开始加载应用配置...")
        
        guard let url = Bundle.main.url(forResource: "AppConfig", withExtension: "json") else {
            fatalError("错误: 在应用资源包中找不到 AppConfig.json 文件。请确保该文件已添加到项目中。")
        }
        print("  - 找到了配置文件: \(url.path)")

        do {
            let data = try Data(contentsOf: url)
            
            if let jsonString = String(data: data, encoding: .utf8) {
                print("  - 原始 JSON 内容:\n---\n\(jsonString)\n---")
            }
            
            let decoder = JSONDecoder()
            let configData = try decoder.decode(AppConfigData.self, from: data)
            
            print("  - 成功加载了 \(configData.modelConfigs.count) 个模型配置:")
            for model in configData.modelConfigs { print("    - 模型: \(model.name)") }
            print("  - 成功加载了 \(configData.backgroundImages.count) 个背景图片: \(configData.backgroundImages.joined(separator: ", "))")

            let models = configData.modelConfigs.map { $0.toAIModelConfig() }
            
            print("✅ [ConfigLoader] 应用配置加载完成。")
            return (models, configData.backgroundImages)
        } catch {
            print("❌ [ConfigLoader] 致命错误: 加载或解析 AppConfig.json 文件失败: \(error)")
            if let decodingError = error as? DecodingError {
                print("  - 解码错误详情: \(decodingError)")
            }
            fatalError("错误: 加载或解析 AppConfig.json 文件失败: \(error)")
        }
    }
}