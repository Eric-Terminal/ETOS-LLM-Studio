import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacDataImportTests {
    @Test("第三方只导入选中的类别，同时保留会话关联标签、音频、图片和来源")
    func selectedSessionsKeepTheirReferences() throws {
        let tag = SessionTag(name: "导入标签")
        let session = ChatSession(id: UUID(), name: "导入会话")
        let message = ChatMessage(role: .user, content: "附件", audioFileName: "voice.m4a", imageFileNames: ["photo.png"])
        let package = SyncPackage(options: [.providers, .sessions, .mcpServers], sourcePlatform: "OpenMinis",
            providers: [provider()], sessionTags: [tag], sessions: [SyncedSession(session: session, messages: [message])],
            mcpServers: [server()], audioFiles: [SyncedAudio(filename: "voice.m4a", data: Data([1]))],
            imageFiles: [SyncedImage(filename: "photo.png", data: Data([2]))])
        let result = try MacDataImportPreview.scopedPackage(prepared(package), selection: [.sessions, .appStorage])
        #expect(result.options == .sessions)
        #expect(result.providers.isEmpty && result.mcpServers.isEmpty && result.appStorageSnapshot == nil)
        #expect(result.sourcePlatform == "OpenMinis")
        #expect(result.sessions.first?.messages.first?.id == message.id)
        #expect(result.sessionTags.first?.id == tag.id)
        #expect(result.audioFiles.first?.filename == "voice.m4a")
        #expect(result.imageFiles.first?.filename == "photo.png")
    }

    @Test("取消会话范围也移除会话媒体和标签")
    func providerOnlyDoesNotLeakSessionPayloads() throws {
        let package = SyncPackage(options: [.providers, .sessions], providers: [provider()],
            sessionTags: [SessionTag(name: "私人")], sessions: [SyncedSession(session: ChatSession(id: UUID(), name: "私人"), messages: [])],
            imageFiles: [SyncedImage(filename: "secret.png", data: Data([3]))])
        let result = try MacDataImportPreview.scopedPackage(prepared(package), selection: [.providers])
        #expect(result.providers.count == 1)
        #expect(result.sessions.isEmpty && result.sessionTags.isEmpty && result.imageFiles.isEmpty)
    }

    @Test("旧 ETOS 包保留完整导出范围和设置，不套用第三方的四项筛选")
    func legacyPackagePreservesAllExportedOptions() throws {
        let package = SyncPackage(options: .fullSync, sourcePlatform: "watchOS", appStorageSnapshot: Data([7]), globalSystemPrompt: "原始提示词")
        let prepared = ThirdPartyImportPreparedResult(source: .etosBackup, package: package)
        let result = try MacDataImportPreview.scopedPackage(prepared, selection: [])
        #expect(result.options == .fullSync && result.sourcePlatform == "watchOS")
        #expect(result.appStorageSnapshot == package.appStorageSnapshot)
        #expect(result.globalSystemPrompt == "原始提示词")
        let preview = MacDataImportPreview(prepared: prepared)
        #expect(preview.fixedScope?.isEmpty == false)
        #expect(preview.requiresCredentialAcknowledgement(selection: []))
    }

    @Test("空范围、未导出的类别和无内容的选择不能进入合并")
    func invalidScopesAreRejected() {
        let item = prepared(SyncPackage(options: .sessions, providers: [provider()]))
        let selections: [Set<MacDataImportCategory>] = [[], [.providers], [.sessions], [.appStorage]]
        for selection in selections {
            #expect(throws: ThirdPartyImportError.self) { try MacDataImportPreview.scopedPackage(item, selection: selection) }
        }
    }

    @Test("凭据确认随实际范围变化，自定义头也视为可能携带凭据")
    func credentialsGateTracksSelectedScope() {
        let package = SyncPackage(options: [.providers, .sessions, .mcpServers], providers: [provider()],
            sessions: [SyncedSession(session: ChatSession(id: UUID(), name: "会话"), messages: [])], mcpServers: [server()])
        let preview = MacDataImportPreview(prepared: prepared(package))
        #expect(preview.requiresCredentialAcknowledgement(selection: [.providers]))
        #expect(preview.requiresCredentialAcknowledgement(selection: [.mcpServers]))
        #expect(!preview.requiresCredentialAcknowledgement(selection: [.sessions]))
        var headersOnly = provider(); headersOnly.apiKeys = []; headersOnly.headerOverrides = ["Authorization": "private"]
        let headerPreview = MacDataImportPreview(prepared: prepared(SyncPackage(options: .providers, providers: [headersOnly])))
        #expect(headerPreview.requiresCredentialAcknowledgement(selection: [.providers]))
    }

    @Test("OpenMinis 展示计数与降级提示，向导摘要不包含任何原始内容")
    func previewGuideContainsCountsOnly() {
        let item = ThirdPartyImportPreparedResult(source: .openMinis,
            package: SyncPackage(options: [.providers, .mcpServers], providers: [provider()], mcpServers: [server()]),
            warnings: ["private-warning"], recognizedSkillNames: ["private-skill"], containsSensitiveCredentials: true,
            parsedMessagesCount: 12, attachmentPlaceholderCount: 3, degradedItemCount: 2)
        let state = MacDataImportPreview(prepared: item, conflicts: MacDataImportConflicts(providers: 1, sessions: 0))
        #expect(state.rows.first(where: { $0.id == "messages" })?.value == "12")
        #expect(state.rows.first(where: { $0.id == "provider_adds" })?.value == "0")
        #expect(state.warnings.first?.title == "private-warning")
        #expect(state.skillNames.first?.title == "private-skill")
        guard case .dictionary(let fields) = state.guideCounts else { Issue.record("缺少计数快照"); return }
        #expect(fields["messages"] == .int(12) && fields["warnings"] == .int(1))
        for value in fields.values {
            guard case .int = value else { Issue.record("计数快照包含非数值内容"); continue }
        }
        #expect(state.scopeRows == [.providers, .mcpServers])
    }

    @Test("合并报告覆盖所有同步类别，包含隐式随会话导入的媒体")
    func reportUsesCompleteCoreSummary() {
        let summary = SyncMergeSummary(importedProviders: 1, importedSessions: 2, importedImageFiles: 3,
            importedFontFiles: 4, importedFontRouteConfigurations: 2, importedAppStorageValues: 5)
        let report = MacDataImportReport(summary: summary, options: .fullSync, warnings: ["保留提示"])
        #expect(Set(report.rows.map(\.id)) == Set(MacDataImportCategory.allCases.map(\.rawValue)))
        guard case .dictionary(let fields) = report.guideSummary else { Issue.record("缺少报告快照"); return }
        #expect(fields["fontFiles"] == .dictionary(["imported": .int(6), "skipped": .int(0)]))
        #expect(report.warnings.first?.title == "保留提示")
        let sessionsOnly = MacDataImportReport(summary: summary, options: .sessions)
        #expect(sessionsOnly.rows.contains { $0.id == "imageFiles" })
    }

    @Test("七类来源与双语文档明确最终原生确认、快照分流和 MCP 连接行为")
    func sourcesAndGuideBoundariesAreComplete() {
        #expect(ThirdPartyImportSource.allCases.count == 7)
        #expect(GuideDocumentCatalog.documents.contains { $0.id == "data-import" })
        let chinese = GuideDataImportKnowledge.document(locale: Locale(identifier: "zh_CN")).content
        let english = GuideDataImportKnowledge.document(locale: Locale(identifier: "en_US")).content
        #expect(chinese.contains("向导不能选文件") && chinese.contains(".elsbackup"))
        #expect(english.contains("cannot choose files") && english.contains("may start processes"))
    }

    @Test("已确认写入不随调用者取消，并阻止重入")
    @MainActor
    func acceptedWriteOutlivesCallerCancellation() async throws {
        let operations = MacDataImportOperations()
        let started = AsyncStream<Void>.makeStream(), release = AsyncStream<Void>.makeStream()
        let caller = Task {
            try await operations.perform {
                started.continuation.yield(())
                var iterator = release.stream.makeAsyncIterator()
                _ = await iterator.next()
                #expect(!Task.isCancelled)
                return SyncMergeSummary(importedSessions: 1)
            }
        }
        var start = started.stream.makeAsyncIterator()
        _ = await start.next()
        caller.cancel()
        do {
            _ = try await operations.perform { SyncMergeSummary.empty }
            Issue.record("并发导入没有被拒绝")
        } catch { #expect(error is MacMemoryWriteError) }
        release.continuation.yield(())
        await operations.waitForCompletion()
        let summary = try await caller.value
        #expect(summary?.importedSessions == 1)
    }

    @Test("数据库恢复排空仍在读取的预览，取消结果不会继续成为新预览")
    @MainActor
    func databaseBarrierCancelsAndDrainsPreview() async {
        let operations = MacDataImportOperations(), started = AsyncStream<Void>.makeStream()
        let worker = Task.detached {
            started.continuation.yield(())
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return 1
        }
        let id = operations.trackPreview(worker)
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        await operations.cancelAndWaitForPreviews()
        switch await worker.result {
        case .success: Issue.record("数据替换前的旧预览仍然成功")
        case .failure(let error): #expect(error is CancellationError)
        }
        operations.finishPreview(id)
    }

    private func prepared(_ package: SyncPackage) -> ThirdPartyImportPreparedResult {
        ThirdPartyImportPreparedResult(source: .openMinis, package: package, warnings: [])
    }

    private func provider() -> Provider {
        Provider(name: "private-provider", baseURL: "https://example.invalid/private", apiKeys: ["private-key"], apiFormat: "openai")
    }

    private func server() -> MCPServerConfiguration {
        MCPServerConfiguration(displayName: "private-server",
            transport: .http(endpoint: URL(string: "https://example.invalid/mcp")!, apiKey: "private-token", additionalHeaders: [:]))
    }
}
