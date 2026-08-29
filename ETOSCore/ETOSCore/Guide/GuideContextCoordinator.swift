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

    /// watchOS 进入二级向导页时，暂时保留来源页声明；退出向导后必须解除。
    public func pinActivePage() {
        pinnedRegistration = registrations.last
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
        registrations.last ?? pinnedRegistration
    }
}
