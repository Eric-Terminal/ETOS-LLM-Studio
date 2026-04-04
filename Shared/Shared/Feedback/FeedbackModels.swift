// ============================================================================
// FeedbackModels.swift
// ============================================================================
// ETOS LLM Studio 应用内反馈数据模型
//
// 定义内容:
// - 反馈草稿、工单、评论与状态快照
// - 状态映射与标签过滤逻辑
// - 文本脱敏与时间编码辅助工具
// ============================================================================

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - 反馈类型

public enum FeedbackCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case bug = "bug"
    case suggestion = "suggestion"

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .bug:
            return NSLocalizedString("问题（Bug）", comment: "Feedback category bug")
        case .suggestion:
            return NSLocalizedString("建议（Feature）", comment: "Feedback category suggestion")
        }
    }
}

// MARK: - 工单状态

public enum FeedbackTicketStatus: String, Codable, CaseIterable, Sendable {
    case triage = "triage"
    case inProgress = "in_progress"
    case blocked = "blocked"
    case resolved = "resolved"
    case closed = "closed"
    case unknown = "unknown"

    public var localizedTitle: String {
        switch self {
        case .triage:
            return NSLocalizedString("待分拣", comment: "Feedback status triage")
        case .inProgress:
            return NSLocalizedString("处理中", comment: "Feedback status in progress")
        case .blocked:
            return NSLocalizedString("阻塞中", comment: "Feedback status blocked")
        case .resolved:
            return NSLocalizedString("已解决", comment: "Feedback status resolved")
        case .closed:
            return NSLocalizedString("已关闭", comment: "Feedback status closed")
        case .unknown:
            return NSLocalizedString("未知状态", comment: "Feedback status unknown")
        }
    }
}

// MARK: - 环境快照

public struct FeedbackEnvironmentSnapshot: Codable, Hashable, Sendable {
    public let platform: String
    public let appVersion: String
    public let appBuild: String
    public let osVersion: String
    public let deviceModel: String
    public let localeIdentifier: String
    public let timezoneIdentifier: String

    public init(
        platform: String,
        appVersion: String,
        appBuild: String,
        osVersion: String,
        deviceModel: String,
        localeIdentifier: String,
        timezoneIdentifier: String
    ) {
        self.platform = platform
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.localeIdentifier = localeIdentifier
        self.timezoneIdentifier = timezoneIdentifier
    }
}

// MARK: - 提交草稿

public struct FeedbackDraft: Codable, Hashable, Sendable {
    public var category: FeedbackCategory
    public var title: String
    public var detail: String
    public var reproductionSteps: String?
    public var expectedBehavior: String?
    public var actualBehavior: String?
    public var extraContext: String?

    public init(
        category: FeedbackCategory,
        title: String,
        detail: String,
        reproductionSteps: String? = nil,
        expectedBehavior: String? = nil,
        actualBehavior: String? = nil,
        extraContext: String? = nil
    ) {
        self.category = category
        self.title = title
        self.detail = detail
        self.reproductionSteps = reproductionSteps
        self.expectedBehavior = expectedBehavior
        self.actualBehavior = actualBehavior
        self.extraContext = extraContext
    }

    public var sanitizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var sanitizedDetail: String {
        detail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isValid: Bool {
        !sanitizedTitle.isEmpty && !sanitizedDetail.isEmpty
    }
}

// MARK: - 评论与状态

public struct FeedbackComment: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let author: String
    public let body: String
    public let createdAt: Date
    public let isDeveloper: Bool

    public init(id: String, author: String, body: String, createdAt: Date, isDeveloper: Bool = false) {
        self.id = id
        self.author = author
        self.body = body
        self.createdAt = createdAt
        self.isDeveloper = isDeveloper
    }

    enum CodingKeys: String, CodingKey {
        case id
        case author
        case body
        case createdAt = "created_at"
        case isDeveloper = "is_developer"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let stringID = try? container.decode(String.self, forKey: .id) {
            id = stringID
        } else if let intID = try? container.decode(Int.self, forKey: .id) {
            id = String(intID)
        } else if let int64ID = try? container.decode(Int64.self, forKey: .id) {
            id = String(int64ID)
        } else {
            id = UUID().uuidString
        }

        author = try container.decode(String.self, forKey: .author)
        body = try container.decode(String.self, forKey: .body)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isDeveloper = try container.decodeIfPresent(Bool.self, forKey: .isDeveloper) ?? false
    }
}

public struct FeedbackStatusSnapshot: Codable, Hashable, Sendable {
    public let issueNumber: Int
    public let title: String
    public let status: FeedbackTicketStatus
    public let labels: [String]
    public let updatedAt: Date
    public let publicURL: URL?
    public let isClosed: Bool
    public let comments: [FeedbackComment]

    public init(
        issueNumber: Int,
        title: String,
        status: FeedbackTicketStatus,
        labels: [String],
        updatedAt: Date,
        publicURL: URL?,
        isClosed: Bool,
        comments: [FeedbackComment]
    ) {
        self.issueNumber = issueNumber
        self.title = title
        self.status = status
        self.labels = labels
        self.updatedAt = updatedAt
        self.publicURL = publicURL
        self.isClosed = isClosed
        self.comments = comments
    }
}

public struct FeedbackTicket: Codable, Hashable, Identifiable, Sendable {
    public var id: String { String(issueNumber) }
    public var issueNumber: Int
    public var ticketToken: String
    public var category: FeedbackCategory
    public var title: String
    public var createdAt: Date
    public var lastKnownStatus: FeedbackTicketStatus
    public var lastCheckedAt: Date?
    public var lastKnownUpdatedAt: Date?
    public var publicURL: URL?
    public var moderationBlocked: Bool?
    public var moderationMessage: String?
    public var archiveID: String?
    public var submittedTitle: String?
    public var submittedDetail: String?
    public var submittedReproductionSteps: String?
    public var submittedExpectedBehavior: String?
    public var submittedActualBehavior: String?
    public var submittedExtraContext: String?
    public var lastKnownCommentCount: Int?
    public var lastKnownDeveloperCommentID: String?
    public var lastKnownDeveloperCommentAt: Date?

    public init(
        issueNumber: Int,
        ticketToken: String,
        category: FeedbackCategory,
        title: String,
        createdAt: Date,
        lastKnownStatus: FeedbackTicketStatus,
        lastCheckedAt: Date? = nil,
        lastKnownUpdatedAt: Date? = nil,
        publicURL: URL? = nil,
        moderationBlocked: Bool? = nil,
        moderationMessage: String? = nil,
        archiveID: String? = nil,
        submittedTitle: String? = nil,
        submittedDetail: String? = nil,
        submittedReproductionSteps: String? = nil,
        submittedExpectedBehavior: String? = nil,
        submittedActualBehavior: String? = nil,
        submittedExtraContext: String? = nil,
        lastKnownCommentCount: Int? = nil,
        lastKnownDeveloperCommentID: String? = nil,
        lastKnownDeveloperCommentAt: Date? = nil
    ) {
        self.issueNumber = issueNumber
        self.ticketToken = ticketToken
        self.category = category
        self.title = title
        self.createdAt = createdAt
        self.lastKnownStatus = lastKnownStatus
        self.lastCheckedAt = lastCheckedAt
        self.lastKnownUpdatedAt = lastKnownUpdatedAt
        self.publicURL = publicURL
        self.moderationBlocked = moderationBlocked
        self.moderationMessage = moderationMessage
        self.archiveID = archiveID
        self.submittedTitle = submittedTitle
        self.submittedDetail = submittedDetail
        self.submittedReproductionSteps = submittedReproductionSteps
        self.submittedExpectedBehavior = submittedExpectedBehavior
        self.submittedActualBehavior = submittedActualBehavior
        self.submittedExtraContext = submittedExtraContext
        self.lastKnownCommentCount = lastKnownCommentCount
        self.lastKnownDeveloperCommentID = lastKnownDeveloperCommentID
        self.lastKnownDeveloperCommentAt = lastKnownDeveloperCommentAt
    }

    public func merged(with snapshot: FeedbackStatusSnapshot, checkedAt: Date = Date()) -> FeedbackTicket {
        var updated = self
        updated.title = snapshot.title
        updated.lastKnownStatus = snapshot.status
        updated.lastCheckedAt = checkedAt
        updated.lastKnownUpdatedAt = snapshot.updatedAt
        updated.publicURL = snapshot.publicURL
        updated.lastKnownCommentCount = snapshot.comments.count
        if let latestDeveloperComment = snapshot.comments
            .filter({ $0.isDeveloper })
            .max(by: { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.id < rhs.id
            }) {
            updated.lastKnownDeveloperCommentID = latestDeveloperComment.id
            updated.lastKnownDeveloperCommentAt = latestDeveloperComment.createdAt
        } else {
            updated.lastKnownDeveloperCommentID = nil
            updated.lastKnownDeveloperCommentAt = nil
        }
        return updated
    }
}

// MARK: - 状态映射与标签过滤

public enum FeedbackStatusMapper {
    public static func map(serverStatus: String?, labels: [String], isClosed: Bool) -> FeedbackTicketStatus {
        let normalizedStatus = serverStatus?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if isClosed || normalizedStatus == "closed" {
            return .closed
        }

        let loweredLabels = labels.map { $0.lowercased() }

        if loweredLabels.contains("status/triage") {
            return .triage
        }
        if loweredLabels.contains("status/in-progress") {
            return .inProgress
        }
        if loweredLabels.contains("status/blocked") {
            return .blocked
        }
        if loweredLabels.contains("status/resolved") {
            return .resolved
        }

        if let normalizedStatus {
            switch normalizedStatus {
            case "triage":
                return .triage
            case "in_progress", "in-progress", "inprogress", "processing", "open":
                return .inProgress
            case "blocked":
                return .blocked
            case "resolved", "done":
                return .resolved
            case "closed":
                return .closed
            default:
                break
            }
        }

        return .inProgress
    }
}

public enum FeedbackLabelFilter {
    private static let hiddenPrefixes: [String] = [
        "internal/",
        "security/",
        "meta/",
        "source/"
    ]

    public static func visibleLabels(from labels: [String]) -> [String] {
        labels.filter { label in
            let normalized = label.lowercased()
            return !hiddenPrefixes.contains { normalized.hasPrefix($0) }
        }
    }
}

// MARK: - 脱敏

public enum FeedbackTextSanitizer {
    private static let regexRules: [(pattern: String, template: String)] = [
        (#"(?i)(authorization\s*:\s*bearer\s+)[^\s]+"#, "$1***"),
        (#"(?i)(api[_-]?key\s*[=:]\s*)[^\s\",]+"#, "$1***"),
        (#"(?i)sk-[A-Za-z0-9]{12,}"#, "***"),
        (#"(?i)(x-api-key\s*:\s*)[^\s\",]+"#, "$1***")
    ]

    public static func redact(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }

        var output = raw
        for rule in regexRules {
            let pattern = rule.pattern
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let fullRange = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(
                in: output,
                options: [],
                range: fullRange,
                withTemplate: rule.template
            )
        }
        return output
    }
}

// MARK: - 日期编码

public enum FeedbackDateCodec {
    private static let parserWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let parserWithoutFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let encoderFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public static func decode(_ string: String) -> Date? {
        if let date = parserWithFractional.date(from: string) {
            return date
        }
        return parserWithoutFractional.date(from: string)
    }

    public static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = FeedbackDateCodec.decode(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "无法解析日期字段: \(value)"
            )
        }
        return decoder
    }

    public static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(encoderFormatter.string(from: date))
        }
        return encoder
    }
}

// MARK: - 签名辅助

public enum FeedbackSignature {
    public static func bodyHashHex(_ body: Data) -> String {
#if canImport(CryptoKit)
        let digest = SHA256.hash(data: body)
        return digest.map { String(format: "%02x", $0) }.joined()
#else
        return "\(body.count)"
#endif
    }

    public static func hmacSHA256Hex(message: String, secret: String) -> String {
#if canImport(CryptoKit)
        let key = SymmetricKey(data: Data(secret.utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(digest).map { String(format: "%02x", $0) }.joined()
#else
        return String(message.hashValue)
#endif
    }
}

// MARK: - PoW 辅助

public struct FeedbackPoWSolution: Sendable {
    public let nonce: String
    public let hashHex: String
    public let bits: Int

    public init(nonce: String, hashHex: String, bits: Int) {
        self.nonce = nonce
        self.hashHex = hashHex
        self.bits = bits
    }
}

public enum FeedbackProofOfWork {
    public static func solve(
        method: String,
        path: String,
        timestamp: String,
        bodyHashHex: String,
        challengeID: String,
        powSalt: String,
        bits: Int,
        maxIterations: Int = 4_000_000
    ) -> FeedbackPoWSolution? {
        guard bits > 0 else { return nil }
        guard maxIterations > 0 else { return nil }

#if canImport(CryptoKit)
        let upperMethod = method.uppercased()
        for counter in 0..<maxIterations {
            let nonce = String(counter, radix: 16, uppercase: false)
            let message = [
                upperMethod,
                path,
                timestamp,
                bodyHashHex,
                challengeID,
                powSalt,
                nonce,
            ].joined(separator: "\n")
            let digest = SHA256.hash(data: Data(message.utf8))
            if hasLeadingZeroBits(digest: digest, bits: bits) {
                let hashHex = digest.map { String(format: "%02x", $0) }.joined()
                return FeedbackPoWSolution(nonce: nonce, hashHex: hashHex, bits: bits)
            }
        }
#endif
        return nil
    }

#if canImport(CryptoKit)
    private static func hasLeadingZeroBits(digest: SHA256.Digest, bits: Int) -> Bool {
        var remainingBits = bits
        for byte in digest {
            if remainingBits <= 0 {
                return true
            }
            if remainingBits >= 8 {
                if byte != 0 {
                    return false
                }
                remainingBits -= 8
                continue
            }

            let shift = UInt8(8 - remainingBits)
            let mask = UInt8(0xFF) << shift
            return (byte & mask) == 0
        }
        return remainingBits <= 0
    }
#endif
}
