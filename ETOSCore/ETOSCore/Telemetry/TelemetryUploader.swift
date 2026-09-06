// ============================================================================
// TelemetryUploader.swift
// ============================================================================
// ETOS LLM Studio
//
// 启动期批量上传上一运行遗留的遥测。服务端逐条确认后才允许删除本地文件。
// ============================================================================

import Foundation

struct TelemetryUploadOutcome: Sendable {
    let confirmedPayloadIDs: Set<String>
    let attemptedPayloadIDs: Set<String>
    let errorDescription: String?
}

protocol TelemetryUploading: Sendable {
    func upload(_ files: [TelemetryStoredFile]) async -> TelemetryUploadOutcome
}

private struct TelemetryUploadRequest: Encodable {
    let schemaVersion: Int
    let envelopes: [TelemetryEnvelope]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case envelopes
    }
}

private struct TelemetryUploadResponse: Decodable {
    struct Result: Decodable {
        let payloadID: String
        let status: String

        enum CodingKeys: String, CodingKey {
            case payloadID = "payload_id"
            case status
        }
    }

    let schemaVersion: Int
    let results: [Result]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case results
    }
}

final class TelemetryUploader: TelemetryUploading, @unchecked Sendable {
    static let defaultBatchLimit = 16
    static let defaultRequestBodyLimit = 4 * 1_024 * 1_024
    static let defaultMaxAttempts = 2
    static let defaultRetryDelayNanoseconds: UInt64 = 2_000_000_000

    private let session: URLSession
    private let endpoint: URL
    private let batchLimit: Int
    private let requestBodyLimit: Int
    private let maxAttempts: Int
    private let retryDelayNanoseconds: UInt64

    init(
        session: URLSession? = nil,
        endpoint: URL? = nil,
        batchLimit: Int = defaultBatchLimit,
        requestBodyLimit: Int = defaultRequestBodyLimit,
        maxAttempts: Int = defaultMaxAttempts,
        retryDelayNanoseconds: UInt64 = defaultRetryDelayNanoseconds
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: configuration)
        }

        let baseURL = FeedbackServiceConfig.default.baseURL
        self.endpoint = endpoint ??
            baseURL
                .appendingPathComponent("v1", isDirectory: true)
                .appendingPathComponent("telemetry", isDirectory: false)
        self.batchLimit = max(1, min(batchLimit, 16))
        self.requestBodyLimit = max(1_024, requestBodyLimit)
        self.maxAttempts = max(1, min(maxAttempts, 3))
        self.retryDelayNanoseconds = retryDelayNanoseconds
    }

    func upload(_ files: [TelemetryStoredFile]) async -> TelemetryUploadOutcome {
        let batches = makeBatches(files)
        var confirmed = Set<String>()
        var attempted = Set<String>()
        var errors: [String] = []

        for batch in batches {
            let payloadIDs = Set(batch.map(\.envelope.payloadID))
            attempted.formUnion(payloadIDs)
            var pending = batch
            var lastError: String?

            for attempt in 0..<maxAttempts {
                guard !Task.isCancelled, !pending.isEmpty else { break }
                let result = await uploadBatch(pending)
                confirmed.formUnion(result.confirmedPayloadIDs)
                pending.removeAll {
                    result.confirmedPayloadIDs.contains($0.envelope.payloadID)
                }
                if pending.isEmpty {
                    lastError = nil
                    break
                }

                lastError = result.errorDescription ?? NSLocalizedString(
                    "性能数据服务返回了不兼容的响应。",
                    comment: "Telemetry incomplete response"
                )
                guard attempt + 1 < maxAttempts else { break }
                do {
                    try await Task.sleep(nanoseconds: retryDelayNanoseconds)
                } catch {
                    break
                }
            }

            if !pending.isEmpty {
                errors.append(
                    lastError ?? NSLocalizedString(
                        "性能数据上传失败，将在下次启动重试。",
                        comment: "Telemetry upload failure"
                    )
                )
            }
        }

        return TelemetryUploadOutcome(
            confirmedPayloadIDs: confirmed,
            attemptedPayloadIDs: attempted,
            errorDescription: errors.first
        )
    }

    private func uploadBatch(
        _ files: [TelemetryStoredFile]
    ) async -> (
        confirmedPayloadIDs: Set<String>,
        errorDescription: String?
    ) {
        let payloadIDs = Set(files.map(\.envelope.payloadID))
        guard let schemaVersion = files.first?.envelope.schemaVersion,
              files.allSatisfy({ $0.envelope.schemaVersion == schemaVersion }) else {
            return (
                [],
                NSLocalizedString(
                    "性能数据服务返回了不兼容的响应。",
                    comment: "Telemetry incompatible response"
                )
            )
        }
        do {
            let body = try encode(files)
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = body
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return (
                    [],
                    NSLocalizedString(
                        "性能数据服务暂时不可用，将在下次启动重试。",
                        comment: "Telemetry HTTP failure"
                    )
                )
            }

            let decoded = try JSONDecoder().decode(TelemetryUploadResponse.self, from: data)
            guard decoded.schemaVersion == schemaVersion else {
                return (
                    [],
                    NSLocalizedString(
                        "性能数据服务返回了不兼容的响应。",
                        comment: "Telemetry schema mismatch"
                    )
                )
            }

            let confirmed = Set<String>(decoded.results.compactMap { result -> String? in
                guard payloadIDs.contains(result.payloadID),
                      result.status == "accepted" || result.status == "duplicate" else {
                    return nil
                }
                return result.payloadID
            })
            return (confirmed, nil)
        } catch {
            return (
                [],
                NSLocalizedString(
                    "性能数据上传失败，将在下次启动重试。",
                    comment: "Telemetry upload failure"
                )
            )
        }
    }

    private func makeBatches(_ files: [TelemetryStoredFile]) -> [[TelemetryStoredFile]] {
        var result: [[TelemetryStoredFile]] = []
        var current: [TelemetryStoredFile] = []
        var estimatedBytes = 64

        for file in files {
            let candidateBytes = estimatedBytes + file.data.count + 1
            let hasMatchingSchema = current.isEmpty ||
                current.first?.envelope.schemaVersion == file.envelope.schemaVersion
            let candidateFits = current.count < batchLimit &&
                hasMatchingSchema &&
                candidateBytes <= requestBodyLimit

            if candidateFits {
                current.append(file)
                estimatedBytes = candidateBytes
                continue
            }

            if !current.isEmpty {
                result.append(current)
                current = []
                estimatedBytes = 64
            }

            let singleFits = estimatedBytes + file.data.count + 1 <= requestBodyLimit
            if singleFits {
                current = [file]
                estimatedBytes += file.data.count + 1
            }
        }

        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private func encode(_ files: [TelemetryStoredFile]) throws -> Data {
        guard let schemaVersion = files.first?.envelope.schemaVersion,
              files.allSatisfy({ $0.envelope.schemaVersion == schemaVersion }) else {
            throw EncodingError.invalidValue(
                files.map(\.envelope.schemaVersion),
                .init(codingPath: [], debugDescription: "遥测上传批次包含多个协议版本。")
            )
        }
        let request = TelemetryUploadRequest(
            schemaVersion: schemaVersion,
            envelopes: files.map(\.envelope)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(request)
    }

    private static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        return "ETOS LLM Studio/\(version) (iOS; MetricKit Telemetry)"
    }
}
