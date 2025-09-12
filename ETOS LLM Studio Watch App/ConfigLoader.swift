// ConfigLoader.swift
// ETOS LLM Studio Watch App 配置加载文件
// 负责从 AppConfig.json 文件中读取和解析应用配置

import Foundation

// MARK: - Codable 数据结构

/// 用于解析 JSON 中模型配置的临时数据结构
/// 它遵循 Codable 协议，以便于从 JSON 解码
// 为了向后兼容，apiKey 可以是单个字符串或字符串数组
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

    // 将apiKey转换为字符串数组
    func toStringArray() -> [String] {
        switch self {
        case .string(let str):
            return [str]
        case .array(let arr):
            return arr
        }
    }
}

private struct ModelConfigData: Codable, Hashable {
    let name: String
    let apiKey: APIKey
    let apiURL: String
    let basePayload: [String: JSONValue] // 使用自定义的 JSONValue 来处理 [String: Any]

    /// 将解析出的数据转换为应用内部使用的 AIModelConfig 结构
    func toAIModelConfig() -> AIModelConfig {
        let anyPayload = basePayload.mapValues { $0.toAny() }
        return AIModelConfig(name: name, apiKeys: apiKey.toStringArray(), apiURL: apiURL, basePayload: anyPayload)
    }
}

/// 匹配 AppConfig.json 顶层结构的 Codable 结构
private struct AppConfigData: Codable {
    let backgroundImages: [String]
    let modelConfigs: [ModelConfigData]
}

/// 一个辅助枚举，用于在 Codable 中处理不确定的 JSON 值类型 (即 [String: Any])
private enum JSONValue: Codable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case dictionary([String: JSONValue])
    case array([JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .dictionary(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.typeMismatch(JSONValue.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON type"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .dictionary(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        }
    }

    /// 将 JSONValue 转换回 Any 类型，以便在应用中使用
    func toAny() -> Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        case .dictionary(let value): return value.mapValues { $0.toAny() }
        case .array(let value): return value.map { $0.toAny() }
        }
    }
}


// MARK: - 配置加载器

/// 配置加载器类
/// 提供一个静态方法来加载和解析配置
class ConfigLoader {
    
    /// 从应用的 Bundle 中加载 AppConfig.json 文件
    /// - Returns: 一个元组，包含模型配置数组和背景图片名称数组
    static func load() -> (models: [AIModelConfig], backgrounds: [String]) {
        print("⚙️ [ConfigLoader] 开始加载应用配置...")
        
        // 1. 在应用的资源包中查找 AppConfig.json 文件
        guard let url = Bundle.main.url(forResource: "AppConfig", withExtension: "json") else {
            print("❌ [ConfigLoader] 致命错误: 在应用资源包中找不到 AppConfig.json 文件。")
            fatalError("错误: 在应用资源包中找不到 AppConfig.json 文件。请确保该文件已添加到项目中。")
        }
        print("  - 找到了配置文件: \(url.path)")

        do {
            // 2. 读取文件数据
            let data = try Data(contentsOf: url)
            
            // 打印原始JSON内容
            if let jsonString = String(data: data, encoding: .utf8) {
                print("  - 原始 JSON 内容:\n---\n\(jsonString)\n---")
            } else {
                print("  - 警告: 无法将文件数据转换为 UTF-8 字符串进行预览。")
            }
            
            // 3. 使用 JSONDecoder 将数据解码为我们定义的 Codable 结构
            print("  - 正在解码 JSON 数据...")
            let decoder = JSONDecoder()
            let configData = try decoder.decode(AppConfigData.self, from: data)
            print("  - JSON 解码成功。")
            
            // 4. 打印解析后的数据摘要
            print("  - 成功加载了 \(configData.modelConfigs.count) 个模型配置:")
            for model in configData.modelConfigs {
                print("    - 模型: \(model.name)")
            }
            print("  - 成功加载了 \(configData.backgroundImages.count) 个背景图片: \(configData.backgroundImages.joined(separator: ", "))")

            let models = configData.modelConfigs.map { $0.toAIModelConfig() }
            
            // 5. 返回最终的配置数据
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