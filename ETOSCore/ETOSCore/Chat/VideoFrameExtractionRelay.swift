// ============================================================================
// VideoFrameExtractionRelay.swift
// ============================================================================
// ETOS LLM Studio
//
// watchOS 没有系统视频逐帧解码 API，因此将抽帧任务交给配对 iPhone。
// ============================================================================

import Foundation
#if canImport(WatchConnectivity)
@preconcurrency import WatchConnectivity
#endif

#if canImport(WatchConnectivity)
actor VideoFrameExtractionRelay {
    static let shared = VideoFrameExtractionRelay()

    private static let requestKind = "video.frameExtraction.request"
    private static let responseKind = "video.frameExtraction.response"
    private static let kindKey = "kind"
    private static let requestIDKey = "requestID"
    private static let fileNameKey = "fileName"
    private static let mimeTypeKey = "mimeType"
    private static let modeKey = "mode"
    private static let fixedFPSKey = "fixedFPS"
    private static let maximumFrameCountKey = "maximumFrameCount"
    private static let timeoutNanoseconds: UInt64 = 5 * 60 * 1_000_000_000

    private struct RelayFrame: Codable {
        let data: Data
        let mimeType: String
        let fileName: String
        let timestamp: Double
    }

    private struct RelayResponse: Codable {
        let frames: [RelayFrame]
        let duration: Double
        let errorMessage: String?
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<VideoFrameExtractionResult, Error>
        let timeoutTask: Task<Void, Never>
    }

    private var pendingRequests: [UUID: PendingRequest] = [:]
    private var outboundTemporaryFiles: [ObjectIdentifier: URL] = [:]

    func extractFrames(
        from attachment: FileAttachment,
        configuration: VideoFrameExtractionConfiguration
    ) async throws -> VideoFrameExtractionResult {
#if os(watchOS)
        guard WCSession.isSupported() else {
            throw VideoFrameExtractionRelayError.unsupported
        }
        let session = WCSession.default
        try Self.validateCompanionAvailability(
            isActivated: session.activationState == .activated,
            isCompanionAppInstalled: session.isCompanionAppInstalled,
            isReachable: session.isReachable
        )

        let requestID = UUID()
        let fileExtension = (attachment.fileName as NSString).pathExtension
        let requestURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("etos-video-relay-\(requestID.uuidString)")
            .appendingPathExtension(fileExtension.isEmpty ? "mp4" : fileExtension)
        try attachment.data.write(to: requestURL, options: .atomic)

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds)
                await self?.finishRequest(
                    requestID,
                    result: .failure(VideoFrameExtractionRelayError.timeout)
                )
            }
            pendingRequests[requestID] = PendingRequest(
                continuation: continuation,
                timeoutTask: timeoutTask
            )
            let transfer = session.transferFile(
                requestURL,
                metadata: [
                    Self.kindKey: Self.requestKind,
                    Self.requestIDKey: requestID.uuidString,
                    Self.fileNameKey: attachment.fileName,
                    Self.mimeTypeKey: attachment.mimeType,
                    Self.modeKey: configuration.mode.rawValue,
                    Self.fixedFPSKey: configuration.fixedFPS,
                    Self.maximumFrameCountKey: configuration.maximumFrameCount
                ]
            )
            outboundTemporaryFiles[ObjectIdentifier(transfer)] = requestURL
        }
#else
        throw VideoFrameExtractionRelayError.unsupported
#endif
    }

    nonisolated static func validateCompanionAvailability(
        isActivated: Bool,
        isCompanionAppInstalled: Bool,
        isReachable: Bool
    ) throws {
        guard isActivated, isCompanionAppInstalled else {
            throw VideoFrameExtractionRelayError.companionUnavailable
        }
        guard isReachable else {
            throw VideoFrameExtractionRelayError.companionUnreachable
        }
    }

    nonisolated static func handleIncomingFile(
        _ file: WCSessionFile,
        session: WCSession
    ) -> Bool {
        guard let kind = file.metadata?[kindKey] as? String,
              kind == requestKind || kind == responseKind else {
            return false
        }
        let metadata = file.metadata ?? [:]
        let fileURL = file.fileURL
        Task.detached(priority: .userInitiated) {
            let dataResult = Result { try Data(contentsOf: fileURL) }
            await shared.receive(
                dataResult: dataResult,
                metadata: metadata,
                session: session
            )
        }
        return true
    }

    func handleFinishedTransfer(
        _ transfer: WCSessionFileTransfer,
        error: Error?
    ) -> Bool {
        guard let kind = transfer.file.metadata?[Self.kindKey] as? String,
              kind == Self.requestKind || kind == Self.responseKind else {
            return false
        }
        let identifier = ObjectIdentifier(transfer)
        if let url = outboundTemporaryFiles.removeValue(forKey: identifier) {
            try? FileManager.default.removeItem(at: url)
        }
        if let error,
           kind == Self.requestKind,
           let rawRequestID = transfer.file.metadata?[Self.requestIDKey] as? String,
           let requestID = UUID(uuidString: rawRequestID) {
            finishRequest(
                requestID,
                result: .failure(VideoFrameExtractionRelayError.transferFailed(error.localizedDescription))
            )
        }
        return true
    }

    private func receive(
        dataResult: Result<Data, Error>,
        metadata: [String: Any],
        session: WCSession
    ) async {
        guard let kind = metadata[Self.kindKey] as? String,
              let rawRequestID = metadata[Self.requestIDKey] as? String,
              let requestID = UUID(uuidString: rawRequestID) else {
            return
        }
        switch kind {
        case Self.requestKind:
#if os(iOS)
            await processRequest(
                dataResult: dataResult,
                metadata: metadata,
                requestID: requestID,
                session: session
            )
#endif
        case Self.responseKind:
#if os(watchOS)
            processResponse(dataResult: dataResult, requestID: requestID)
#endif
        default:
            break
        }
    }

#if os(iOS)
    private func processRequest(
        dataResult: Result<Data, Error>,
        metadata: [String: Any],
        requestID: UUID,
        session: WCSession
    ) async {
        let response: RelayResponse
        do {
            let data = try dataResult.get()
            let mode = VideoFrameExtractionMode.normalized(
                metadata[Self.modeKey] as? String ?? ""
            )
            let configuration = VideoFrameExtractionConfiguration(
                mode: mode,
                fixedFPS: metadata[Self.fixedFPSKey] as? Double ?? 1,
                maximumFrameCount: metadata[Self.maximumFrameCountKey] as? Int ?? 60
            )
            let attachment = FileAttachment(
                data: data,
                mimeType: metadata[Self.mimeTypeKey] as? String ?? "video/mp4",
                fileName: metadata[Self.fileNameKey] as? String ?? "video.mp4"
            )
            let result = try await VideoFrameExtractor().extractFrames(
                from: attachment,
                configuration: configuration
            )
            response = RelayResponse(
                frames: result.frames.map { frame in
                    RelayFrame(
                        data: frame.attachment.data,
                        mimeType: frame.attachment.mimeType,
                        fileName: frame.attachment.fileName,
                        timestamp: frame.timestamp
                    )
                },
                duration: result.duration,
                errorMessage: nil
            )
        } catch {
            response = RelayResponse(
                frames: [],
                duration: 0,
                errorMessage: error.localizedDescription
            )
        }

        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let responseData = try encoder.encode(response)
            let responseURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("etos-video-relay-response-\(requestID.uuidString)")
                .appendingPathExtension("plist")
            try responseData.write(to: responseURL, options: .atomic)
            let transfer = session.transferFile(
                responseURL,
                metadata: [
                    Self.kindKey: Self.responseKind,
                    Self.requestIDKey: requestID.uuidString
                ]
            )
            outboundTemporaryFiles[ObjectIdentifier(transfer)] = responseURL
        } catch {
            // 对端超时后会给出可理解的错误，不在这里创建第二条传输。
        }
    }
#endif

#if os(watchOS)
    private func processResponse(
        dataResult: Result<Data, Error>,
        requestID: UUID
    ) {
        do {
            let data = try dataResult.get()
            let response = try PropertyListDecoder().decode(RelayResponse.self, from: data)
            if let errorMessage = response.errorMessage {
                finishRequest(
                    requestID,
                    result: .failure(VideoFrameExtractionRelayError.remoteFailed(errorMessage))
                )
                return
            }
            let frames = response.frames.map { frame in
                ExtractedVideoFrame(
                    attachment: ImageAttachment(
                        data: frame.data,
                        mimeType: frame.mimeType,
                        fileName: frame.fileName
                    ),
                    timestamp: frame.timestamp
                )
            }
            finishRequest(
                requestID,
                result: .success(VideoFrameExtractionResult(
                    frames: frames,
                    duration: response.duration
                ))
            )
        } catch {
            finishRequest(
                requestID,
                result: .failure(VideoFrameExtractionRelayError.invalidResponse)
            )
        }
    }
#endif

    private func finishRequest(
        _ requestID: UUID,
        result: Result<VideoFrameExtractionResult, Error>
    ) {
        guard let pending = pendingRequests.removeValue(forKey: requestID) else {
            return
        }
        pending.timeoutTask.cancel()
        pending.continuation.resume(with: result)
    }
}

enum VideoFrameExtractionRelayError: LocalizedError, Equatable {
    case unsupported
    case companionUnavailable
    case companionUnreachable
    case transferFailed(String)
    case timeout
    case invalidResponse
    case remoteFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return NSLocalizedString("此设备不支持视频抽帧中继。", comment: "Video frame relay unsupported")
        case .companionUnavailable:
            return NSLocalizedString("非原生视频发送需要配对 iPhone 协助抽帧，请确认 iPhone 已安装并启动本应用。", comment: "Video frame relay companion unavailable")
        case .companionUnreachable:
            return NSLocalizedString("无法抽帧：当前无法连接配对 iPhone。请连接 iPhone 后重试。", comment: "Video frame relay companion unreachable")
        case .transferFailed(let message):
            return String(
                format: NSLocalizedString("视频发送到 iPhone 失败：%@", comment: "Video frame relay transfer failed"),
                message
            )
        case .timeout:
            return NSLocalizedString("等待 iPhone 完成视频抽帧超时。", comment: "Video frame relay timeout")
        case .invalidResponse:
            return NSLocalizedString("iPhone 返回的视频抽帧结果无法解析。", comment: "Video frame relay invalid response")
        case .remoteFailed(let message):
            return String(
                format: NSLocalizedString("iPhone 视频抽帧失败：%@", comment: "Video frame relay remote failure"),
                message
            )
        }
    }
}
#endif
