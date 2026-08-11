// ============================================================================
// MCPNativeCapabilityCompanionRelay.swift
// ============================================================================
// ETOS LLM Studio
//
// watchOS 只把明确列入白名单且本机缺失的原生能力委托给配对 iPhone。
// 音频文件通过 WatchConnectivity 文件传输，不把大文件塞进即时消息。
// ============================================================================

import Foundation
#if canImport(WatchConnectivity)
@preconcurrency import WatchConnectivity
#endif

actor MCPNativeCapabilityCompanionRelay {
    static let shared = MCPNativeCapabilityCompanionRelay()

    private static let messageKind = "etos.nativeCapability.execute"
    private static let fileRequestKind = "etos.nativeCapability.fileRequest"
    private static let fileResponseKind = "etos.nativeCapability.fileResponse"
    private static let kindKey = "kind"
    private static let requestIDKey = "requestID"
    private static let toolNameKey = "toolName"
    private static let argumentsJSONKey = "argumentsJSON"
    private static let fileNameKey = "fileName"
    private static let timeoutNanoseconds: UInt64 = 5 * 60 * 1_000_000_000

    private struct FileResponse: Codable {
        let resultJSON: String?
        let errorMessage: String?
    }

    private struct PendingFileRequest {
        let continuation: CheckedContinuation<[String: Any], Error>
        let timeoutTask: Task<Void, Never>
    }

    private var pendingFileRequests: [UUID: PendingFileRequest] = [:]
    private var responseTemporaryFiles: [ObjectIdentifier: URL] = [:]

    func execute(toolName: String, arguments: [String: Any]) async throws -> [String: Any] {
        #if os(watchOS) && canImport(WatchConnectivity)
        guard Self.isAllowed(toolName) else {
            throw MCPNativeCapabilityError.unsupportedTool(toolName)
        }
        guard WCSession.isSupported() else {
            throw companionUnavailable
        }
        let session = WCSession.default
        guard session.activationState == .activated, session.isCompanionAppInstalled else {
            throw companionUnavailable
        }
        if toolName == "speech.transcribe_file" {
            return try await executeFileBackedTool(
                toolName: toolName,
                arguments: arguments,
                session: session
            )
        }
        guard session.isReachable else {
            throw companionUnavailable
        }
        let argumentsJSON = try Self.argumentsJSON(arguments)
        return try await withCheckedThrowingContinuation { continuation in
            session.sendMessage(
                [
                    Self.kindKey: Self.messageKind,
                    Self.toolNameKey: toolName,
                    Self.argumentsJSONKey: argumentsJSON
                ],
                replyHandler: { reply in
                    if let error = reply["error"] as? String {
                        continuation.resume(throwing: MCPNativeCapabilityError.unavailable(error))
                        return
                    }
                    do {
                        var result = try Self.decodeResult(reply["resultJSON"] as? String)
                        result["delegated_to_iphone"] = true
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                },
                errorHandler: { error in
                    continuation.resume(throwing: MCPNativeCapabilityError.unavailable(error.localizedDescription))
                }
            )
        }
        #else
        throw companionUnavailable
        #endif
    }

    #if os(watchOS) && canImport(WatchConnectivity)
    private func executeFileBackedTool(
        toolName: String,
        arguments: [String: Any],
        session: WCSession
    ) async throws -> [String: Any] {
        let source = try arguments.nativeRequiredString("source")
        let sourceURL = try MCPNativeFileAccess.readableURL(for: source)
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw MCPNativeCapabilityError.invalidArgument(
                NSLocalizedString("语音转写来源必须是普通文件。", comment: "Relay transcription source must be regular file")
            )
        }
        guard (values.fileSize ?? 0) <= 100 * 1_024 * 1_024 else {
            throw MCPNativeCapabilityError.invalidArgument(
                NSLocalizedString("委托转写的音频文件不能超过 100 MiB。", comment: "Relay transcription file limit")
            )
        }
        let requestID = UUID()
        let argumentsJSON = try Self.argumentsJSON(arguments)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds)
                    await self?.finishFileRequest(
                        requestID,
                        result: .failure(MCPNativeCapabilityError.unavailable(
                            NSLocalizedString("等待 iPhone 完成原生文件工具超时。", comment: "Native file relay timeout")
                        ))
                    )
                }
                pendingFileRequests[requestID] = PendingFileRequest(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                session.transferFile(
                    sourceURL,
                    metadata: [
                        Self.kindKey: Self.fileRequestKind,
                        Self.requestIDKey: requestID.uuidString,
                        Self.toolNameKey: toolName,
                        Self.argumentsJSONKey: argumentsJSON,
                        Self.fileNameKey: sourceURL.lastPathComponent
                    ]
                )
            }
        } onCancel: {
            Task { [weak self] in
                await self?.finishFileRequest(requestID, result: .failure(CancellationError()))
            }
        }
    }
    #endif

    @MainActor
    static func handleIncomingMessage(
        _ message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) -> Bool {
        #if os(iOS)
        guard message[kindKey] as? String == messageKind else { return false }
        guard let toolName = message[toolNameKey] as? String,
              isDirectMessageAllowed(toolName),
              let argumentsJSON = message[argumentsJSONKey] as? String else {
            replyHandler([
                "error": NSLocalizedString("原生能力委托消息格式无效。", comment: "Invalid native companion message")
            ])
            return true
        }
        Task {
            do {
                let result: [String: Any]
                if MCPNativeDeviceToolDefinitions.contains(toolName) {
                    result = try await MCPNativeDeviceExecutor.shared.execute(
                        toolName: toolName,
                        argumentsJSON: argumentsJSON
                    )
                } else {
                    result = try await MCPNativeMediaExecutor.shared.execute(
                        toolName: toolName,
                        argumentsJSON: argumentsJSON
                    )
                }
                replyHandler(["resultJSON": try MCPNativeJSON.text(result)])
            } catch {
                replyHandler(["error": error.localizedDescription])
            }
        }
        return true
        #else
        return false
        #endif
    }

    #if canImport(WatchConnectivity)
    nonisolated static func handleIncomingFile(_ file: WCSessionFile, session: WCSession) -> Bool {
        guard let kind = file.metadata?[kindKey] as? String,
              kind == fileRequestKind || kind == fileResponseKind else {
            return false
        }
        let metadata = file.metadata ?? [:]
        let stagedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("etos-native-relay-\(UUID().uuidString)")
            .appendingPathExtension(file.fileURL.pathExtension)
        do {
            try FileManager.default.moveItem(at: file.fileURL, to: stagedURL)
            Task {
                await shared.receiveFile(
                    at: stagedURL,
                    metadata: metadata,
                    session: session
                )
            }
        } catch {
            Task {
                await shared.receiveStagingFailure(
                    error,
                    metadata: metadata,
                    session: session
                )
            }
        }
        return true
    }

    func handleFinishedTransfer(_ transfer: WCSessionFileTransfer, error: Error?) -> Bool {
        guard let kind = transfer.file.metadata?[Self.kindKey] as? String,
              kind == Self.fileRequestKind || kind == Self.fileResponseKind else {
            return false
        }
        let identifier = ObjectIdentifier(transfer)
        if let url = responseTemporaryFiles.removeValue(forKey: identifier) {
            try? FileManager.default.removeItem(at: url)
        }
        #if os(watchOS)
        if let error,
           kind == Self.fileRequestKind,
           let rawRequestID = transfer.file.metadata?[Self.requestIDKey] as? String,
           let requestID = UUID(uuidString: rawRequestID) {
            finishFileRequest(
                requestID,
                result: .failure(MCPNativeCapabilityError.unavailable(error.localizedDescription))
            )
        }
        #endif
        return true
    }

    private func receiveFile(at url: URL, metadata: [String: Any], session: WCSession) async {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let kind = metadata[Self.kindKey] as? String,
              let rawRequestID = metadata[Self.requestIDKey] as? String,
              let requestID = UUID(uuidString: rawRequestID) else {
            return
        }
        switch kind {
        case Self.fileRequestKind:
            #if os(iOS)
            await processFileRequest(
                at: url,
                metadata: metadata,
                requestID: requestID,
                session: session
            )
            #endif
        case Self.fileResponseKind:
            #if os(watchOS)
            processFileResponse(at: url, requestID: requestID)
            #endif
        default:
            break
        }
    }

    private func receiveStagingFailure(
        _ error: Error,
        metadata: [String: Any],
        session: WCSession
    ) async {
        guard let kind = metadata[Self.kindKey] as? String,
              let rawRequestID = metadata[Self.requestIDKey] as? String,
              let requestID = UUID(uuidString: rawRequestID) else {
            return
        }
        #if os(iOS)
        if kind == Self.fileRequestKind {
            await sendFileResponse(
                FileResponse(resultJSON: nil, errorMessage: error.localizedDescription),
                requestID: requestID,
                session: session
            )
        }
        #elseif os(watchOS)
        if kind == Self.fileResponseKind {
            finishFileRequest(
                requestID,
                result: .failure(MCPNativeCapabilityError.unavailable(error.localizedDescription))
            )
        }
        #endif
    }

    #if os(iOS)
    private func processFileRequest(
        at url: URL,
        metadata: [String: Any],
        requestID: UUID,
        session: WCSession
    ) async {
        let response: FileResponse
        do {
            guard metadata[Self.toolNameKey] as? String == "speech.transcribe_file",
                  let argumentsJSON = metadata[Self.argumentsJSONKey] as? String else {
                throw MCPNativeCapabilityError.unsupportedTool(
                    metadata[Self.toolNameKey] as? String ?? ""
                )
            }
            let arguments = try Self.decodeArguments(argumentsJSON)
            let result = try await MCPNativeSpeechExecutor().executeRelayedTranscription(
                arguments: arguments,
                fileURL: url
            )
            response = FileResponse(resultJSON: try MCPNativeJSON.text(result), errorMessage: nil)
        } catch {
            response = FileResponse(resultJSON: nil, errorMessage: error.localizedDescription)
        }
        await sendFileResponse(response, requestID: requestID, session: session)
    }

    private func sendFileResponse(
        _ response: FileResponse,
        requestID: UUID,
        session: WCSession
    ) async {
        do {
            let data = try PropertyListEncoder().encode(response)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("etos-native-relay-response-\(requestID.uuidString)")
                .appendingPathExtension("plist")
            try data.write(to: url, options: .atomic)
            let transfer = session.transferFile(
                url,
                metadata: [
                    Self.kindKey: Self.fileResponseKind,
                    Self.requestIDKey: requestID.uuidString
                ]
            )
            responseTemporaryFiles[ObjectIdentifier(transfer)] = url
        } catch {
            // 文件委托在对端有超时边界；这里不能再通过另一条不可靠通道假装成功。
        }
    }
    #endif

    #if os(watchOS)
    private func processFileResponse(at url: URL, requestID: UUID) {
        do {
            let data = try Data(contentsOf: url)
            let response = try PropertyListDecoder().decode(FileResponse.self, from: data)
            if let errorMessage = response.errorMessage {
                finishFileRequest(
                    requestID,
                    result: .failure(MCPNativeCapabilityError.unavailable(errorMessage))
                )
                return
            }
            var result = try Self.decodeResult(response.resultJSON)
            result["delegated_to_iphone"] = true
            finishFileRequest(requestID, result: .success(result))
        } catch {
            finishFileRequest(
                requestID,
                result: .failure(MCPNativeCapabilityError.unavailable(
                    NSLocalizedString("iPhone 返回的原生文件工具结果无效。", comment: "Invalid native file relay response")
                ))
            )
        }
    }
    #endif
    #endif

    private func finishFileRequest(_ requestID: UUID, result: Result<[String: Any], Error>) {
        guard let pending = pendingFileRequests.removeValue(forKey: requestID) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(with: result)
    }

    private nonisolated static func isAllowed(_ toolName: String) -> Bool {
        isDirectMessageAllowed(toolName) || toolName == "speech.transcribe_file"
    }

    private nonisolated static func isDirectMessageAllowed(_ toolName: String) -> Bool {
        MCPNativeDeviceToolDefinitions.contains(toolName)
            || [
                "home.list_homes", "home.list_accessories", "home.list_scenes",
                "home.read_characteristic", "home.write_characteristic", "home.execute_scene",
                "nfc.scan", "nfc.read_ndef", "nfc.write_ndef"
            ].contains(toolName)
    }

    private nonisolated static func argumentsJSON(_ arguments: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(arguments) else {
            throw MCPNativeCapabilityError.invalidArgument(
                NSLocalizedString("原生能力委托参数无法编码。", comment: "Native relay arguments invalid")
            )
        }
        let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func decodeArguments(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPNativeCapabilityError.invalidArgument(
                NSLocalizedString("原生能力委托参数不是 JSON 对象。", comment: "Native relay arguments invalid")
            )
        }
        return value
    }

    private nonisolated static func decodeResult(_ text: String?) throws -> [String: Any] {
        guard let text,
              let data = text.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPNativeCapabilityError.unavailable(
                NSLocalizedString("iPhone 未返回有效的原生工具结果。", comment: "Invalid native companion response")
            )
        }
        return result
    }

    private var companionUnavailable: MCPNativeCapabilityError {
        .unavailable(
            NSLocalizedString("配对 iPhone 当前不可达，无法执行该原生能力。", comment: "Native companion unavailable")
        )
    }
}
