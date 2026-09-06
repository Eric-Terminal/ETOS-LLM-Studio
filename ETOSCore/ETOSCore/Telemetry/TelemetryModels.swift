// ============================================================================
// TelemetryModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 性能遥测的稳定传输模型。保留未知系统字段，但在落盘前移除可能承载用户内容的异常文本。
// ============================================================================

import Foundation
import CryptoKit
#if os(iOS)
import UIKit
#endif

public enum TelemetryPayloadKind: String, Codable, CaseIterable, Sendable {
    case metric
    case diagnostic
}

public enum TelemetryDistribution: String, Codable, CaseIterable, Sendable {
    case testflight
    case appstore
    case development
    case unknown
}

public struct TelemetryAppMetadata: Codable, Hashable, Sendable {
    public let version: String
    public let build: String
    public let distribution: TelemetryDistribution

    public init(version: String, build: String, distribution: TelemetryDistribution) {
        self.version = version
        self.build = build
        self.distribution = distribution
    }

    public static var current: TelemetryAppMetadata {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"

        let distribution: TelemetryDistribution
        #if DEBUG
        distribution = .development
        #else
        if bundle.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" {
            distribution = .testflight
        } else if bundle.appStoreReceiptURL != nil {
            distribution = .appstore
        } else {
            distribution = .unknown
        }
        #endif

        return TelemetryAppMetadata(version: version, build: build, distribution: distribution)
    }
}

public struct TelemetryPlatformMetadata: Codable, Hashable, Sendable {
    public let name: String
    public let osVersion: String
    public let deviceClass: String
    public let architecture: String

    enum CodingKeys: String, CodingKey {
        case name
        case osVersion = "os_version"
        case deviceClass = "device_class"
        case architecture
    }

    public init(name: String, osVersion: String, deviceClass: String, architecture: String) {
        self.name = name
        self.osVersion = osVersion
        self.deviceClass = deviceClass
        self.architecture = architecture
    }

    public static var currentIOS: TelemetryPlatformMetadata {
        #if os(iOS)
        return TelemetryPlatformMetadata(
            name: "ios",
            osVersion: UIDevice.current.systemVersion,
            deviceClass: currentHardwareModel(),
            architecture: currentArchitecture
        )
        #else
        return TelemetryPlatformMetadata(
            name: "ios",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceClass: "test",
            architecture: currentArchitecture
        )
        #endif
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    #if os(iOS)
    private static func currentHardwareModel() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return UIDevice.current.model }

        let identifier = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }
    #endif
}

public struct TelemetryPrivacyDeclaration: Codable, Hashable, Sendable {
    public let containsChatContent: Bool
    public let containsRequestBody: Bool
    public let containsResponseBody: Bool
    public let containsCredentials: Bool
    public let containsUserIdentifier: Bool

    enum CodingKeys: String, CodingKey {
        case containsChatContent = "contains_chat_content"
        case containsRequestBody = "contains_request_body"
        case containsResponseBody = "contains_response_body"
        case containsCredentials = "contains_credentials"
        case containsUserIdentifier = "contains_user_identifier"
    }

    public init(
        containsChatContent: Bool = false,
        containsRequestBody: Bool = false,
        containsResponseBody: Bool = false,
        containsCredentials: Bool = false,
        containsUserIdentifier: Bool = false
    ) {
        self.containsChatContent = containsChatContent
        self.containsRequestBody = containsRequestBody
        self.containsResponseBody = containsResponseBody
        self.containsCredentials = containsCredentials
        self.containsUserIdentifier = containsUserIdentifier
    }

    public static let noUserContent = TelemetryPrivacyDeclaration()

    public var isSafeForUpload: Bool {
        !containsChatContent &&
        !containsRequestBody &&
        !containsResponseBody &&
        !containsCredentials &&
        !containsUserIdentifier
    }
}

public struct TelemetryEnvelope: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2
    public static let supportedSchemaVersions = 1...currentSchemaVersion

    public let schemaVersion: Int
    public let payloadID: String
    public let kind: TelemetryPayloadKind
    public let capturedAt: Date
    public let periodStart: Date?
    public let periodEnd: Date?
    public let app: TelemetryAppMetadata
    public let platform: TelemetryPlatformMetadata
    public let privacy: TelemetryPrivacyDeclaration
    public let payload: JSONValue

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case payloadID = "payload_id"
        case kind
        case capturedAt = "captured_at"
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case app
        case platform
        case privacy
        case payload
    }

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        payloadID: String,
        kind: TelemetryPayloadKind,
        capturedAt: Date,
        periodStart: Date?,
        periodEnd: Date?,
        app: TelemetryAppMetadata,
        platform: TelemetryPlatformMetadata,
        privacy: TelemetryPrivacyDeclaration = .noUserContent,
        payload: JSONValue
    ) {
        self.schemaVersion = schemaVersion
        self.payloadID = payloadID
        self.kind = kind
        self.capturedAt = capturedAt
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.app = app
        self.platform = platform
        self.privacy = privacy
        self.payload = payload
    }
}

public enum TelemetryEnvelopeError: LocalizedError {
    case payloadIsNotJSONObject
    case privacyInvariantViolated

    public var errorDescription: String? {
        switch self {
        case .payloadIsNotJSONObject:
            return NSLocalizedString("MetricKit 遥测不是有效的 JSON 对象。", comment: "Invalid MetricKit JSON")
        case .privacyInvariantViolated:
            return NSLocalizedString("遥测隐私声明不允许上传用户内容。", comment: "Unsafe telemetry privacy declaration")
        }
    }
}

public enum TelemetryEnvelopeCodec {
    public static func makeEnvelope(
        kind: TelemetryPayloadKind,
        rawPayloadData: Data,
        capturedAt: Date = Date(),
        periodStart: Date?,
        periodEnd: Date?,
        app: TelemetryAppMetadata = .current,
        platform: TelemetryPlatformMetadata = .currentIOS
    ) throws -> TelemetryEnvelope {
        let payload = try TelemetryPayloadFlattener.flatten(rawPayloadData)
        let payloadID = SHA256.hash(data: try canonicalPayloadData(payload))
            .map { String(format: "%02x", $0) }
            .joined()

        let envelope = TelemetryEnvelope(
            payloadID: payloadID,
            kind: kind,
            capturedAt: capturedAt,
            periodStart: periodStart,
            periodEnd: periodEnd,
            app: app,
            platform: platform,
            payload: payload
        )
        guard envelope.privacy.isSafeForUpload else {
            throw TelemetryEnvelopeError.privacyInvariantViolated
        }
        return envelope
    }

    public static func encode(_ envelope: TelemetryEnvelope, prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if prettyPrinted {
            formatting.insert(.prettyPrinted)
        }
        encoder.outputFormatting = formatting
        return try encoder.encode(envelope)
    }

    public static func decode(_ data: Data) throws -> TelemetryEnvelope {
        guard TelemetryPayloadFlattener.isWithinDecodingLimits(data) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "遥测信封超过安全解码边界。"
            ))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(TelemetryEnvelope.self, from: data)
        guard TelemetryEnvelope.supportedSchemaVersions.contains(envelope.schemaVersion) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "不支持的遥测信封版本。"
            ))
        }
        return envelope
    }

    public static func canonicalPayloadData(_ payload: JSONValue) throws -> Data {
        guard case .dictionary = payload else {
            throw TelemetryEnvelopeError.payloadIsNotJSONObject
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }
}

public enum TelemetryLogDeliveryState: String, Sendable {
    case pending
    case sentThisLaunch
    case tooLarge
}

public struct TelemetryLogRecord: Identifiable, Hashable, Sendable {
    public let envelope: TelemetryEnvelope
    public let rawJSON: String
    public let fileSizeBytes: Int64
    public let deliveryState: TelemetryLogDeliveryState
    public let relativePath: String?

    public init(
        envelope: TelemetryEnvelope,
        rawJSON: String,
        fileSizeBytes: Int64,
        deliveryState: TelemetryLogDeliveryState,
        relativePath: String?
    ) {
        self.envelope = envelope
        self.rawJSON = rawJSON
        self.fileSizeBytes = fileSizeBytes
        self.deliveryState = deliveryState
        self.relativePath = relativePath
    }

    public var id: String {
        "\(deliveryState.rawValue):\(envelope.payloadID)"
    }

    public var payloadCategories: [String] {
        guard case .dictionary(let values) = envelope.payload else { return [] }
        return values.keys.sorted()
    }

    public var periodDescription: String {
        guard let periodStart = envelope.periodStart, let periodEnd = envelope.periodEnd else {
            return NSLocalizedString("系统未提供统计时间范围", comment: "MetricKit period unavailable")
        }
        let formatter = ISO8601DateFormatter()
        return "\(formatter.string(from: periodStart)) – \(formatter.string(from: periodEnd))"
    }
}
