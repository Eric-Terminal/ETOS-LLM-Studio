// ============================================================================
// Shared.swift
// ============================================================================
// ETOS LLM Studio 共享模块通用文件
//
// 定义内容:
// - (当前为空，可用于存放共享的扩展、辅助函数等)
// ============================================================================

import Foundation
import Combine

public enum ToolPermissionDecision: String {
    case deny
    case allowOnce
    case allowForTool
    case allowAll
    case supplement
}

public struct ToolPermissionRequest: Identifiable, Equatable {
    public let id: UUID
    public let toolName: String
    public let displayName: String?
    public let arguments: String
    
    public init(id: UUID = UUID(), toolName: String, displayName: String?, arguments: String) {
        self.id = id
        self.toolName = toolName
        self.displayName = displayName
        self.arguments = arguments
    }
}

@MainActor
public final class ToolPermissionCenter: ObservableObject {
    public static let shared = ToolPermissionCenter()
    
    @Published public private(set) var activeRequest: ToolPermissionRequest?
    
    private var allowAll = false
    private var allowedTools: Set<String> = []
    private var queuedRequests: [QueuedRequest] = []
    private var activeContinuation: CheckedContinuation<ToolPermissionDecision, Never>?
    
    public func requestPermission(toolName: String, displayName: String?, arguments: String) async -> ToolPermissionDecision {
        if allowAll || allowedTools.contains(toolName) {
            return .allowOnce
        }
        
        return await withCheckedContinuation { continuation in
            let request = ToolPermissionRequest(toolName: toolName, displayName: displayName, arguments: arguments)
            if activeRequest == nil {
                activeRequest = request
                activeContinuation = continuation
            } else {
                queuedRequests.append(QueuedRequest(request: request, continuation: continuation))
            }
        }
    }
    
    public func resolveActiveRequest(with decision: ToolPermissionDecision) {
        guard let activeRequest else { return }
        
        switch decision {
        case .allowAll:
            allowAll = true
        case .allowForTool:
            allowedTools.insert(activeRequest.toolName)
        case .deny, .allowOnce, .supplement:
            break
        }
        
        activeContinuation?.resume(returning: decision)
        activeContinuation = nil
        self.activeRequest = nil
        advanceQueueIfNeeded()
    }
    
    private func advanceQueueIfNeeded() {
        guard self.activeRequest == nil, !queuedRequests.isEmpty else { return }
        while !queuedRequests.isEmpty {
            let next = queuedRequests.removeFirst()
            if allowAll || allowedTools.contains(next.request.toolName) {
                next.continuation.resume(returning: .allowOnce)
                continue
            }
            self.activeRequest = next.request
            activeContinuation = next.continuation
            break
        }
    }
}

private struct QueuedRequest {
    let request: ToolPermissionRequest
    let continuation: CheckedContinuation<ToolPermissionDecision, Never>
}
