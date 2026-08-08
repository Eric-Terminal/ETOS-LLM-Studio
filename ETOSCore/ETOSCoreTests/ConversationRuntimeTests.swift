// ============================================================================
// ConversationRuntimeTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 覆盖长期会话协作的上下文分叉、等待环、关系授权、持久邮箱、预算、
// 请求配置固化、消息来源以及并发流式写入合并语义。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("长期会话协作运行时测试")
struct ConversationRuntimeTests {
    @Test("提示词继承、追加和替换保持确定语义")
    func resolvesPromptInheritanceModes() {
        #expect(
            ConversationContextForkBuilder.resolvedPrompt(
                inherited: "父提示词",
                provided: "子提示词",
                mode: .inherit
            ) == "父提示词"
        )
        #expect(
            ConversationContextForkBuilder.resolvedPrompt(
                inherited: "父提示词",
                provided: "子提示词",
                mode: .append
            ) == "父提示词\n\n子提示词"
        )
        #expect(
            ConversationContextForkBuilder.resolvedPrompt(
                inherited: "父提示词",
                provided: "子提示词",
                mode: .replace
            ) == "子提示词"
        )
        #expect(
            ConversationContextForkBuilder.resolvedPrompt(
                inherited: "父提示词",
                provided: "   ",
                mode: .append
            ) == "父提示词"
        )
    }

    @Test("new、完整分叉和最近轮次分叉不会复制未闭合工具调用")
    func forksOnlyCompleteConversationContext() {
        let firstUser = ChatMessage(role: .user, content: "第一问")
        let firstAssistant = ChatMessage(
            role: .assistant,
            content: "第一答",
            responseGroupID: firstUser.id
        )
        let secondUser = ChatMessage(role: .user, content: "第二问")
        let secondAssistant = ChatMessage(role: .assistant, content: "第二答")
        let unfinishedToolMessage = ChatMessage(
            role: .assistant,
            content: "",
            toolCalls: [
                InternalToolCall(
                    id: "unfinished",
                    toolName: ConversationToolName.listConversations.rawValue,
                    arguments: "{}"
                )
            ]
        )
        let source = [
            firstUser,
            firstAssistant,
            secondUser,
            secondAssistant,
            unfinishedToolMessage
        ]

        #expect(
            ConversationContextForkBuilder.messages(
                from: source,
                mode: .new,
                recentRoundCount: nil
            ).isEmpty
        )

        let all = ConversationContextForkBuilder.messages(
            from: source,
            mode: .forkAll,
            recentRoundCount: nil
        )
        #expect(all.count == 4)
        #expect(all.map(\.content) == ["第一问", "第一答", "第二问", "第二答"])
        #expect(all.map(\.sourceMessageID) == source.prefix(4).map(\.id))
        #expect(zip(all, source).allSatisfy { pair in pair.0.id != pair.1.id })
        #expect(all[1].responseGroupID == all[0].id)

        let recent = ConversationContextForkBuilder.messages(
            from: source,
            mode: .forkRecent,
            recentRoundCount: 1
        )
        #expect(recent.map(\.content) == ["第二问", "第二答"])

        let selected = ConversationContextForkBuilder.selectedMessages(
            from: source,
            mode: .forkRecent,
            recentRoundCount: 1
        )
        #expect(selected.map(\.id) == [secondUser.id, secondAssistant.id])

        let earlierUnfinishedToolMessage = ChatMessage(
            role: .assistant,
            content: "",
            toolCalls: [
                InternalToolCall(
                    id: "unfinished_earlier",
                    toolName: ConversationToolName.listConversations.rawValue,
                    arguments: "{}"
                )
            ]
        )
        let historyAfterUnfinishedCall = [
            firstUser,
            earlierUnfinishedToolMessage,
            secondUser,
            secondAssistant,
            unfinishedToolMessage
        ]
        let safePrefix = ConversationContextForkBuilder.messages(
            from: historyAfterUnfinishedCall,
            mode: .forkAll,
            recentRoundCount: nil
        )
        #expect(safePrefix.map(\.content) == ["第一问"])
    }

    @Test("等待图允许任意深度，但拒绝同步等待环")
    func detectsWaitCyclesWithoutDepthLimit() {
        let runA = UUID()
        let runB = UUID()
        let runC = UUID()
        let runD = UUID()
        let edges = [
            (waitingRunID: runA, targetRunID: runB),
            (waitingRunID: runB, targetRunID: runC)
        ]

        #expect(
            !ConversationWaitGraph.wouldCreateCycle(
                waitingRunID: runC,
                targetRunID: runD,
                existingEdges: edges
            )
        )
        #expect(
            ConversationWaitGraph.wouldCreateCycle(
                waitingRunID: runC,
                targetRunID: runA,
                existingEdges: edges
            )
        )
        #expect(
            ConversationWaitGraph.wouldCreateCycle(
                waitingRunID: runA,
                targetRunID: runA,
                existingEdges: []
            )
        )
    }

    @Test("会话工具目录完整且名称唯一")
    func exposesCompleteConversationToolCatalog() {
        let names = ConversationToolDefinitions.all.map(\.name)
        #expect(Set(names) == Set(ConversationToolName.allCases.map(\.rawValue)))
        #expect(names.count == Set(names).count)
        #expect(names.contains(ConversationToolName.listAvailableModels.rawValue))
    }

    @Test("模型目录不进入创建工具 Schema，隐藏子代理默认开启且列表工具声明受限 max")
    func keepsDynamicModelCatalogOutOfToolSchema() throws {
        let toolsByName = Dictionary(
            uniqueKeysWithValues: ConversationToolDefinitions.all.map { ($0.name, $0) }
        )
        guard let createTool = toolsByName[ConversationToolName.createConversation.rawValue],
              case .dictionary(let createSchema) = createTool.parameters,
              case .dictionary(let createProperties)? = createSchema["properties"],
              case .dictionary(let modelIdentifierSchema)? = createProperties["model_identifier"] else {
            Issue.record("创建会话工具应声明 model_identifier 字符串参数。")
            return
        }
        #expect(modelIdentifierSchema["type"] == .string("string"))
        #expect(modelIdentifierSchema["enum"] == nil)
        guard case .dictionary(let hiddenSchema)? = createProperties["hidden"] else {
            Issue.record("创建会话工具应声明 hidden 参数。")
            return
        }
        #expect(hiddenSchema["type"] == .string("boolean"))
        #expect(hiddenSchema["default"] == .bool(true))

        let defaultArguments = try JSONDecoder().decode(
            CreateConversationToolArguments.self,
            from: Data(#"{"initial_message":"任务","context_mode":"new","execution_mode":"background"}"#.utf8)
        )
        let visibleArguments = try JSONDecoder().decode(
            CreateConversationToolArguments.self,
            from: Data(#"{"initial_message":"任务","context_mode":"new","execution_mode":"background","hidden":false}"#.utf8)
        )
        #expect(defaultArguments.hidesConversation)
        #expect(!visibleArguments.hidesConversation)

        for toolName in [ConversationToolName.listConversations, .listAvailableModels] {
            guard let tool = toolsByName[toolName.rawValue],
                  case .dictionary(let schema) = tool.parameters,
                  case .dictionary(let properties)? = schema["properties"],
                  case .dictionary(let maxSchema)? = properties["max"] else {
                Issue.record("\(toolName.rawValue) 应声明 max 参数。")
                continue
            }
            #expect(maxSchema["minimum"] == .int(ConversationToolListLimit.minimum))
            #expect(maxSchema["maximum"] == .int(ConversationToolListLimit.maximum))
        }
    }

    @Test("可见子代理与主会话会原子归入确定性文件夹")
    func groupsVisibleSubagentConversationAtomically() throws {
        try withStore { store in
            let outerFolder = SessionFolder(name: "已有项目")
            var parent = ChatSession(
                id: UUID(),
                name: "主任务",
                folderID: outerFolder.id,
                isTemporary: false
            )
            store.saveSessionFolders([outerFolder])
            store.saveChatSessions([parent])

            let groupFolder = SessionFolder(
                id: parent.id,
                name: parent.name,
                parentID: outerFolder.id,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let child = ChatSession(
                id: UUID(),
                name: "可见子代理",
                folderID: groupFolder.id,
                isTemporary: false
            )
            try store.createConversationRuntimeBundle(
                targetSession: child,
                groupingFolder: groupFolder,
                groupingRootSessionID: parent.id,
                origin: nil,
                capabilities: [],
                targetRun: nil,
                event: nil,
                delegation: nil,
                waits: [],
                waitingRunID: nil
            )

            let sessionsByID = Dictionary(uniqueKeysWithValues: store.loadChatSessions().map { ($0.id, $0) })
            #expect(sessionsByID[parent.id]?.folderID == groupFolder.id)
            #expect(sessionsByID[child.id]?.folderID == groupFolder.id)
            let persistedGroup = try #require(store.loadSessionFolders().first(where: { $0.id == groupFolder.id }))
            #expect(persistedGroup.name == parent.name)
            #expect(persistedGroup.parentID == outerFolder.id)

            parent.folderID = groupFolder.id
            store.saveChatSessions([parent, child])
            #expect(store.loadChatSessions().count == 2)
        }
    }

    @Test("隐藏子代理不进入普通列表并随主会话级联删除")
    func embedsHiddenSubagentAndCascadesDeletion() throws {
        try withStore { store in
            let parent = ChatSession(id: UUID(), name: "主会话", isTemporary: false)
            store.saveChatSessions([parent])
            let hidden = ChatSession(
                id: UUID(),
                name: "隐藏子代理",
                containerSessionID: parent.id,
                isTemporary: false
            )
            let hiddenMessage = ChatMessage(role: .user, content: "内部任务记录")
            let capability = ConversationCapability(
                sourceSessionID: parent.id,
                targetSessionID: hidden.id,
                relation: .created,
                canRead: true,
                canSend: true,
                canTriggerReply: true,
                canInterrupt: true
            )
            try store.createConversationRuntimeBundle(
                targetSession: hidden,
                targetMessages: [hiddenMessage],
                origin: ConversationOrigin(
                    childSessionID: hidden.id,
                    parentSessionID: parent.id,
                    parentSessionNameSnapshot: parent.name,
                    contextMode: .new
                ),
                capabilities: [capability],
                targetRun: nil,
                event: nil,
                delegation: nil,
                waits: [],
                waitingRunID: nil
            )

            #expect(store.loadChatSessions().map(\.id) == [parent.id])
            #expect(store.loadChatSession(id: hidden.id)?.containerSessionID == parent.id)
            #expect(store.loadEmbeddedSubagentSessionIDs(containerSessionID: parent.id) == [hidden.id])
            #expect(try store.loadLinkedConversationContacts(sourceSessionID: parent.id).first?.isEmbeddedSubagent == true)

            // 普通列表快照保存不得把未包含在列表里的隐藏记录误删。
            store.saveChatSessions([parent])
            #expect(store.loadMessages(for: hidden.id).map(\.content) == ["内部任务记录"])

            store.deleteSessionArtifacts(sessionID: parent.id)
            #expect(store.loadChatSession(id: hidden.id) == nil)
            #expect(store.loadMessages(for: hidden.id).isEmpty)
        }
    }

    @Test("列表上限与同模型选择语义保持确定")
    func resolvesListLimitsAndSelfModelSelection() throws {
        #expect(try ConversationToolListLimit.resolve(nil) == 20)
        #expect(try ConversationToolListLimit.resolve(1) == 1)
        #expect(try ConversationToolListLimit.resolve(200) == 200)
        #expect(throws: ConversationRuntimeError.self) {
            try ConversationToolListLimit.resolve(0)
        }
        #expect(throws: ConversationRuntimeError.self) {
            try ConversationToolListLimit.resolve(201)
        }

        #expect(ConversationToolModelSelection.explicitIdentifier(from: nil) == nil)
        #expect(ConversationToolModelSelection.explicitIdentifier(from: "   ") == nil)
        #expect(ConversationToolModelSelection.explicitIdentifier(from: "SELF") == nil)
        #expect(ConversationToolModelSelection.explicitIdentifier(from: " model-id ") == "model-id")
    }

    @Test("MCP 可读别名仍可识别为会话工具")
    func recognizesMCPConversationToolAliases() {
        #expect(ConversationToolDefinitions.containsExposedName("mcp_create_conversation"))
        #expect(ConversationToolDefinitions.containsExposedName("mcp_server_45544f53_list_conversations"))
        #expect(
            ConversationToolDefinitions.containsExposedName(
                "mcp://45544F53-0000-0000-0000-4150544C0007/read_conversation"
            )
        )
        #expect(!ConversationToolDefinitions.containsExposedName("mcp_unrelated_tool"))
    }

    @Test("会话工具卡可以从参数和结果恢复目标会话")
    func resolvesConversationToolPresentationTargets() {
        let firstID = UUID()
        let secondID = UUID()
        let sendCall = InternalToolCall(
            id: "call_send",
            toolName: "mcp_\(ConversationToolName.sendMessage.rawValue)",
            arguments: "{\"conversation_id\":\"\(firstID.uuidString)\",\"message\":\"你好\"}",
            result: "{\"conversation_id\":\"\(firstID.uuidString)\",\"status\":\"queued\"}"
        )
        #expect(ConversationToolPresentationLoader.targetSessionIDs(for: sendCall) == [firstID])

        let waitCall = InternalToolCall(
            id: "call_wait",
            toolName: ConversationToolName.waitForConversations.rawValue,
            arguments: "{\"conversation_ids\":[\"\(firstID.uuidString)\",\"\(secondID.uuidString)\"],\"mode\":\"all\"}"
        )
        #expect(
            ConversationToolPresentationLoader.targetSessionIDs(for: waitCall) == [firstID, secondID]
        )
    }

    @Test("来源、双向授权和撤销状态持久化")
    func persistsOriginsCapabilitiesAndRevocation() throws {
        try withStore { store in
            let parent = ChatSession(id: UUID(), name: "父会话", isTemporary: false)
            let child = ChatSession(id: UUID(), name: "子会话", isTemporary: false)
            store.saveChatSessions([parent, child])

            let origin = ConversationOrigin(
                childSessionID: child.id,
                parentSessionID: parent.id,
                parentSessionNameSnapshot: parent.name,
                contextMode: .forkAll,
                // SQLite 使用 Unix 时间戳存储日期；固定到可精确往返的秒值，
                // 避免 Date() 的亚微秒尾数在不同测试组合中造成相等性抖动。
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            try store.upsertConversationOrigin(origin)
            try store.upsertConversationCapability(
                ConversationCapability(
                    sourceSessionID: parent.id,
                    targetSessionID: child.id,
                    relation: .created,
                    canRead: true,
                    canSend: true,
                    canTriggerReply: true,
                    canInterrupt: true
                )
            )
            try store.upsertConversationCapability(
                ConversationCapability(
                    sourceSessionID: child.id,
                    targetSessionID: parent.id,
                    relation: .parent,
                    canRead: false,
                    canSend: true,
                    canTriggerReply: false,
                    canInterrupt: false
                )
            )

            #expect(try store.loadConversationOrigin(childSessionID: child.id) == origin)
            let parentContacts = try store.loadLinkedConversationContacts(sourceSessionID: parent.id)
            #expect(parentContacts.map(\.sessionID) == [child.id])
            #expect(parentContacts.first?.canInterrupt == true)
            let childContacts = try store.loadLinkedConversationContacts(sourceSessionID: child.id)
            #expect(childContacts.first?.canSend == true)
            #expect(childContacts.first?.canRead == false)

            try store.revokeConversationCapability(
                sourceSessionID: parent.id,
                targetSessionID: child.id,
                revokedAt: Date()
            )
            #expect(try store.loadLinkedConversationContacts(sourceSessionID: parent.id).isEmpty)
            #expect(
                try store.loadConversationCapability(
                    sourceSessionID: parent.id,
                    targetSessionID: child.id
                )?.revokedAt != nil
            )

            store.deleteSessionArtifacts(sessionID: parent.id)
            let orphanedOrigin = try #require(
                try store.loadConversationOrigin(childSessionID: child.id)
            )
            #expect(orphanedOrigin.parentSessionID == nil)
            #expect(orphanedOrigin.parentSessionNameSnapshot == "父会话")
        }
    }

    @Test("运行时关系、Run、Event、Delegation 与 Wait 同事务回滚")
    func rollsBackIncompleteRuntimeBundle() throws {
        try withStore { store in
            let parent = ChatSession(id: UUID(), name: "事务父会话", isTemporary: false)
            let child = ChatSession(id: UUID(), name: "事务子会话", isTemporary: false)
            store.saveChatSessions([parent])
            let childMessage = ChatMessage(role: .user, content: "事务初始消息")
            let sourceRun = ConversationRun(
                sessionID: parent.id,
                status: .running,
                requestConfiguration: ConversationRunRequestConfiguration()
            )
            try store.upsertConversationRun(sourceRun)
            let targetRun = ConversationRun(
                sessionID: child.id,
                rootRunID: sourceRun.rootRunID,
                parentRunID: sourceRun.id,
                status: .queued,
                requestConfiguration: ConversationRunRequestConfiguration()
            )
            let origin = ConversationOrigin(
                childSessionID: child.id,
                parentSessionID: parent.id,
                parentSessionNameSnapshot: parent.name,
                contextMode: .new
            )
            let capability = ConversationCapability(
                sourceSessionID: parent.id,
                targetSessionID: child.id,
                relation: .created,
                canRead: true,
                canSend: true,
                canTriggerReply: true,
                canInterrupt: true
            )
            let wait = ConversationWait(
                waitGroupID: UUID(),
                waitingRunID: sourceRun.id,
                targetSessionID: child.id,
                targetRunID: targetRun.id,
                toolCallID: "call_atomic",
                completionMode: .all
            )
            let invalidDestinationID = UUID()
            let invalidEvent = ConversationEvent(
                destinationSessionID: invalidDestinationID,
                kind: .incomingMessage,
                deliveryPolicy: .respondWhenIdle
            )
            let delegation = ConversationDelegation(
                sourceSessionID: parent.id,
                targetSessionID: child.id,
                sourceRunID: sourceRun.id,
                targetRunID: targetRun.id,
                requestMessageID: childMessage.id,
                toolCallID: "call_atomic",
                executionMode: .awaitReply,
                status: .waiting
            )

            var didFail = false
            do {
                try store.createConversationRuntimeBundle(
                    targetSession: child,
                    targetMessages: [childMessage],
                    origin: origin,
                    capabilities: [capability],
                    targetRun: targetRun,
                    event: invalidEvent,
                    delegation: delegation,
                    waits: [wait],
                    waitingRunID: sourceRun.id
                )
            } catch {
                didFail = true
            }
            #expect(didFail)
            #expect(!store.loadChatSessions().contains { $0.id == child.id })
            #expect(store.loadMessages(for: child.id).isEmpty)
            #expect(try store.loadConversationOrigin(childSessionID: child.id) == nil)
            #expect(try store.loadConversationRun(id: targetRun.id) == nil)
            #expect(
                try store.loadConversationCapability(
                    sourceSessionID: parent.id,
                    targetSessionID: child.id
                ) == nil
            )
            #expect(try store.loadConversationWaits(waitGroupID: wait.waitGroupID).isEmpty)
            #expect(try store.loadConversationRun(id: sourceRun.id)?.status == .running)
        }
    }

    @Test("只投递邮箱保留未读，触发事件可原子领取")
    func persistsUnreadMailboxAndClaimsRunnableEvents() throws {
        try withStore { store in
            let source = ChatSession(id: UUID(), name: "来源", isTemporary: false)
            let target = ChatSession(id: UUID(), name: "目标", isTemporary: false)
            store.saveChatSessions([source, target])
            let unreadEvent = ConversationEvent(
                destinationSessionID: target.id,
                sourceSessionID: source.id,
                kind: .participantActivity,
                deliveryPolicy: .deliverOnly,
                createdAt: Date(timeIntervalSince1970: 1)
            )
            let runnableEvent = ConversationEvent(
                destinationSessionID: target.id,
                sourceSessionID: source.id,
                messageID: UUID(),
                kind: .incomingMessage,
                deliveryPolicy: .respondWhenIdle,
                createdAt: Date(timeIntervalSince1970: 2)
            )
            let secondRunnableEvent = ConversationEvent(
                destinationSessionID: target.id,
                sourceSessionID: source.id,
                messageID: UUID(),
                kind: .incomingMessage,
                deliveryPolicy: .respondWhenIdle,
                createdAt: Date(timeIntervalSince1970: 2.5)
            )
            try store.upsertConversationEvent(unreadEvent)
            try store.upsertConversationEvent(runnableEvent)
            try store.upsertConversationEvent(secondRunnableEvent)

            let claimed = try #require(
                try store.claimNextPendingConversationEvent(
                    executorDeviceID: "test-device",
                    at: Date(timeIntervalSince1970: 3)
                )
            )
            #expect(claimed.id == runnableEvent.id)
            #expect(claimed.state == .claimed)
            #expect(try store.loadConversationEvent(id: unreadEvent.id)?.state == .pending)
            #expect(
                try store.claimNextPendingConversationEvent(
                    executorDeviceID: "second-device",
                    at: Date(timeIntervalSince1970: 3.5)
                ) == nil
            )
            try store.updateConversationEventState(
                id: runnableEvent.id,
                state: .processed,
                executorDeviceID: "test-device",
                at: Date(timeIntervalSince1970: 3.75)
            )
            #expect(
                try store.claimNextPendingConversationEvent(
                    executorDeviceID: "second-device",
                    at: Date(timeIntervalSince1970: 3.8)
                )?.id == secondRunnableEvent.id
            )

            try store.acknowledgeConversationEvents(
                destinationSessionID: target.id,
                sourceSessionID: source.id,
                at: Date(timeIntervalSince1970: 4)
            )
            #expect(try store.loadConversationEvent(id: unreadEvent.id)?.state == .processed)
        }
    }

    @Test("Run 固化模型配置，Wait 固化工具调用关联，预算可暂停后继续")
    func persistsRunWaitAndBudgetState() throws {
        try withStore { store in
            let source = ChatSession(id: UUID(), name: "等待方", isTemporary: false)
            let target = ChatSession(id: UUID(), name: "执行方", isTemporary: false)
            let selectedMCPServerID = UUID()
            store.saveChatSessions([source, target])
            let configuration = ConversationRunRequestConfiguration(
                modelIdentifier: "provider/model-a",
                temperature: 0.25,
                topP: 0.8,
                systemPrompt: "固定系统提示词",
                maxChatHistory: 12,
                enableStreaming: false,
                browserDataProfile: .persistentShared,
                agentToolsEnabled: true,
                localLinuxToolsEnabled: false,
                selectedAgentMCPServerIDs: [selectedMCPServerID]
            )
            let sourceRun = ConversationRun(
                sessionID: source.id,
                status: .waitingConversation,
                requestConfiguration: configuration
            )
            let targetRun = ConversationRun(
                sessionID: target.id,
                rootRunID: sourceRun.rootRunID,
                parentRunID: sourceRun.id,
                status: .queued,
                requestConfiguration: configuration
            )
            try store.upsertConversationRun(sourceRun)
            try store.upsertConversationRun(targetRun)

            let persistedRun = try #require(try store.loadConversationRun(id: targetRun.id))
            #expect(persistedRun.requestConfiguration.modelIdentifier == "provider/model-a")
            #expect(persistedRun.requestConfiguration.temperature == 0.25)
            #expect(persistedRun.requestConfiguration.browserDataProfile == .persistentShared)
            #expect(persistedRun.requestConfiguration.agentToolsEnabled == true)
            #expect(persistedRun.requestConfiguration.localLinuxToolsEnabled == false)
            #expect(persistedRun.requestConfiguration.selectedAgentMCPServerIDs == [selectedMCPServerID])
            #expect(persistedRun.parentRunID == sourceRun.id)

            let waitGroupID = UUID()
            let wait = ConversationWait(
                waitGroupID: waitGroupID,
                waitingRunID: sourceRun.id,
                targetSessionID: target.id,
                targetRunID: targetRun.id,
                toolCallID: "call_wait_B",
                completionMode: .all
            )
            try store.upsertConversationWait(wait)
            let persistedWait = try #require(
                try store.loadConversationWaits(waitGroupID: waitGroupID).first
            )
            #expect(persistedWait.toolCallID == "call_wait_B")
            #expect(persistedWait.targetRunID == targetRun.id)

            let first = try store.consumeConversationExecutionBudget(
                rootRunID: sourceRun.rootRunID,
                defaultMaximum: 2,
                at: Date(timeIntervalSince1970: 1)
            )
            let second = try store.consumeConversationExecutionBudget(
                rootRunID: sourceRun.rootRunID,
                defaultMaximum: 99,
                at: Date(timeIntervalSince1970: 2)
            )
            #expect(first.maximumExecutions == 2)
            #expect(second.usedExecutions == 2)
            #expect(throws: ConversationRuntimeError.executionBudgetExhausted) {
                try store.consumeConversationExecutionBudget(
                    rootRunID: sourceRun.rootRunID,
                    defaultMaximum: 99,
                    at: Date(timeIntervalSince1970: 3)
                )
            }

            try store.extendConversationExecutionBudget(
                rootRunID: sourceRun.rootRunID,
                additionalExecutions: 2,
                at: Date(timeIntervalSince1970: 4)
            )
            let resumed = try store.consumeConversationExecutionBudget(
                rootRunID: sourceRun.rootRunID,
                defaultMaximum: 2,
                at: Date(timeIntervalSince1970: 5)
            )
            #expect(resumed.maximumExecutions == 4)
            #expect(resumed.usedExecutions == 3)
        }
    }

    @Test("跨会话消息保留真实作者和来源")
    func persistsConversationMessageProvenance() throws {
        try withStore { store in
            let source = ChatSession(id: UUID(), name: "来源", isTemporary: false)
            let target = ChatSession(id: UUID(), name: "目标", isTemporary: false)
            store.saveChatSessions([source, target])
            let sourceMessageID = UUID()
            let eventID = UUID()
            let message = ChatMessage(
                role: .user,
                content: "来自其他会话的内容",
                authorKind: .conversation,
                sourceSessionID: source.id,
                sourceMessageID: sourceMessageID,
                conversationEventID: eventID
            )

            _ = try store.appendConversationMessageAtomically(message, to: target.id)
            let persisted = try #require(store.loadMessages(for: target.id).first)
            #expect(persisted.role == .user)
            #expect(persisted.authorKind == .conversation)
            #expect(persisted.sourceSessionID == source.id)
            #expect(persisted.sourceMessageID == sourceMessageID)
            #expect(persisted.conversationEventID == eventID)
        }
    }

    @Test("工具结果可原子插入且不会覆盖同时到达的 steering")
    func insertsConversationMessagesWithoutReplacingConcurrentInput() throws {
        try withStore { store in
            let session = ChatSession(id: UUID(), name: "原子消息", isTemporary: false)
            store.saveChatSessions([session])
            let toolCallMessage = ChatMessage(role: .assistant, content: "调用工具")
            let steering = ChatMessage(role: .user, content: "用户追加方向")
            _ = try store.appendConversationMessageAtomically(toolCallMessage, to: session.id)
            _ = try store.appendConversationMessageAtomically(steering, to: session.id)

            let toolResult = ChatMessage(role: .tool, content: "工具结果", authorKind: .tool)
            _ = try store.upsertConversationMessageAtomically(
                toolResult,
                to: session.id,
                afterMessageID: toolCallMessage.id
            )

            var updatedToolCallMessage = toolCallMessage
            updatedToolCallMessage.content = "调用工具（已完成）"
            _ = try store.upsertConversationMessageAtomically(updatedToolCallMessage, to: session.id)

            let messages = store.loadMessages(for: session.id)
            #expect(messages.map(\.id) == [toolCallMessage.id, toolResult.id, steering.id])
            #expect(messages.first?.content == "调用工具（已完成）")
            #expect(messages.last?.content == "用户追加方向")

            #expect(try store.deleteConversationMessageAtomically(id: toolResult.id, from: session.id))
            #expect(store.loadMessages(for: session.id).map(\.id) == [toolCallMessage.id, steering.id])
        }
    }

    @MainActor
    @Test("流式更新只替换加载消息，不覆盖并发插入的 steering")
    func streamingMergePreservesConcurrentSteering() {
        let service = ChatService(memoryManager: MemoryManager())
        let session = service.createSavedSession(name: "并发 steering", activate: false)
        defer { service.deleteSessions([session]) }
        let loading = ChatMessage(role: .assistant, content: "生成中")
        let steering = ChatMessage(role: .user, content: "用户追加方向")
        service.storeRuntimeMessagesSnapshot([loading, steering], for: session.id)

        var updatedLoading = loading
        updatedLoading.content = "生成完成"
        let merged = service.messagesByMergingStreamingUpdate(
            [updatedLoading],
            loadingMessageID: loading.id,
            sessionID: session.id
        )

        #expect(merged.map(\.id) == [loading.id, steering.id])
        #expect(merged.first?.content == "生成完成")
        #expect(merged.last?.content == "用户追加方向")
    }

    private func withStore(_ body: (PersistenceGRDBStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("etos-conversation-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try PersistenceGRDBStore(chatsDirectory: directory)
        try body(store)
    }
}
