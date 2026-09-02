// ============================================================================
// GuideContextCoordinator.swift
// ============================================================================
// ETOS LLM Studio
//
// 页面显式注册向导上下文；导航栈最上层的注册项始终代表用户当前看到的页面。
// ============================================================================

import Foundation
import Combine

@MainActor
public final class GuideContextCoordinator: ObservableObject {
    public struct RegistrationToken: Hashable, Sendable {
        fileprivate let id: UUID

        public init() {
            self.id = UUID()
        }
    }

    public typealias SnapshotProvider = @MainActor @Sendable () async -> GuidePageSnapshot
    public typealias ReadToolExecutor = @MainActor @Sendable (InternalToolCall) async throws -> String
    public typealias ProposalBuilder = @MainActor @Sendable (InternalToolCall, GuidePageSnapshot) throws -> GuideActionProposal
    public typealias ProposalExecutor = @MainActor @Sendable (GuideActionProposal) async throws -> GuideActionExecution

    private struct Registration {
        let token: RegistrationToken
        let descriptor: GuidePageDescriptor
        let isFallback: Bool
        let snapshotProvider: SnapshotProvider
        let readToolExecutor: ReadToolExecutor
        let proposalBuilder: ProposalBuilder
        let proposalExecutor: ProposalExecutor
    }

    public static let shared = GuideContextCoordinator()

    @Published public private(set) var activePage: GuidePageDescriptor?
    private var registrations: [Registration] = []
    private var pinnedRegistration: Registration?

    public init() {}

    @discardableResult
    public func register(
        descriptor: GuidePageDescriptor,
        isFallback: Bool = false,
        snapshot: @escaping SnapshotProvider,
        executeReadTool: @escaping ReadToolExecutor = { call in
            throw GuideError.unsupportedTool(call.toolName)
        },
        buildProposal: @escaping ProposalBuilder,
        execute: @escaping ProposalExecutor
    ) -> RegistrationToken {
        let token = RegistrationToken()
        registrations.append(Registration(
            token: token,
            descriptor: descriptor,
            isFallback: isFallback,
            snapshotProvider: snapshot,
            readToolExecutor: executeReadTool,
            proposalBuilder: buildProposal,
            proposalExecutor: execute
        ))
        refreshActivePage()
        return token
    }

    public func unregister(_ token: RegistrationToken) {
        registrations.removeAll { $0.token == token }
        refreshActivePage()
    }

    public func activate(_ token: RegistrationToken) {
        guard let index = registrations.firstIndex(where: { $0.token == token }) else { return }
        let registration = registrations.remove(at: index)
        registrations.append(registration)
        refreshActivePage()
    }

    /// SwiftUI 视图仍停留在同一层级时，页面声明可能随传输类型等本地状态变化。
    /// 替换原注册项而不改变其导航顺序，避免向导继续使用旧字段白名单。
    public func update(
        _ token: RegistrationToken,
        descriptor: GuidePageDescriptor,
        isFallback: Bool = false,
        snapshot: @escaping SnapshotProvider,
        executeReadTool: @escaping ReadToolExecutor,
        buildProposal: @escaping ProposalBuilder,
        execute: @escaping ProposalExecutor
    ) {
        guard let index = registrations.firstIndex(where: { $0.token == token }) else { return }
        registrations[index] = Registration(
            token: token,
            descriptor: descriptor,
            isFallback: isFallback,
            snapshotProvider: snapshot,
            readToolExecutor: executeReadTool,
            proposalBuilder: buildProposal,
            proposalExecutor: execute
        )
        refreshActivePage()
    }

    /// watchOS 进入二级向导页时，暂时保留来源页声明；退出向导后必须解除。
    public func pinActivePage() {
        pinnedRegistration = currentRegistration
        refreshActivePage()
    }

    public func unpinActivePage() {
        pinnedRegistration = nil
        refreshActivePage()
    }

    public func currentContext() async throws -> GuidePageContext {
        guard let registration = currentRegistration else {
            throw GuideError.noActivePage
        }
        return GuidePageContext(
            descriptor: registration.descriptor,
            snapshot: await registration.snapshotProvider()
        )
    }

    public func makeProposal(for call: InternalToolCall) async throws -> GuideActionProposal {
        guard let registration = currentRegistration else {
            throw GuideError.noActivePage
        }
        guard registration.descriptor.tools.contains(where: {
            $0.access == .proposeChange && $0.definition.name == call.toolName
        }) else {
            throw GuideError.unsupportedTool(call.toolName)
        }
        let snapshot = await registration.snapshotProvider()
        return try registration.proposalBuilder(call, snapshot)
    }

    public func executeReadTool(_ call: InternalToolCall) async throws -> String {
        guard let registration = currentRegistration else {
            throw GuideError.noActivePage
        }
        guard registration.descriptor.tools.contains(where: {
            $0.access == .read && $0.definition.name == call.toolName
        }) else {
            throw GuideError.unsupportedTool(call.toolName)
        }
        return try await registration.readToolExecutor(call)
    }

    public func execute(_ proposal: GuideActionProposal) async throws -> GuideActionExecution {
        guard let registration = currentRegistration else {
            throw GuideError.noActivePage
        }
        guard registration.descriptor.id == proposal.pageID else {
            throw GuideError.pageChanged
        }
        return try await registration.proposalExecutor(proposal)
    }

    private func refreshActivePage() {
        activePage = currentRegistration?.descriptor
    }

    private var currentRegistration: Registration? {
        // 导航容器的后备上下文只在当前页没有更精确声明时接管。
        // watchOS 进入向导二级页后，固定的来源页也应优先于设置根容器。
        registrations.last(where: { !$0.isFallback })
            ?? pinnedRegistration
            ?? registrations.last
    }
}
