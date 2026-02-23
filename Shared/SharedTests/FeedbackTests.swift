import Testing
import Foundation
@testable import Shared

@Suite("FeedbackStatusMapper Tests")
struct FeedbackStatusMapperTests {
    @Test("status/* 标签优先于 closed 状态")
    func statusLabelHasPriority() {
        let mapped = FeedbackStatusMapper.map(
            serverStatus: "closed",
            labels: ["type/bug", "status/in-progress"],
            isClosed: true
        )

        #expect(mapped == .inProgress)
    }

    @Test("无标签时回退到 open/closed")
    func fallbackToClosedFlag() {
        let openStatus = FeedbackStatusMapper.map(serverStatus: nil, labels: [], isClosed: false)
        let closedStatus = FeedbackStatusMapper.map(serverStatus: nil, labels: [], isClosed: true)

        #expect(openStatus == .inProgress)
        #expect(closedStatus == .closed)
    }

    @Test("服务端状态字段可直接映射")
    func serverStatusMapping() {
        let resolved = FeedbackStatusMapper.map(serverStatus: "resolved", labels: [], isClosed: false)
        let blocked = FeedbackStatusMapper.map(serverStatus: "blocked", labels: [], isClosed: false)

        #expect(resolved == .resolved)
        #expect(blocked == .blocked)
    }
}

@Suite("FeedbackTextSanitizer Tests")
struct FeedbackTextSanitizerTests {
    @Test("敏感字段会被脱敏")
    func redactSecrets() {
        let raw = "Authorization: Bearer sk-1234567890ABCDEFG api_key=abcd1234efgh5678"
        let sanitized = FeedbackTextSanitizer.redact(raw)

        #expect(!sanitized.contains("sk-1234567890ABCDEFG"))
        #expect(!sanitized.contains("abcd1234efgh5678"))
        #expect(sanitized.contains("***"))
    }
}

@Suite("FeedbackSignature Tests")
struct FeedbackSignatureTests {
    @Test("签名长度符合 SHA256 十六进制格式")
    func signatureLengthIsHex64() {
        let signature = FeedbackSignature.hmacSHA256Hex(message: "hello", secret: "world")

        #expect(signature.count == 64)
        #expect(signature.allSatisfy { $0.isHexDigit })
    }
}
