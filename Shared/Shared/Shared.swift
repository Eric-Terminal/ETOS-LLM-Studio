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
    @Published public private(set) var autoApproveEnabled: Bool
    @Published public private(set) var autoApproveCountdownSeconds: Int
    @Published public private(set) var autoApproveRemainingSeconds: Int?
    @Published public private(set) var disabledAutoApproveTools: [String]
    
    private var allowAll = false
    private var allowedTools: Set<String> = []
    private var disabledAutoApproveToolSet: Set<String>
    private var queuedRequests: [QueuedRequest] = []
    private var activeContinuation: CheckedContinuation<ToolPermissionDecision, Never>?
    private var autoApproveTask: Task<Void, Never>?
    private let defaults: UserDefaults

    private enum DefaultsKey {
        static let autoApproveEnabled = "tool.permission.autoApproveEnabled"
        static let autoApproveCountdownSeconds = "tool.permission.autoApproveCountdownSeconds"
        static let disabledAutoApproveTools = "tool.permission.disabledAutoApproveTools"
    }

    private let autoApproveCountdownMin = 1
    private let autoApproveCountdownMax = 30

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedEnabled = defaults.object(forKey: DefaultsKey.autoApproveEnabled) as? Bool
        autoApproveEnabled = storedEnabled ?? false
        let storedCountdown = defaults.integer(forKey: DefaultsKey.autoApproveCountdownSeconds)
        if storedCountdown > 0 {
            autoApproveCountdownSeconds = min(max(storedCountdown, autoApproveCountdownMin), autoApproveCountdownMax)
        } else {
            autoApproveCountdownSeconds = 8
        }
        let storedDisabledTools = defaults.stringArray(forKey: DefaultsKey.disabledAutoApproveTools) ?? []
        disabledAutoApproveToolSet = Set(storedDisabledTools.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        disabledAutoApproveTools = disabledAutoApproveToolSet.sorted()
    }
    
    public func requestPermission(toolName: String, displayName: String?, arguments: String) async -> ToolPermissionDecision {
        if allowAll || allowedTools.contains(toolName) {
            return .allowOnce
        }
        
        return await withCheckedContinuation { continuation in
            let request = ToolPermissionRequest(toolName: toolName, displayName: displayName, arguments: arguments)
            if activeRequest == nil {
                activeRequest = request
                activeContinuation = continuation
                scheduleAutoApproveIfNeeded(for: request)
            } else {
                queuedRequests.append(QueuedRequest(request: request, continuation: continuation))
            }
        }
    }
    
    public func resolveActiveRequest(with decision: ToolPermissionDecision) {
        guard let activeRequest else { return }
        cancelAutoApproveCountdown()
        
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

    public func setAutoApproveEnabled(_ enabled: Bool) {
        autoApproveEnabled = enabled
        defaults.set(enabled, forKey: DefaultsKey.autoApproveEnabled)
        if let activeRequest {
            scheduleAutoApproveIfNeeded(for: activeRequest)
        } else {
            cancelAutoApproveCountdown()
        }
    }

    public func setAutoApproveCountdownSeconds(_ seconds: Int) {
        let sanitized = min(max(seconds, autoApproveCountdownMin), autoApproveCountdownMax)
        autoApproveCountdownSeconds = sanitized
        defaults.set(sanitized, forKey: DefaultsKey.autoApproveCountdownSeconds)
        if let activeRequest {
            scheduleAutoApproveIfNeeded(for: activeRequest)
        }
    }

    public func isAutoApproveDisabled(for toolName: String) -> Bool {
        let normalized = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return disabledAutoApproveToolSet.contains(normalized)
    }

    public func setAutoApproveDisabled(_ disabled: Bool, for toolName: String) {
        let normalized = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        if disabled {
            disabledAutoApproveToolSet.insert(normalized)
        } else {
            disabledAutoApproveToolSet.remove(normalized)
        }
        persistDisabledAutoApproveTools()
        if let activeRequest, activeRequest.toolName == normalized {
            scheduleAutoApproveIfNeeded(for: activeRequest)
        }
    }

    public func clearDisabledAutoApproveTools() {
        disabledAutoApproveToolSet.removeAll()
        persistDisabledAutoApproveTools()
        if let activeRequest {
            scheduleAutoApproveIfNeeded(for: activeRequest)
        }
    }

    public func disableAutoApproveForActiveTool() {
        guard let activeRequest else { return }
        setAutoApproveDisabled(true, for: activeRequest.toolName)
    }

    public func autoApproveRemainingSeconds(for request: ToolPermissionRequest) -> Int? {
        guard activeRequest?.id == request.id else { return nil }
        return autoApproveRemainingSeconds
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
            scheduleAutoApproveIfNeeded(for: next.request)
            break
        }
        if self.activeRequest == nil {
            cancelAutoApproveCountdown()
        }
    }

    private func scheduleAutoApproveIfNeeded(for request: ToolPermissionRequest) {
        cancelAutoApproveCountdown()
        guard autoApproveEnabled,
              !isAutoApproveDisabled(for: request.toolName),
              autoApproveCountdownSeconds > 0 else {
            return
        }

        autoApproveRemainingSeconds = autoApproveCountdownSeconds
        let requestID = request.id
        autoApproveTask = Task { [weak self] in
            guard let self else { return }
            var remaining = autoApproveCountdownSeconds
            while remaining > 0 {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                if Task.isCancelled {
                    return
                }
                remaining -= 1
                await MainActor.run {
                    guard self.activeRequest?.id == requestID else { return }
                    self.autoApproveRemainingSeconds = remaining
                }
            }

            await MainActor.run {
                guard self.activeRequest?.id == requestID else { return }
                self.resolveActiveRequest(with: .allowOnce)
            }
        }
    }

    private func cancelAutoApproveCountdown() {
        autoApproveTask?.cancel()
        autoApproveTask = nil
        autoApproveRemainingSeconds = nil
    }

    private func persistDisabledAutoApproveTools() {
        disabledAutoApproveTools = disabledAutoApproveToolSet.sorted()
        defaults.set(disabledAutoApproveTools, forKey: DefaultsKey.disabledAutoApproveTools)
    }
}

private struct QueuedRequest {
    let request: ToolPermissionRequest
    let continuation: CheckedContinuation<ToolPermissionDecision, Never>
}
