// ============================================================================
// MCPNativeNFCExecutor.swift
// ============================================================================
// ETOS LLM Studio
//
// NFC 操作始终使用系统交互界面；写入前还要校验模型提交的完整记录预览。
// ============================================================================

import Foundation
#if os(iOS) && canImport(CoreNFC)
@preconcurrency import CoreNFC
#endif

actor MCPNativeNFCExecutor {
    func execute(toolName: String, arguments: [String: Any]) async throws -> [String: Any] {
        #if os(iOS) && canImport(CoreNFC)
        guard NFCReaderSession.readingAvailable else {
            throw MCPNativeCapabilityError.unavailable(
                NSLocalizedString("当前 iPhone 不支持 NFC 标签读取。", comment: "NFC unavailable")
            )
        }
        switch toolName {
        case "nfc.scan":
            return try await MCPNativeNFCSessionController.shared.scan()
        case "nfc.read_ndef":
            return try await MCPNativeNFCSessionController.shared.readNDEF()
        case "nfc.write_ndef":
            guard arguments.nativeBool("confirmed") == true else {
                throw MCPNativeCapabilityError.invalidArgument(
                    NSLocalizedString("写入 NFC 前必须确认完整 NDEF 预览。", comment: "NFC write preview confirmation required")
                )
            }
            let records = try MCPNativeNDEFRecord.records(from: arguments)
            return try await MCPNativeNFCSessionController.shared.writeNDEF(records)
        default:
            throw MCPNativeCapabilityError.unsupportedTool(toolName)
        }
        #else
        return try await MCPNativeCapabilityCompanionRelay.shared.execute(
            toolName: toolName,
            arguments: arguments
        )
        #endif
    }
}

#if os(iOS) && canImport(CoreNFC)
private struct MCPNativeNDEFRecord {
    let payload: NFCNDEFPayload
    let preview: [String: Any]

    static func records(from arguments: [String: Any]) throws -> [Self] {
        guard let rawRecords = arguments["records"] as? [[String: Any]], !rawRecords.isEmpty else {
            throw MCPNativeCapabilityError.missingArgument("records")
        }
        guard rawRecords.count <= 32 else {
            throw MCPNativeCapabilityError.invalidArgument(
                NSLocalizedString("一次最多写入 32 条 NDEF 记录。", comment: "NDEF record count limit")
            )
        }
        return try rawRecords.map(makeRecord)
    }

    private static func makeRecord(_ record: [String: Any]) throws -> Self {
        let kind = try record.nativeRequiredString("kind").lowercased()
        let value = try record.nativeRequiredString("value")
        switch kind {
        case "text":
            let language = record.nativeString("language") ?? "en"
            guard let payload = NFCNDEFPayload.wellKnownTypeTextPayload(
                string: value,
                locale: Locale(identifier: language)
            ) else {
                throw invalidRecord(kind)
            }
            return Self(
                payload: payload,
                preview: ["kind": kind, "text": value, "language": language]
            )
        case "uri":
            guard let payload = NFCNDEFPayload.wellKnownTypeURIPayload(string: value) else {
                throw invalidRecord(kind)
            }
            return Self(payload: payload, preview: ["kind": kind, "uri": value])
        case "mime":
            let mimeType = try record.nativeRequiredString("mime_type")
            guard let data = Data(base64Encoded: value), data.count <= 1_048_576 else {
                throw MCPNativeCapabilityError.invalidArgument(
                    NSLocalizedString("MIME NDEF 记录必须包含不超过 1 MiB 的有效 Base64 数据。", comment: "Invalid MIME NDEF data")
                )
            }
            let payload = NFCNDEFPayload(
                format: .media,
                type: Data(mimeType.utf8),
                identifier: Data(),
                payload: data
            )
            return Self(
                payload: payload,
                preview: ["kind": kind, "mime_type": mimeType, "byte_count": data.count]
            )
        case "external":
            let externalType = try record.nativeRequiredString("external_type")
            guard externalType.contains(":"),
                  let data = Data(base64Encoded: value),
                  data.count <= 1_048_576 else {
                throw MCPNativeCapabilityError.invalidArgument(
                    NSLocalizedString("外部 NDEF 记录需要 domain:type 格式和不超过 1 MiB 的有效 Base64 数据。", comment: "Invalid external NDEF data")
                )
            }
            let payload = NFCNDEFPayload(
                format: .nfcExternal,
                type: Data(externalType.utf8),
                identifier: Data(),
                payload: data
            )
            return Self(
                payload: payload,
                preview: ["kind": kind, "external_type": externalType, "byte_count": data.count]
            )
        default:
            throw invalidRecord(kind)
        }
    }

    private static func invalidRecord(_ kind: String) -> MCPNativeCapabilityError {
        .invalidArgument(
            String(
                format: NSLocalizedString("无效的 NDEF 记录类型或内容：%@。", comment: "Invalid NDEF record"),
                kind
            )
        )
    }
}

// CoreNFC 的 Objective-C 对象没有声明 Sendable，但这些引用只在同一个系统会话
// 的串行回调与 MainActor 状态机之间传递，不会脱离 Session 生命周期并发访问。
private struct MCPNativeNFCTagReference: @unchecked Sendable {
    let value: NFCTag
}

private struct MCPNativeNDEFTagReference: @unchecked Sendable {
    let value: NFCNDEFTag
}

private struct MCPNativeNDEFMessageReference: @unchecked Sendable {
    let value: NFCNDEFMessage
}

private struct MCPNativeNDEFPreviewReference: @unchecked Sendable {
    let value: [[String: Any]]
}

@MainActor
private final class MCPNativeNFCSessionController: NSObject {
    static let shared = MCPNativeNFCSessionController()

    private enum Operation {
        case scan(CheckedContinuation<[String: Any], Error>)
        case read(CheckedContinuation<[String: Any], Error>)
        case write(
            message: NFCNDEFMessage,
            preview: [[String: Any]],
            continuation: CheckedContinuation<[String: Any], Error>
        )
    }

    private var operation: Operation?
    private var tagSession: NFCTagReaderSession?

    func scan() async throws -> [String: Any] {
        try ensureIdle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation = .scan(continuation)
                beginTagSession(
                    alertMessage: NSLocalizedString(
                        "请将 iPhone 顶部靠近 NFC 标签。",
                        comment: "NFC scan system prompt"
                    )
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func readNDEF() async throws -> [String: Any] {
        try ensureIdle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation = .read(continuation)
                beginTagSession(
                    alertMessage: NSLocalizedString(
                        "请将 iPhone 顶部靠近要读取的 NFC 标签。",
                        comment: "NFC read system prompt"
                    )
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func writeNDEF(_ records: [MCPNativeNDEFRecord]) async throws -> [String: Any] {
        try ensureIdle()
        let message = NFCNDEFMessage(records: records.map(\.payload))
        let preview = records.map(\.preview)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation = .write(message: message, preview: preview, continuation: continuation)
                beginTagSession(
                    alertMessage: NSLocalizedString(
                        "请核对预览后，将 iPhone 顶部靠近要写入的 NFC 标签。",
                        comment: "NFC write system prompt"
                    )
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func beginTagSession(alertMessage: String) {
        guard let session = NFCTagReaderSession(
            pollingOption: [.iso14443, .iso15693],
            delegate: self,
            queue: nil
        ) else {
            finish(.failure(MCPNativeCapabilityError.unavailable(
                NSLocalizedString("系统无法创建 NFC 标签读取会话。", comment: "NFC tag session creation failed")
            )))
            return
        }
        session.alertMessage = alertMessage
        tagSession = session
        session.begin()
    }

    private func ensureIdle() throws {
        guard operation == nil else {
            throw MCPNativeCapabilityError.unavailable(
                NSLocalizedString("已有 NFC 系统会话正在进行。", comment: "NFC session busy")
            )
        }
    }

    private func cancel() {
        let error = CancellationError()
        tagSession?.invalidate()
        finish(.failure(error))
    }

    private func finish(_ result: Result<[String: Any], Error>, message: String? = nil) {
        guard let operation else { return }
        self.operation = nil
        if let message {
            tagSession?.alertMessage = message
        }
        tagSession?.invalidate()
        tagSession = nil
        switch operation {
        case .scan(let continuation), .read(let continuation):
            continuation.resume(with: result)
        case .write(_, _, let continuation):
            continuation.resume(with: result)
        }
    }

    private func fail(_ error: Error) {
        finish(.failure(error))
    }
}

extension MCPNativeNFCSessionController: NFCTagReaderSessionDelegate {
    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    nonisolated func tagReaderSession(
        _ session: NFCTagReaderSession,
        didInvalidateWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.operation != nil else { return }
            self.fail(error)
        }
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard tags.count == 1, let tag = tags.first else {
            session.alertMessage = NSLocalizedString(
                "检测到多个标签，请一次只靠近一个标签。",
                comment: "Multiple NFC tags detected"
            )
            session.restartPolling()
            return
        }
        let tagReference = MCPNativeNFCTagReference(value: tag)
        session.connect(to: tagReference.value) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.fail(error)
                    return
                }
                switch self.operation {
                case .scan:
                    let payload = self.tagPayload(tagReference.value)
                    self.finish(
                        .success(payload),
                        message: NSLocalizedString("已读取 NFC 标签。", comment: "NFC scan complete")
                    )
                case .read, .write:
                    guard let ndefTag = self.ndefTag(from: tagReference.value) else {
                        self.fail(MCPNativeCapabilityError.unavailable(
                            NSLocalizedString("该标签不支持 NDEF。", comment: "NDEF unsupported")
                        ))
                        return
                    }
                    self.handleConnectedNDEFTag(MCPNativeNDEFTagReference(value: ndefTag))
                case nil:
                    break
                }
            }
        }
    }

    private func ndefTag(from tag: NFCTag) -> NFCNDEFTag? {
        switch tag {
        case .miFare(let value): return value
        case .iso7816(let value): return value
        case .iso15693(let value): return value
        case .feliCa(let value): return value
        @unknown default: return nil
        }
    }

    private func tagPayload(_ tag: NFCTag) -> [String: Any] {
        let type: String
        let identifier: Data
        switch tag {
        case .miFare(let value):
            type = "mifare"
            identifier = value.identifier
        case .iso7816(let value):
            type = "iso7816"
            identifier = value.identifier
        case .iso15693(let value):
            type = "iso15693"
            identifier = value.identifier
        case .feliCa(let value):
            type = "felica"
            identifier = value.currentIDm
        @unknown default:
            type = "unknown"
            identifier = Data()
        }
        return [
            "tag_type": type,
            "identifier_hex": identifier.map { String(format: "%02X", $0) }.joined(),
            "identifier_byte_count": identifier.count
        ]
    }

    private func handleConnectedNDEFTag(_ tag: MCPNativeNDEFTagReference) {
        tag.value.queryNDEFStatus { [weak self] status, capacity, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.fail(error)
                    return
                }
                switch self.operation {
                case .read:
                    guard status != .notSupported else {
                        self.fail(MCPNativeCapabilityError.unavailable(
                            NSLocalizedString("该标签不支持 NDEF。", comment: "NDEF unsupported")
                        ))
                        return
                    }
                    self.read(tag: tag, status: status, capacity: capacity)
                case .write(let message, let preview, _):
                    guard status == .readWrite else {
                        self.fail(MCPNativeCapabilityError.unavailable(
                            NSLocalizedString("该标签不可写入 NDEF。", comment: "NDEF tag not writable")
                        ))
                        return
                    }
                    guard message.length <= capacity else {
                        self.fail(MCPNativeCapabilityError.invalidArgument(
                            NSLocalizedString("NDEF 消息超过标签可用容量。", comment: "NDEF capacity exceeded")
                        ))
                        return
                    }
                    self.write(message: message, preview: preview, to: tag, capacity: capacity)
                default:
                    self.fail(MCPNativeCapabilityError.unavailable(
                        NSLocalizedString("NFC 会话状态已失效。", comment: "Invalid NFC session state")
                    ))
                }
            }
        }
    }

    private func read(tag: MCPNativeNDEFTagReference, status: NFCNDEFStatus, capacity: Int) {
        tag.value.readNDEF { [weak self] message, error in
            let messageReference = message.map { MCPNativeNDEFMessageReference(value: $0) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.fail(error)
                    return
                }
                guard let message = messageReference?.value else {
                    self.fail(MCPNativeCapabilityError.unavailable(
                        NSLocalizedString("标签没有可读取的 NDEF 消息。", comment: "Empty NDEF tag")
                    ))
                    return
                }
                let records = message.records.prefix(32).map(self.payload)
                self.finish(
                    .success([
                        "status": self.statusName(status),
                        "capacity_bytes": capacity,
                        "message_length_bytes": message.length,
                        "record_count": records.count,
                        "records": records,
                        "truncated": message.records.count > records.count
                    ]),
                    message: NSLocalizedString("已读取 NDEF 消息。", comment: "NDEF read complete")
                )
            }
        }
    }

    private func write(
        message: NFCNDEFMessage,
        preview: [[String: Any]],
        to tag: MCPNativeNDEFTagReference,
        capacity: Int
    ) {
        let messageLength = message.length
        let previewReference = MCPNativeNDEFPreviewReference(value: preview)
        tag.value.writeNDEF(message) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.fail(error)
                    return
                }
                self.finish(
                    .success([
                        "written": true,
                        "message_length_bytes": messageLength,
                        "capacity_bytes": capacity,
                        "record_count": previewReference.value.count,
                        "preview": previewReference.value
                    ]),
                    message: NSLocalizedString("NDEF 消息已写入。", comment: "NDEF write complete")
                )
            }
        }
    }

    private func payload(_ record: NFCNDEFPayload) -> [String: Any] {
        let (decodedText, _) = record.wellKnownTypeTextPayload()
        if let text = decodedText {
            return ["kind": "text", "text": String(text.prefix(8_192))]
        }
        if let url = record.wellKnownTypeURIPayload() {
            return ["kind": "uri", "uri": String(url.absoluteString.prefix(8_192))]
        }
        let data = record.payload
        return [
            "kind": record.typeNameFormat == .media ? "mime" : "binary",
            "type": String(data: record.type, encoding: .utf8) ?? record.type.base64EncodedString(),
            "identifier_base64": record.identifier.base64EncodedString(),
            "payload_base64": data.prefix(65_536).base64EncodedString(),
            "payload_byte_count": data.count,
            "truncated": data.count > 65_536
        ]
    }

    private func statusName(_ status: NFCNDEFStatus) -> String {
        switch status {
        case .notSupported: return "not_supported"
        case .readOnly: return "read_only"
        case .readWrite: return "read_write"
        @unknown default: return "unknown"
        }
    }
}
#endif
