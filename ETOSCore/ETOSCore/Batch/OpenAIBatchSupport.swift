import Foundation
import CryptoKit

/// 延续 PR #157 的 JSONL → 文件上传 → Batch → 文件下载流程，复用现有聊天请求构造器。
enum OpenAIBatchSupport {
    static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func headersDigest(_ provider: Provider) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: provider.headerOverrides, options: .sortedKeys)
        return digest(String(decoding: data, as: UTF8.self))
    }

    static func supports(_ model: RunnableModel) -> Bool {
        ["openai-compatible", "openai-responses"].contains(model.effectiveAPIFormat) && model.model.kind == .chat
    }

    static func prepare(title: String, inputs: [String], model: RunnableModel, temperature: Double?, topP: Double?) throws -> BatchJob {
        guard supports(model) else { throw BatchError.unsupportedModel }
        guard !inputs.isEmpty, inputs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              let key = model.provider.nextAPIKey() else { throw BatchError.invalidInput }
        let adapter: any APIAdapter = model.effectiveAPIFormat == "openai-responses" ? OpenAIResponsesAdapter() : OpenAIAdapter()
        var common: [String: Any] = ["stream": false, providerAPIKeyControlKey: key, requestLogSuppressionControlKey: true]
        if let temperature { common["temperature"] = temperature }
        if let topP { common["top_p"] = topP }
        var endpoint: String?
        var items: [BatchRequestItem] = []
        for input in inputs {
            guard let request = adapter.buildChatRequest(for: model, commonPayload: common,
                    messages: [ChatMessage(role: .user, content: input)], tools: nil,
                    audioAttachments: [:], imageAttachments: [:], fileAttachments: [:]),
                  let data = request.httpBody,
                  var body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = request.url?.path else { throw BatchError.invalidInput }
            // Batch 禁止流式与跨请求会话续接；自定义 Body 也不能把它们重新打开。
            body["stream"] = false
            for key in ["stream_options", "background", "previous_response_id", "conversation"] { body.removeValue(forKey: key) }
            let resolvedEndpoint = path.hasSuffix("/responses") ? "/v1/responses" : "/v1/chat/completions"
            if let endpoint, endpoint != resolvedEndpoint { throw BatchError.unsupportedModel }
            endpoint = resolvedEndpoint
            let encoded = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
            items.append(BatchRequestItem(id: UUID().uuidString, input: input,
                                          body: try JSONDecoder().decode(JSONValue.self, from: encoded)))
        }
        return BatchJob(id: UUID(), title: title, providerID: model.provider.id, modelID: model.model.id,
                        providerName: model.provider.name, modelName: model.model.modelName,
                        baseURL: model.provider.baseURL, credentialDigest: digest(key),
                        headersDigest: try headersDigest(model.provider), endpoint: endpoint!, requests: items)
    }

    static func jsonl(_ job: BatchJob) throws -> Data {
        var data = Data()
        for item in job.requests {
            let value: JSONValue = .dictionary([
                "custom_id": .string(item.id), "method": .string("POST"),
                "url": .string(job.endpoint), "body": item.body
            ])
            data.append(try JSONEncoder().encode(value))
            data.append(0x0A)
        }
        return data
    }

    static func credentials(for job: BatchJob, providers: [Provider] = ConfigLoader.loadProviders()) throws -> (Provider, String) {
        guard let provider = providers.first(where: { $0.id == job.providerID }),
              provider.baseURL == job.baseURL, try headersDigest(provider) == job.headersDigest,
              let key = ProviderCredentialStore.normalizeAPIKeys(provider.apiKeys).first(where: { digest($0) == job.credentialDigest }) else {
            throw BatchError.credentialsChanged
        }
        return (provider, key)
    }

    static func request(provider: Provider, key: String, path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard let base = URL(string: provider.baseURL), ["https", "http"].contains(base.scheme?.lowercased() ?? ""),
              base.host != nil else { throw BatchError.invalidInput }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 120
        request.httpBody = body
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaderOverrides(provider.headerOverrides, apiKey: key, to: &request)
        return request
    }

    static func upload(_ job: BatchJob, provider: Provider, key: String) throws -> URLRequest {
        var request = try request(provider: provider, key: key, path: "files", method: "POST")
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.appendMultipartField(name: "purpose", value: "batch", boundary: boundary)
        body.appendMultipartFile(name: "file", fileName: "batch.jsonl", mimeType: "application/jsonl",
                                 data: try jsonl(job), boundary: boundary)
        body.appendString("--\(boundary)--\r\n")
        request.httpBody = body
        return request
    }

    static func parseResults(_ data: Data, knownIDs: Set<String>) throws -> [BatchResult] {
        struct Line: Decodable {
            var custom_id: String
            var response: Response?
            var error: JSONValue?
            struct Response: Decodable { var status_code: Int; var body: JSONValue? }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw BatchError.invalidResponse }
        return try text.split(whereSeparator: \.isNewline).map { line in
            let raw = Data(line.utf8)
            let item = try JSONDecoder().decode(Line.self, from: raw)
            guard knownIDs.contains(item.custom_id) else { throw BatchError.invalidResponse }
            var result = BatchResult(id: item.custom_id, rawResponse: try JSONDecoder().decode(JSONValue.self, from: raw))
            if let response = item.response, (200...299).contains(response.status_code), let body = response.body,
               item.error == nil || item.error == .null {
                do {
                    let message = try OpenAIAdapter().parseResponse(data: JSONEncoder().encode(body))
                    result.text = message.content
                    result.reasoning = message.reasoningContent
                } catch { result.error = error.localizedDescription }
            } else {
                let error = item.error.flatMap { $0 == .null ? nil : $0 } ?? item.response?.body
                if case .dictionary(let fields) = error, case .string(let message) = fields["message"] {
                    result.error = message
                } else {
                    result.error = error.map { String(describing: $0.toAny()) } ?? BatchError.invalidResponse.localizedDescription
                }
            }
            return result
        }
    }
}
