// ============================================================================
// MCPModels.swift
// ============================================================================
// 定义 Model Context Protocol 相关的通用数据结构。
// ============================================================================

import Foundation

public struct MCPClientInfo: Codable, Hashable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct MCPClientCapabilities: Codable, Hashable {
    public var roots: MCPClientRootsCapabilities?
    public var sampling: MCPClientSamplingCapabilities?
    public var elicitation: MCPClientElicitationCapabilities?
    public var experimental: [String: JSONValue]?

    public init(
        roots: MCPClientRootsCapabilities? = nil,
        sampling: MCPClientSamplingCapabilities? = nil,
        elicitation: MCPClientElicitationCapabilities? = nil,
        experimental: [String: JSONValue]? = nil
    ) {
        self.roots = roots
        self.sampling = sampling
        self.elicitation = elicitation
        self.experimental = experimental
    }
}

public struct MCPClientRootsCapabilities: Codable, Hashable {
    public var listChanged: Bool?

    public init(listChanged: Bool? = nil) {
        self.listChanged = listChanged
    }
}

public struct MCPClientSamplingCapabilities: Codable, Hashable {
    public init() {}
}

public struct MCPClientElicitationCapabilities: Codable, Hashable {
    public var form: MCPClientElicitationFormCapability?
    public var url: MCPClientElicitationURLCapability?

    public init(
        form: MCPClientElicitationFormCapability? = nil,
        url: MCPClientElicitationURLCapability? = nil
    ) {
        self.form = form
        self.url = url
    }
}

public struct MCPClientElicitationFormCapability: Codable, Hashable {
    public init() {}
}

public struct MCPClientElicitationURLCapability: Codable, Hashable {
    public init() {}
}

public enum MCPProtocolVersion {
    // 优先使用当前较新的协议版本，同时兼容历史服务端返回。
    public static let current = "2025-11-25"
    public static let supported = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public static func isSupported(_ version: String) -> Bool {
        supported.contains(version)
    }
}

enum MCPRuntimeDefaults {
    static let requestTimeout: TimeInterval = 180
    static let maxRetryAttempts = 3
}

public struct MCPServerInfo: Codable, Hashable {
    public var name: String
    public var version: String?
    public var capabilities: [String: JSONValue]?
    public var metadata: [String: JSONValue]?
}

public struct MCPToolDescription: Codable, Identifiable, Hashable {
    public var id: String { toolId }

    public let toolId: String
    public let description: String?
    public let inputSchema: JSONValue?
    public let examples: [JSONValue]?

    public init(toolId: String, description: String?, inputSchema: JSONValue?, examples: [JSONValue]?) {
        self.toolId = toolId
        self.description = description
        self.inputSchema = inputSchema
        self.examples = examples
    }

    private enum CodingKeys: String, CodingKey {
        case toolId
        case name
        case id
        case description
        case inputSchema
        case examples
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let resolvedId = try container.decodeIfPresent(String.self, forKey: .toolId)
            ?? container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decodeIfPresent(String.self, forKey: .id)
        guard let resolvedId else {
            throw DecodingError.keyNotFound(CodingKeys.toolId, DecodingError.Context(codingPath: container.codingPath, debugDescription: "Missing tool identifier"))
        }
        self.toolId = resolvedId
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.inputSchema = try container.decodeIfPresent(JSONValue.self, forKey: .inputSchema)
        self.examples = try container.decodeIfPresent([JSONValue].self, forKey: .examples)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toolId, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(inputSchema, forKey: .inputSchema)
        try container.encodeIfPresent(examples, forKey: .examples)
    }
}

public struct MCPResourceDescription: Codable, Identifiable, Hashable {
    public var id: String { resourceId }

    public let resourceId: String
    public let description: String?
    public let outputSchema: JSONValue?
    public let querySchema: JSONValue?

    public init(resourceId: String, description: String?, outputSchema: JSONValue?, querySchema: JSONValue?) {
        self.resourceId = resourceId
        self.description = description
        self.outputSchema = outputSchema
        self.querySchema = querySchema
    }

    private enum CodingKeys: String, CodingKey {
        case resourceId
        case uri
        case name
        case description
        case outputSchema
        case querySchema
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let resolvedId = try container.decodeIfPresent(String.self, forKey: .uri)
            ?? container.decodeIfPresent(String.self, forKey: .resourceId)
            ?? container.decodeIfPresent(String.self, forKey: .name)
        guard let resolvedId else {
            throw DecodingError.keyNotFound(CodingKeys.resourceId, DecodingError.Context(codingPath: container.codingPath, debugDescription: "Missing resource identifier"))
        }
        self.resourceId = resolvedId
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.outputSchema = try container.decodeIfPresent(JSONValue.self, forKey: .outputSchema)
        self.querySchema = try container.decodeIfPresent(JSONValue.self, forKey: .querySchema)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(resourceId, forKey: .uri)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(outputSchema, forKey: .outputSchema)
        try container.encodeIfPresent(querySchema, forKey: .querySchema)
    }
}

public struct MCPResourceTemplate: Codable, Identifiable, Hashable {
    public var id: String { uriTemplate }

    public let uriTemplate: String
    public let name: String?
    public let title: String?
    public let description: String?
    public let mimeType: String?
    public let annotations: JSONValue?
    public let metadata: [String: JSONValue]?

    public init(
        uriTemplate: String,
        name: String?,
        title: String?,
        description: String?,
        mimeType: String?,
        annotations: JSONValue?,
        metadata: [String: JSONValue]? = nil
    ) {
        self.uriTemplate = uriTemplate
        self.name = name
        self.title = title
        self.description = description
        self.mimeType = mimeType
        self.annotations = annotations
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case uriTemplate
        case name
        case title
        case description
        case mimeType
        case annotations
        case metadata = "_meta"
    }
}
