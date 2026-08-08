// ============================================================================
// BrowserAgentToolExecutor.swift
// ============================================================================
// ETOS LLM Studio
//
// Browser Agent 使用路由层注入的 session/run/tool 身份。每个操作都进入统一
// 任务表和取消作用域；跨域、脚本、截图与下载在真正执行前经过额外审批。
// ============================================================================

import Foundation

public actor BrowserAgentToolExecutor {
    public static let shared = BrowserAgentToolExecutor()

    private struct Arguments: Decodable, Sendable {
        let action: BrowserAgentAction
        let tab_id: String?
        let url: String?
        let element_index: Int?
        let text: String?
        let submit: Bool?
        let delta_x: Double?
        let delta_y: Double?
        let script: String?
        let filename: String?
    }

    private struct ActiveBrowserJob {
        var job: LocalLinuxJob
        let task: Task<String, Error>
    }

    private let contextManager: LocalAgentRuntimeContextManager
    private let scheduler: LocalLinuxJobScheduler
    private let storage: LocalLinuxStorageManager
    private let executorDeviceID: String
    private var activeJobs: [UUID: ActiveBrowserJob] = [:]
    private var suspensionInterruptedJobIDs: Set<UUID> = []

    public init(
        contextManager: LocalAgentRuntimeContextManager = .shared,
        scheduler: LocalLinuxJobScheduler = .shared,
        storage: LocalLinuxStorageManager = .shared,
        executorDeviceID: String = UsageAnalyticsRuntimeContext.currentDeviceIdentifier()
    ) {
        self.contextManager = contextManager
        self.scheduler = scheduler
        self.storage = storage
        self.executorDeviceID = executorDeviceID
    }

    public func execute(
        toolName: String,
        argumentsJSON: String,
        sessionID: UUID,
        runID: UUID,
        triggeringMessageID: UUID?,
        toolCallID: String,
        selectedMCPServerIDs: [UUID],
        allowCompanionDelegation: Bool = true
    ) async throws -> String {
        guard BrowserAgentToolDefinitions.contains(toolName) else {
            throw BrowserAgentError.invalidArguments(
                NSLocalizedString("未知的浏览器工具。", comment: "Unknown Browser Agent tool")
            )
        }
        let arguments: Arguments
        do {
            arguments = try JSONDecoder().decode(Arguments.self, from: Data(argumentsJSON.utf8))
        } catch {
            throw BrowserAgentError.invalidArguments(
                NSLocalizedString("无法解析浏览器工具参数。", comment: "Invalid Browser Agent arguments")
            )
        }

        #if os(watchOS)
        if allowCompanionDelegation,
           AppConfigStore.boolValue(for: .browserAgentDelegateToIPhone) {
            return try await BrowserAgentCompanionRelay.shared.execute(
                argumentsJSON: argumentsJSON,
                sessionID: sessionID,
                runID: runID,
                triggeringMessageID: triggeringMessageID,
                toolCallID: toolCallID,
                selectedMCPServerIDs: selectedMCPServerIDs
            )
        }
        #endif

        let frozen = try await contextManager.beginRun(
            sessionID: sessionID,
            triggeringMessageID: triggeringMessageID,
            toolCallID: toolCallID,
            runID: runID,
            selectedMCPServerIDs: selectedMCPServerIDs,
            browserSessionID: sessionID
        )
        let requestID = await scheduler.reserveRequestID()
        var job = LocalLinuxJob(
            requestID: requestID,
            kind: .browser,
            sessionID: sessionID,
            runID: runID,
            rootRunID: frozen.context.rootRunID,
            parentRunID: frozen.context.parentRunID,
            toolCallID: toolCallID,
            workspaceID: frozen.workspace.id,
            executorDeviceID: executorDeviceID,
            request: persistedRequest(for: arguments, workspace: frozen.workspace),
            state: .starting
        )
        job.startedAt = Date()
        guard Persistence.saveLocalLinuxJob(job) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法保存 Browser Agent 任务。", comment: "Save Browser Agent job failure")
            )
        }

        let task = Task<String, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.perform(
                arguments,
                sessionID: sessionID,
                context: frozen.context,
                workspace: frozen.workspace,
                toolCallID: toolCallID
            )
        }
        job.state = .running
        _ = Persistence.saveLocalLinuxJob(job)
        activeJobs[job.id] = ActiveBrowserJob(job: job, task: task)
        await scheduler.refreshActivityCounts()

        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard !task.isCancelled else { throw CancellationError() }
            await finish(jobID: job.id, state: .completed, reason: .exited, exitCode: 0)
            _ = try? await storage.refreshWorkspaceSize(frozen.workspace)
            return result
        } catch is CancellationError {
            let interrupted = suspensionInterruptedJobIDs.remove(job.id) != nil
            await finish(
                jobID: job.id,
                state: interrupted ? .interrupted : .cancelled,
                reason: interrupted ? .interruptedBySuspension : .cancelled,
                exitCode: nil
            )
            throw CancellationError()
        } catch {
            await finish(jobID: job.id, state: .failed, reason: .runtimeFailure, exitCode: nil)
            throw error
        }
    }

    public func cancel(jobID: UUID) {
        activeJobs[jobID]?.task.cancel()
    }

    public func cancel(runID: UUID) {
        activeJobs.values
            .filter { $0.job.runID == runID }
            .forEach { $0.task.cancel() }
    }

    public func cancel(sessionID: UUID) {
        activeJobs.values
            .filter { $0.job.sessionID == sessionID }
            .forEach { $0.task.cancel() }
    }

    public func cancelAll() {
        activeJobs.values.forEach { $0.task.cancel() }
    }

    public func interruptForSystemSuspension() -> Set<UUID> {
        let jobs = Array(activeJobs.values)
        suspensionInterruptedJobIDs.formUnion(jobs.map(\.job.id))
        jobs.forEach { $0.task.cancel() }
        return Set(jobs.compactMap(\.job.runID))
    }

    private func perform(
        _ arguments: Arguments,
        sessionID: UUID,
        context: AgentRuntimeContext,
        workspace: LocalAgentWorkspace,
        toolCallID: String
    ) async throws -> String {
        try Task.checkCancellation()
        let manager = await BrowserSessionManager.shared
        if arguments.action != .capabilities,
           arguments.action != .listTabs,
           await manager.isUserControlling(sessionID: sessionID) {
            throw BrowserAgentError.userTakeover
        }
        let allowedNavigationHosts = try await authorizeSensitiveBoundary(
            arguments,
            sessionID: sessionID,
            toolCallID: toolCallID,
            manager: manager,
            workspace: workspace
        )

        switch arguments.action {
        case .capabilities:
            let capabilities = await manager.capabilities()
            return encode(["capabilities": .dictionary(jsonObject(capabilities))])
        case .listTabs:
            let tabs = await manager.tabs(sessionID: sessionID)
            return encodeTabs(tabs)
        case .openTab:
            let url = try arguments.url.map(validatedURL)
            let tab = try await manager.openTab(
                sessionID: sessionID,
                url: url,
                dataProfile: context.browserDataProfile ?? .sessionIsolated,
                allowedAgentNavigationHosts: allowedNavigationHosts
            )
            return encodeTab(tab)
        case .navigate:
            let url = try requiredURL(arguments.url)
            let tab = try await manager.navigate(
                sessionID: sessionID,
                tabID: try tabID(arguments.tab_id),
                url: url,
                allowedAgentNavigationHosts: allowedNavigationHosts
            )
            return encodeTab(tab)
        case .snapshot:
            let snapshot = try await manager.snapshot(sessionID: sessionID, tabID: try tabID(arguments.tab_id))
            return encode(["snapshot": .dictionary(jsonObject(snapshot))])
        case .click:
            guard let index = arguments.element_index, index >= 0 else {
                throw BrowserAgentError.invalidArguments(
                    NSLocalizedString("click 需要非负的 element_index。", comment: "Browser Agent click missing element index")
                )
            }
            try await manager.click(
                sessionID: sessionID,
                tabID: try tabID(arguments.tab_id),
                elementIndex: index,
                allowedAgentNavigationHosts: allowedNavigationHosts
            )
            return encode(["clicked": .bool(true), "element_index": .int(index)])
        case .type:
            guard let index = arguments.element_index, index >= 0, let text = arguments.text else {
                throw BrowserAgentError.invalidArguments(
                    NSLocalizedString("type 需要 element_index 和 text。", comment: "Browser Agent type missing arguments")
                )
            }
            try await manager.type(
                sessionID: sessionID,
                tabID: try tabID(arguments.tab_id),
                elementIndex: index,
                text: text,
                submit: arguments.submit ?? false,
                allowedAgentNavigationHosts: allowedNavigationHosts
            )
            return encode(["typed": .bool(true), "element_index": .int(index), "submitted": .bool(arguments.submit ?? false)])
        case .scroll:
            let deltaX = arguments.delta_x ?? 0
            let deltaY = arguments.delta_y ?? 0
            try await manager.scroll(
                sessionID: sessionID,
                tabID: try tabID(arguments.tab_id),
                deltaX: deltaX,
                deltaY: deltaY
            )
            return encode(["scrolled": .bool(true), "delta_x": .double(deltaX), "delta_y": .double(deltaY)])
        case .evaluateJavaScript:
            guard let script = arguments.script, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BrowserAgentError.invalidArguments(
                    NSLocalizedString("evaluate_javascript 需要 script。", comment: "Browser Agent JavaScript missing script")
                )
            }
            let result = try await manager.evaluateJavaScript(
                sessionID: sessionID,
                tabID: try tabID(arguments.tab_id),
                script: script,
                allowedAgentNavigationHosts: allowedNavigationHosts
            )
            return encode(["result": result])
        case .screenshot:
            #if canImport(WebKit) && canImport(UIKit) && !os(watchOS)
            let url = try await manager.screenshot(sessionID: sessionID, tabID: try tabID(arguments.tab_id))
            return encode(["path": .string(appPath(for: url))])
            #else
            throw BrowserAgentError.unsupported(
                NSLocalizedString("本机截图；可在设置中启用 iPhone 委托。", comment: "Browser Agent watch screenshot unsupported")
            )
            #endif
        case .download:
            #if canImport(WebKit) && canImport(UIKit) && !os(watchOS)
            let url = try requiredURL(arguments.url)
            let directory = try await storage.browserDownloadDirectory(for: workspace)
            let destination = try await manager.download(
                sessionID: sessionID,
                tabID: try tabID(arguments.tab_id),
                url: url,
                filename: arguments.filename,
                destinationDirectory: directory
            )
            return encode(["path": .string(try await storage.guestURI(forHostURL: destination, workspace: workspace))])
            #else
            throw BrowserAgentError.unsupported(
                NSLocalizedString("本机下载；可在设置中启用 iPhone 委托。", comment: "Browser Agent watch download unsupported")
            )
            #endif
        case .closeTab:
            let tab = try await manager.closeTab(sessionID: sessionID, tabID: try tabID(arguments.tab_id))
            return encode(["closed_tab": .dictionary(jsonObject(tab))])
        }
    }

    private func authorizeSensitiveBoundary(
        _ arguments: Arguments,
        sessionID: UUID,
        toolCallID: String,
        manager: BrowserSessionManager,
        workspace: LocalAgentWorkspace
    ) async throws -> Set<String> {
        let selectedTabID = try tabID(arguments.tab_id)
        let currentURL = try? await manager.currentURL(sessionID: sessionID, tabID: selectedTabID)
        var allowedHosts = Set<String>()

        switch arguments.action {
        case .openTab:
            if let target = try arguments.url.map(validatedURL) {
                try await requestPermission(
                    kind: "domain",
                    targetURL: target,
                    sourceURL: nil,
                    sessionID: sessionID,
                    toolCallID: toolCallID
                )
                if let host = host(of: target) { allowedHosts.insert(host) }
            }
        case .navigate:
            let target = try requiredURL(arguments.url)
            if host(of: currentURL ?? nil) != host(of: target) {
                try await requestPermission(
                    kind: "domain",
                    targetURL: target,
                    sourceURL: currentURL ?? nil,
                    sessionID: sessionID,
                    toolCallID: toolCallID
                )
            }
            if let host = host(of: target) { allowedHosts.insert(host) }
        case .click:
            if let index = arguments.element_index,
               let target = try await manager.interactionDestination(
                    sessionID: sessionID,
                    tabID: selectedTabID,
                    elementIndex: index,
                    submittingForm: false
               ), host(of: currentURL ?? nil) != host(of: target) {
                try await requestPermission(
                    kind: "domain",
                    targetURL: target,
                    sourceURL: currentURL ?? nil,
                    sessionID: sessionID,
                    toolCallID: toolCallID
                )
                if let host = host(of: target) { allowedHosts.insert(host) }
            }
        case .type where arguments.submit == true:
            if let index = arguments.element_index,
               let target = try await manager.interactionDestination(
                    sessionID: sessionID,
                    tabID: selectedTabID,
                    elementIndex: index,
                    submittingForm: true
               ), host(of: currentURL ?? nil) != host(of: target) {
                try await requestPermission(
                    kind: "domain",
                    targetURL: target,
                    sourceURL: currentURL ?? nil,
                    sessionID: sessionID,
                    toolCallID: toolCallID
                )
                if let host = host(of: target) { allowedHosts.insert(host) }
            }
        case .evaluateJavaScript:
            try await requestPermission(
                kind: "javascript",
                targetURL: currentURL ?? nil,
                sourceURL: currentURL ?? nil,
                sessionID: sessionID,
                toolCallID: toolCallID
            )
        case .screenshot:
            try await requestPermission(
                kind: "screenshot",
                targetURL: currentURL ?? nil,
                sourceURL: currentURL ?? nil,
                sessionID: sessionID,
                toolCallID: toolCallID
            )
        case .download:
            try await requestPermission(
                kind: "download",
                targetURL: try requiredURL(arguments.url),
                sourceURL: currentURL ?? nil,
                sessionID: sessionID,
                toolCallID: toolCallID,
                destination: workspace.guestPath + "/BrowserDownloads/"
            )
        case .capabilities, .listTabs, .snapshot, .scroll, .type, .closeTab:
            break
        }
        return allowedHosts
    }

    private func requestPermission(
        kind: String,
        targetURL: URL?,
        sourceURL: URL?,
        sessionID: UUID,
        toolCallID: String,
        destination: String? = nil
    ) async throws {
        let targetHost = host(of: targetURL) ?? NSLocalizedString("未知域名", comment: "Unknown Browser Agent host")
        let displayName: String
        switch kind {
        case "javascript":
            displayName = String(
                format: NSLocalizedString("Browser Agent：在 %@ 执行 JavaScript", comment: "Browser Agent JavaScript approval title"),
                targetHost
            )
        case "screenshot":
            displayName = String(
                format: NSLocalizedString("Browser Agent：截取 %@", comment: "Browser Agent screenshot approval title"),
                targetHost
            )
        case "download":
            displayName = String(
                format: NSLocalizedString("Browser Agent：从 %@ 下载到 %@", comment: "Browser Agent download approval title"),
                targetHost,
                destination ?? ""
            )
        default:
            displayName = String(
                format: NSLocalizedString("Browser Agent：访问 %@", comment: "Browser Agent domain approval title"),
                targetHost
            )
        }
        var detailValues: [String: JSONValue] = [
            "operation": .string(kind),
            "source_domain": .string(host(of: sourceURL) ?? ""),
            "target_domain": .string(targetHost)
        ]
        if let destination {
            detailValues["destination"] = .string(destination)
        }
        let details = encode(detailValues)
        let decision = await ToolPermissionCenter.shared.requestPermission(
            toolName: "browser_agent.\(kind).\(targetHost.lowercased())",
            displayName: displayName,
            arguments: details,
            sourceSessionID: sessionID,
            toolCallID: toolCallID
        )
        switch decision {
        case .allowOnce, .allowForTool, .allowAll:
            return
        case .deny, .supplement:
            throw BrowserAgentError.permissionDenied
        }
    }

    private func persistedRequest(
        for arguments: Arguments,
        workspace: LocalAgentWorkspace
    ) -> LocalLinuxJobRequest {
        var summary = [arguments.action.rawValue]
        if let rawURL = arguments.url,
           let url = URL(string: rawURL),
           let host = host(of: url) {
            summary.append(host)
        }
        return LocalLinuxJobRequest(
            executable: BrowserAgentToolDefinitions.toolName,
            arguments: summary,
            workingDirectory: workspace.guestPath
        )
    }

    private func finish(
        jobID: UUID,
        state: LocalLinuxJobState,
        reason: LocalLinuxCompletionReason,
        exitCode: Int32?
    ) async {
        guard var active = activeJobs.removeValue(forKey: jobID) else { return }
        active.job.state = state
        active.job.completionReason = reason
        active.job.exitCode = exitCode
        active.job.finishedAt = Date()
        _ = Persistence.saveLocalLinuxJob(active.job)
        await scheduler.refreshActivityCounts()
    }

    private func tabID(_ rawValue: String?) throws -> UUID? {
        guard let rawValue else { return nil }
        guard let id = UUID(uuidString: rawValue) else {
            throw BrowserAgentError.invalidArguments(
                NSLocalizedString("tab_id 不是有效的 UUID。", comment: "Browser Agent invalid tab ID")
            )
        }
        return id
    }

    private func requiredURL(_ rawValue: String?) throws -> URL {
        guard let rawValue else {
            throw BrowserAgentError.invalidArguments(
                NSLocalizedString("该操作需要 url。", comment: "Browser Agent missing URL")
            )
        }
        return try validatedURL(rawValue)
    }

    private func validatedURL(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            throw BrowserAgentError.invalidArguments(
                NSLocalizedString("url 必须是完整的 http 或 https 地址。", comment: "Browser Agent malformed URL")
            )
        }
        return url
    }

    private func host(of url: URL?) -> String? {
        url?.host?.lowercased()
    }

    private func encodeTabs(_ tabs: [BrowserAgentTabSummary]) -> String {
        encode(["tabs": .array(tabs.map { .dictionary(jsonObject($0)) })])
    }

    private func encodeTab(_ tab: BrowserAgentTabSummary) -> String {
        encode(["tab": .dictionary(jsonObject(tab))])
    }

    private func encode(_ dictionary: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(dictionary),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private func jsonObject<T: Encodable>(_ value: T) -> [String: JSONValue] {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return [:] }
        return object
    }

    private func appPath(for url: URL) -> String {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let documents,
              url.path.hasPrefix(documents.path + "/") else { return url.path }
        return "app://" + String(url.path.dropFirst(documents.path.count + 1))
    }
}
