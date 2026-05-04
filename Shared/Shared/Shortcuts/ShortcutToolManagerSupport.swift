// ============================================================================
// ShortcutToolManagerSupport.swift
// ============================================================================
// 快捷指令工具管理器的执行、导入、回调与解析支撑。
// ============================================================================

import Foundation
import Combine
import os.log
#if os(iOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#endif

extension ShortcutToolManager {
    func executeWithFallback(
        tool: ShortcutToolDefinition,
        argumentsJSON: String,
        allowRelayOnWatch: Bool
    ) async -> ShortcutToolExecutionResult {
        let order: [ShortcutExecutionTransport] = {
            switch tool.runModeHint {
            case .bridge:
                return [.bridge, .direct]
            case .direct:
                return [.direct, .bridge]
            }
        }()

        var lastFailure: ShortcutToolExecutionResult?

        for transport in order {
            let localResult = await executeLocally(tool: tool, argumentsJSON: argumentsJSON, transport: transport)
            if localResult.success {
                return localResult
            }
            lastFailure = localResult

            #if os(watchOS)
            if allowRelayOnWatch {
                let relayRequest = ShortcutToolExecutionRequest(
                    toolName: ShortcutToolNaming.alias(for: tool),
                    argumentsJSON: argumentsJSON,
                    preferredTransport: transport
                )
                do {
                    let relayResult = try await ShortcutExecutionRelay.shared.executeViaCompanion(request: relayRequest)
                    if relayResult.success {
                        return relayResult
                    }
                    lastFailure = relayResult
                } catch {
                    lastFailure = ShortcutToolExecutionResult(
                        requestID: relayRequest.requestID,
                        toolName: tool.name,
                        success: false,
                        result: nil,
                        errorMessage: error.localizedDescription,
                        transport: .relay,
                        startedAt: relayRequest.requestedAt,
                        finishedAt: Date()
                    )
                }
            }
            #endif
        }

        return lastFailure ?? ShortcutToolExecutionResult(
            requestID: UUID().uuidString,
            toolName: tool.name,
            success: false,
            result: nil,
            errorMessage: NSLocalizedString("快捷指令执行失败。", comment: ""),
            transport: .direct,
            startedAt: Date(),
            finishedAt: Date()
        )
    }

    func executeLocally(
        tool: ShortcutToolDefinition,
        argumentsJSON: String,
        transport: ShortcutExecutionTransport
    ) async -> ShortcutToolExecutionResult {
        let requestID = UUID().uuidString
        let targetShortcutName: String
        let payloadText: String

        switch transport {
        case .direct:
            targetShortcutName = tool.name
            payloadText = normalizedArgumentsPayload(from: argumentsJSON)
        case .bridge:
            targetShortcutName = bridgeShortcutName
            payloadText = bridgePayload(for: tool, argumentsJSON: argumentsJSON, requestID: requestID)
        case .relay:
            targetShortcutName = tool.name
            payloadText = normalizedArgumentsPayload(from: argumentsJSON)
        }

        return await runShortcutAndAwaitCallback(
            requestID: requestID,
            targetShortcutName: targetShortcutName,
            payloadText: payloadText,
            originalToolName: tool.name,
            transport: transport
        )
    }

    func runShortcutAndAwaitCallback(
        requestID: String,
        targetShortcutName: String,
        payloadText: String,
        originalToolName: String,
        transport: ShortcutExecutionTransport
    ) async -> ShortcutToolExecutionResult {
        let startAt = Date()

        guard let launchURL = buildRunShortcutURL(
            targetShortcutName: targetShortcutName,
            payloadText: payloadText,
            requestID: requestID,
            transport: transport
        ) else {
            return ShortcutToolExecutionResult(
                requestID: requestID,
                toolName: originalToolName,
                success: false,
                result: nil,
                errorMessage: ShortcutToolError.cannotOpenShortcutApp.localizedDescription,
                transport: transport,
                startedAt: startAt,
                finishedAt: Date()
            )
        }

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<ShortcutToolExecutionResult, Never>) in
            var pending = PendingExecution(
                requestID: requestID,
                toolName: originalToolName,
                transport: transport,
                startedAt: startAt,
                continuation: continuation,
                timeoutTask: nil
            )

            let timeoutTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: self.executionTimeoutSeconds * 1_000_000_000)
                self.resolvePendingAsTimeout(requestID: requestID)
            }
            pending.timeoutTask = timeoutTask
            pendingExecutions[requestID] = pending

            Task { [weak self] in
                guard let self else { return }
                let opened = await self.openSystemURL(launchURL)
                if !opened {
                    let failure = ShortcutToolExecutionResult(
                        requestID: requestID,
                        toolName: originalToolName,
                        success: false,
                        result: nil,
                        errorMessage: ShortcutToolError.cannotOpenShortcutApp.localizedDescription,
                        transport: transport,
                        startedAt: startAt,
                        finishedAt: Date()
                    )
                    self.resolvePending(requestID: requestID, result: failure)
                }
            }
        }

        return result
    }

    func resolvePendingAsTimeout(requestID: String) {
        guard let pending = pendingExecutions[requestID] else { return }
        let result = ShortcutToolExecutionResult(
            requestID: requestID,
            toolName: pending.toolName,
            success: false,
            result: nil,
            errorMessage: ShortcutToolError.callbackTimeout.localizedDescription,
            transport: pending.transport,
            startedAt: pending.startedAt,
            finishedAt: Date()
        )
        resolvePending(requestID: requestID, result: result)
    }

    func resolvePending(requestID: String, result: ShortcutToolExecutionResult) {
        guard var pending = pendingExecutions.removeValue(forKey: requestID) else { return }
        pending.timeoutTask?.cancel()
        pending.timeoutTask = nil
        pending.continuation.resume(returning: result)
    }

    func buildRunShortcutURL(
        targetShortcutName: String,
        payloadText: String,
        requestID: String,
        transport: ShortcutExecutionTransport
    ) -> URL? {
        var callbackComponents = URLComponents()
        callbackComponents.scheme = ShortcutURLRouter.appScheme
        callbackComponents.host = "shortcuts"
        callbackComponents.path = "/callback"

        var successComponents = callbackComponents
        successComponents.queryItems = [
            URLQueryItem(name: "request_id", value: requestID),
            URLQueryItem(name: "status", value: "success"),
            URLQueryItem(name: "transport", value: transport.rawValue)
        ]

        var errorComponents = callbackComponents
        errorComponents.queryItems = [
            URLQueryItem(name: "request_id", value: requestID),
            URLQueryItem(name: "status", value: "error"),
            URLQueryItem(name: "transport", value: transport.rawValue)
        ]

        guard let successURL = successComponents.url?.absoluteString,
              let errorURL = errorComponents.url?.absoluteString else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: targetShortcutName),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: payloadText),
            URLQueryItem(name: "x-success", value: successURL),
            URLQueryItem(name: "x-error", value: errorURL)
        ]
        return components.url
    }

}
