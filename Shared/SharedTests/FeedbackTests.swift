// ============================================================================
// FeedbackTests.swift
// ============================================================================
// FeedbackTests 测试文件
// - 覆盖相关模块的行为与回归测试
// - 保障迭代过程中的稳定性
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("FeedbackStatusMapper Tests")
struct FeedbackStatusMapperTests {
    @Test("closed 状态优先于 status/* 标签")
    func closedHasPriority() {
        let mapped = FeedbackStatusMapper.map(
            serverStatus: "closed",
            labels: ["type/bug", "status/in-progress"],
            isClosed: true
        )

        #expect(mapped == .closed)
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

@Suite("FeedbackProofOfWork Tests")
struct FeedbackProofOfWorkTests {
    @Test("低难度 PoW 可求解")
    func lowDifficultyCanBeSolved() {
        let solution = FeedbackProofOfWork.solve(
            method: "POST",
            path: "/v1/feedback/issues",
            timestamp: "1730000000",
            bodyHashHex: String(repeating: "a", count: 64),
            challengeID: "challenge-demo",
            powSalt: "salt-demo",
            bits: 8,
            maxIterations: 100_000
        )
        #expect(solution != nil)
    }

    @Test("零难度 PoW 直接跳过")
    func zeroDifficultyReturnsNil() {
        let solution = FeedbackProofOfWork.solve(
            method: "POST",
            path: "/v1/feedback/issues",
            timestamp: "1730000000",
            bodyHashHex: String(repeating: "b", count: 64),
            challengeID: "challenge-demo",
            powSalt: "salt-demo",
            bits: 0
        )
        #expect(solution == nil)
    }
}

@Suite("FeedbackDraft Tests")
struct FeedbackDraftTests {
    @Test("标题与描述会先去空白再判断有效性")
    func draftValidationTrimsWhitespace() {
        let invalid = FeedbackDraft(
            category: .bug,
            title: "   \n\t  ",
            detail: "   "
        )
        let valid = FeedbackDraft(
            category: .suggestion,
            title: "  标题  ",
            detail: "\n 描述内容 \t"
        )

        #expect(!invalid.isValid)
        #expect(valid.isValid)
        #expect(valid.sanitizedTitle == "标题")
        #expect(valid.sanitizedDetail == "描述内容")
    }

    @Test("可选字段可完整写入草稿")
    func optionalFieldsAreStored() {
        let draft = FeedbackDraft(
            category: .bug,
            title: "标题",
            detail: "详情",
            reproductionSteps: "步骤1",
            expectedBehavior: "应当成功",
            actualBehavior: "实际失败",
            extraContext: "补充信息"
        )

        #expect(draft.reproductionSteps == "步骤1")
        #expect(draft.expectedBehavior == "应当成功")
        #expect(draft.actualBehavior == "实际失败")
        #expect(draft.extraContext == "补充信息")
    }
}
