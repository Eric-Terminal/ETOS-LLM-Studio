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

    private let session: URLSession
    private let endpoint: URL
    private let batchLimit: Int
    private let requestBodyLimit: Int

    init(
        session: URLSession? = nil,
        endpoint: URL? = nil,
        batchLimit: Int = defaultBatchLimit,
        requestBodyLimit: Int = defaultRequestBodyLimit
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
    }

    func upload(_ files: [TelemetryStoredFile]) async -> TelemetryUploadOutcome {
        let batches = makeBatches(files)
        var confirmed = Set<String>()
        var attempted = Set<String>()
        var errors: [String] = []

        for batch in batches {
            let payloadIDs = Set(batch.map(\.envelope.payloadID))
            attempted.formUnion(payloadIDs)

            do {
                let body = try encode(batch)
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
                    errors.append(NSLocalizedString("性能数据服务暂时不可用，将在下次启动重试。", comment: "Telemetry HTTP failure"))
                    continue
                }

                let decoded = try JSONDecoder().decode(TelemetryUploadResponse.self, from: data)
                guard decoded.schemaVersion == TelemetryEnvelope.currentSchemaVersion else {
                    errors.append(NSLocalizedString("性能数据服务返回了不兼容的响应。", comment: "Telemetry schema mismatch"))
                    continue
                }

                for result in decoded.results where
                    payloadIDs.contains(result.payloadID) &&
                    (result.status == "accepted" || result.status == "duplicate") {
                    confirmed.insert(result.payloadID)
                }
            } catch {
                errors.append(NSLocalizedString("性能数据上传失败，将在下次启动重试。", comment: "Telemetry upload failure"))
            }
        }

        return TelemetryUploadOutcome(
            confirmedPayloadIDs: confirmed,
            attemptedPayloadIDs: attempted,
            errorDescription: errors.first
        )
    }

    private func makeBatches(_ files: [TelemetryStoredFile]) -> [[TelemetryStoredFile]] {
        var result: [[TelemetryStoredFile]] = []
        var current: [TelemetryStoredFile] = []

        for file in files {
            let candidate = current + [file]
            let candidateFits = candidate.count <= batchLimit &&
                ((try? encode(candidate).count) ?? Int.max) <= requestBodyLimit

            if candidateFits {
                current = candidate
                continue
            }

            if !current.isEmpty {
                result.append(current)
                current = []
            }

            let singleFits = ((try? encode([file]).count) ?? Int.max) <= requestBodyLimit
            if singleFits {
                current = [file]
            }
        }

        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private func encode(_ files: [TelemetryStoredFile]) throws -> Data {
        let request = TelemetryUploadRequest(
            schemaVersion: TelemetryEnvelope.currentSchemaVersion,
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
