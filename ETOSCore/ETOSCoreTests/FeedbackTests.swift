// ============================================================================
// FeedbackTests.swift
// ============================================================================
// FeedbackTests 测试文件
// - 覆盖相关模块的行为与回归测试
// - 保障迭代过程中的稳定性
// ============================================================================

import Testing
import Foundation
@testable import ETOSCore

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

@Suite("FeedbackEnvironmentSnapshot Tests")
struct FeedbackEnvironmentSnapshotTests {
    @Test("环境快照可编码并保留 Git 提交哈希")
    func environmentSnapshotRoundTrip() throws {
        let snapshot = FeedbackEnvironmentSnapshot(
            platform: "iOS",
            appVersion: "1.2.3",
            appBuild: "456",
            gitCommitHash: "abcdef1234567890",
            distributionChannel: "testFlight",
            osVersion: "iOS 26.0",
            deviceModel: "iPhone17,1",
            localeIdentifier: "zh_Hans_CN",
            timezoneIdentifier: "Asia/Shanghai"
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(FeedbackEnvironmentSnapshot.self, from: data)

        #expect(decoded.gitCommitHash == "abcdef1234567890")
        #expect(decoded.distributionChannel == "testFlight")
        #expect(decoded.localizedDistributionChannel == "TestFlight")
        #expect(decoded.appBuild == "456")
        #expect(decoded.platform == "iOS")
    }
}

@Suite("FeedbackLaunchRefresh Tests")
struct FeedbackLaunchRefreshTests {
    @Test("启动自动刷新会跳过已关闭工单")
    func launchRefreshSkipsClosedTickets() {
        let triageTicket = FeedbackTicket(
            issueNumber: 1,
            ticketToken: "token-1",
            category: .bug,
            title: "处理中工单",
            createdAt: Date(timeIntervalSince1970: 1_730_000_000),
            lastKnownStatus: .triage
        )
        let closedTicket = FeedbackTicket(
            issueNumber: 2,
            ticketToken: "token-2",
            category: .bug,
            title: "已关闭工单",
            createdAt: Date(timeIntervalSince1970: 1_730_000_100),
            lastKnownStatus: .closed
        )

        let filtered = FeedbackService.ticketsForLaunchRefresh([triageTicket, closedTicket])

        #expect(filtered.count == 1)
        #expect(filtered.first?.issueNumber == 1)
    }
}

@Suite("FeedbackServiceConfig Tests")
struct FeedbackServiceConfigTests {
    @Test("反馈服务地址覆盖值会从配置存储读取")
    func defaultConfigReadsOverrideFromConfigStorage() {
        let suiteName = "FeedbackServiceConfigTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("无法创建测试专用 UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(" https://feedback.example.test ", forKey: AppConfigKey.feedbackAPIBaseURL.rawValue)

        let config = FeedbackServiceConfig.makeDefault(userDefaults: defaults)

        #expect(config.baseURL.absoluteString == "https://feedback.example.test")
    }
}

@Suite("FeedbackTicket Tests")
struct FeedbackTicketTests {
    @Test("审核字段可正常编码与解码")
    func moderationFieldsRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_730_000_000)
        let cachedComment = FeedbackComment(
            id: "comment-1",
            author: "YzmmQwQ",
            body: "API维护这一部分不是Eric本人在负责。",
            createdAt: now.addingTimeInterval(60),
            isDeveloper: false
        )
        let ticket = FeedbackTicket(
            issueNumber: 100,
            ticketToken: "token-abc",
            category: .bug,
            title: "测试标题",
            createdAt: now,
            lastKnownStatus: .blocked,
            lastCheckedAt: now,
            lastKnownUpdatedAt: now,
            publicURL: URL(string: "https://example.com/issues/100"),
            moderationBlocked: true,
            moderationMessage: "AI 审核暂时隐藏：包含不适合公开内容",
            archiveID: "archive-123",
            submittedTitle: "测试标题",
            submittedDetail: "这是我提交的详细描述",
            submittedReproductionSteps: "步骤 1 -> 步骤 2",
            submittedExpectedBehavior: "应当展示详情",
            submittedActualBehavior: "详情页未展示",
            submittedExtraContext: "仅在预览卡片可见",
            lastKnownCommentCount: 5,
            lastKnownDeveloperCommentID: "999",
            lastKnownDeveloperCommentAt: now,
            lastKnownComments: [cachedComment],
            lastKnownTimelineEvents: [.comment(cachedComment)]
        )

        let encoder = FeedbackDateCodec.makeJSONEncoder()
        let decoder = FeedbackDateCodec.makeJSONDecoder()
        let data = try encoder.encode([ticket])
        let decoded = try decoder.decode([FeedbackTicket].self, from: data)

        #expect(decoded.count == 1)
        #expect(decoded[0].moderationBlocked == true)
        #expect(decoded[0].moderationMessage == "AI 审核暂时隐藏：包含不适合公开内容")
        #expect(decoded[0].archiveID == "archive-123")
        #expect(decoded[0].submittedTitle == "测试标题")
        #expect(decoded[0].submittedDetail == "这是我提交的详细描述")
        #expect(decoded[0].submittedReproductionSteps == "步骤 1 -> 步骤 2")
        #expect(decoded[0].submittedExpectedBehavior == "应当展示详情")
        #expect(decoded[0].submittedActualBehavior == "详情页未展示")
        #expect(decoded[0].submittedExtraContext == "仅在预览卡片可见")
        #expect(decoded[0].lastKnownCommentCount == 5)
        #expect(decoded[0].lastKnownDeveloperCommentID == "999")
        #expect(decoded[0].lastKnownDeveloperCommentAt == now)
        #expect(decoded[0].lastKnownComments?.first?.author == "YzmmQwQ")
        #expect(decoded[0].lastKnownTimelineEvents?.count == 1)
    }

    @Test("兼容旧工单数据解码")
    func decodeLegacyTicketWithoutSubmittedFields() throws {
        let json = """
        [
          {
            "issueNumber": 42,
            "ticketToken": "legacy-token",
            "category": "bug",
            "title": "旧版本工单",
            "createdAt": "2026-03-29T00:00:00Z",
            "lastKnownStatus": "in_progress"
          }
        ]
        """

        let decoder = FeedbackDateCodec.makeJSONDecoder()
        let decoded = try decoder.decode([FeedbackTicket].self, from: Data(json.utf8))

        #expect(decoded.count == 1)
        #expect(decoded[0].submittedTitle == nil)
        #expect(decoded[0].submittedDetail == nil)
        #expect(decoded[0].submittedReproductionSteps == nil)
        #expect(decoded[0].submittedExpectedBehavior == nil)
        #expect(decoded[0].submittedActualBehavior == nil)
        #expect(decoded[0].submittedExtraContext == nil)
        #expect(decoded[0].lastKnownCommentCount == nil)
        #expect(decoded[0].lastKnownDeveloperCommentID == nil)
        #expect(decoded[0].lastKnownDeveloperCommentAt == nil)
        #expect(decoded[0].lastKnownComments == nil)
        #expect(decoded[0].lastKnownTimelineEvents == nil)
    }

    @Test("工单合并状态快照时会更新评论追踪标记")
    func mergedSnapshotUpdatesCommentMarkers() {
        let baseDate = Date(timeIntervalSince1970: 1_730_000_000)
        let ticket = FeedbackTicket(
            issueNumber: 77,
            ticketToken: "token-77",
            category: .bug,
            title: "旧标题",
            createdAt: baseDate,
            lastKnownStatus: .triage
        )

        let snapshot = FeedbackStatusSnapshot(
            issueNumber: 77,
            title: "新标题",
            status: .inProgress,
            labels: ["status/in-progress"],
            updatedAt: baseDate.addingTimeInterval(120),
            publicURL: URL(string: "https://example.com/issues/77"),
            isClosed: false,
            comments: [
                FeedbackComment(id: "1", author: "user", body: "我补充一下", createdAt: baseDate.addingTimeInterval(30), isDeveloper: false),
                FeedbackComment(id: "2", author: "dev", body: "已收到，我们在看。", createdAt: baseDate.addingTimeInterval(60), isDeveloper: true)
            ]
        )

        let merged = ticket.merged(with: snapshot, checkedAt: baseDate.addingTimeInterval(180))
        #expect(merged.title == "新标题")
        #expect(merged.lastKnownStatus == .inProgress)
        #expect(merged.lastKnownCommentCount == 2)
        #expect(merged.lastKnownDeveloperCommentID == "2")
        #expect(merged.lastKnownDeveloperCommentAt == baseDate.addingTimeInterval(60))
        #expect(merged.lastKnownComments?.count == 2)
        #expect(merged.lastKnownTimelineEvents?.count == 2)
    }
}

@Suite("FeedbackComment Tests")
struct FeedbackCommentTests {
    @Test("开发者标记字段可解码")
    func decodeDeveloperFlag() throws {
        let json = """
        {
          "id": "1",
          "author": "feedback-bot",
          "body": "测试评论",
          "created_at": "2026-03-29T00:00:00Z",
          "is_developer": true
        }
        """

        let decoder = FeedbackDateCodec.makeJSONDecoder()
        let comment = try decoder.decode(FeedbackComment.self, from: Data(json.utf8))
        #expect(comment.isDeveloper == true)
    }
}

@Suite("FeedbackTimelineEvent Tests")
struct FeedbackTimelineEventTests {
    @Test("状态响应可解码 referenced commit 动态")
    func decodeReferencedCommitTimelineEvent() throws {
        let json = """
        {
          "issue_number": 72,
          "status": "in_progress",
          "title": "模型选择问题",
          "updated_at": "2026-05-22T19:29:52Z",
          "labels": ["status/in-progress"],
          "public_url": "https://github.com/Eric-Terminal/ETOS-LLM-Studio/issues/72",
          "closed": false,
          "comments": [],
          "timeline_events": [
            {
              "id": "25865810670",
              "type": "referenced_commit",
              "actor": "Eric-Terminal",
              "created_at": "2026-05-22T19:10:01Z",
              "commit": {
                "sha": "9193ea1567e3e24051f6ce09de5b96a68dff87ee",
                "short_sha": "9193ea1",
                "message_headline": "fix(#72): 过滤对话模型选择中的专用模型",
                "message": "fix(#72): 过滤对话模型选择中的专用模型",
                "html_url": "https://github.com/Eric-Terminal/ETOS-LLM-Studio/commit/9193ea1567e3e24051f6ce09de5b96a68dff87ee",
                "committed_at": "2026-05-22T19:08:37Z",
                "verified": true
              }
            }
          ]
        }
        """

        let decoder = FeedbackDateCodec.makeJSONDecoder()
        let response = try decoder.decode(IssueStatusResponse.self, from: Data(json.utf8))
        let timelineEvents = response.timelineEvents.compactMap { $0.makeTimelineEvent() }

        #expect(timelineEvents.count == 1)
        guard case .referencedCommit(_, let actor, _, let commit) = timelineEvents[0] else {
            Issue.record("期望解码为 referenced commit 动态")
            return
        }
        #expect(actor == "Eric-Terminal")
        #expect(commit.displayShortSHA == "9193ea1")
        #expect(commit.verified)
    }
}
