import Foundation
import Testing
@testable import ETOSCore

@Suite("Gemini Interactions 适配器", .serialized)
struct GeminiInteractionsAdapterTests {
    private let adapter = GeminiInteractionsAdapter()

    private func runnable(baseURL: String = "https://generativelanguage.googleapis.com/v1", overrides: [String: JSONValue] = [:]) -> RunnableModel {
        let model = Model(modelName: "gemini-flash-latest", overrideParameters: overrides)
        return RunnableModel(
            provider: Provider(name: "测试", baseURL: baseURL, apiKeys: ["test-key"], apiFormat: "gemini-interactions"),
            model: model, requestBodyControlState: model.defaultRequestBodyControlState
        )
    }

    private func payload(_ request: URLRequest?) throws -> [String: Any] {
        let request = try #require(request)
        return try #require(JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any])
    }

    private func request(messages: [ChatMessage], common: [String: Any] = [:], model: RunnableModel? = nil) -> URLRequest? {
        adapter.buildChatRequest(
            for: model ?? runnable(), commonPayload: common.merging([requestLogSuppressionControlKey: true]) { _, value in value },
            messages: messages, tools: nil, audioAttachments: [:], imageAttachments: [:], fileAttachments: [:]
        )
    }

    private func event(_ value: [String: Any]) throws -> ChatMessagePart {
        let data = try JSONSerialization.data(withJSONObject: value)
        return try #require(adapter.parseStreamingResponse(line: "data: " + String(decoding: data, as: UTF8.self)))
    }

    @Test("请求使用步骤协议、原生思考字段与固定流模式，不泄漏内部控制参数")
    func requestContract() throws {
        let model = runnable(overrides: [
            "model": .string("selected-model"),
            "generation_config": .dictionary(["thinking_level": .string("high")]),
            "stream": .bool(false), "previous_interaction_id": .string("old"), "background": .bool(true)
        ])
        let call = InternalToolCall(id: "call-1", toolName: "天气 查询", arguments: #"{"city":"上海"}"#)
        let messages = [ChatMessage(role: .system, content: "系统一"), ChatMessage(role: .user, content: "问题"),
                        ChatMessage(role: .system, content: "系统二"), ChatMessage(role: .assistant, content: "", toolCalls: [call]),
                        ChatMessage(role: .tool, content: "晴", toolCalls: [call])]
        let built = try #require(request(messages: messages, common: ["stream": true, "max_tokens": 128, "temperature": 0.3,
                                             "top_p": 0.5, "top_k": 20, providerAPIKeyControlKey: "controlled"], model: model))
        let body = try payload(built)
        #expect(built.url?.absoluteString == "https://generativelanguage.googleapis.com/v1/interactions")
        #expect(built.value(forHTTPHeaderField: "x-goog-api-key") == "controlled")
        #expect(built.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(body["model"] as? String == "selected-model")
        #expect(body["system_instruction"] as? String == "系统一\n\n系统二")
        #expect(body["stream"] as? Bool == true)
        #expect(body["store"] as? Bool == false)
        for key in ["previous_interaction_id", "background", "temperature", "top_p", "top_k", "contents", providerAPIKeyControlKey, requestLogSuppressionControlKey] {
            #expect(body[key] == nil)
        }
        let config = try #require(body["generation_config"] as? [String: Any])
        #expect(config["thinking_level"] as? String == "high")
        #expect(config["max_output_tokens"] as? Int == 128)
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.compactMap { $0["type"] as? String } == ["user_input", "function_call", "function_result"])
        #expect(input[1]["id"] as? String == "call-1")
        #expect(input[2]["call_id"] as? String == "call-1")
        #expect(input[1]["name"] as? String == input[2]["name"] as? String)
    }

    @Test("多模态使用类型化内容，视频 URI 优先于问题，工具 schema 保留 JSON Schema 语义")
    func attachmentsAndTools() throws {
        let message = ChatMessage(role: .user, content: "查看附件")
        let video = FileAttachment(data: Data([1]), mimeType: "video/mp4", fileName: "video.mp4", remoteFileURI: "https://example.invalid/files/1")
        let pdf = FileAttachment(data: Data([2]), mimeType: "application/pdf", fileName: "doc.pdf")
        let image = ImageAttachment(data: Data([3]), mimeType: "image/png", fileName: "image.png")
        let audio = AudioAttachment(data: Data([4]), mimeType: "audio/mpeg", format: "mp3", fileName: "audio.mp3")
        let schema: JSONValue = .dictionary(["type": .string("object"), "properties": .dictionary([
            "value": .dictionary(["type": .array([.string("string"), .string("null")])])
        ]), "additionalProperties": .bool(false)])
        let body = try payload(adapter.buildChatRequest(
            for: runnable(), commonPayload: [requestLogSuppressionControlKey: true], messages: [message],
            tools: [.init(name: "lookup", description: "查询", parameters: schema)],
            audioAttachments: [message.id: audio], imageAttachments: [message.id: [image]], fileAttachments: [message.id: [video, pdf]]
        ))
        let input = try #require(body["input"] as? [[String: Any]])
        let content = try #require(input.first?["content"] as? [[String: Any]])
        #expect(content.compactMap { $0["type"] as? String } == ["video", "text", "image", "audio", "document"])
        #expect(content.first?["uri"] as? String == video.remoteFileURI)
        #expect(content.first?["data"] == nil)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.first?["type"] as? String == "function")
        let encoded = try JSONSerialization.data(withJSONObject: #require(tools.first?["parameters"]))
        #expect(try JSONDecoder().decode(JSONValue.self, from: encoded) == schema)
    }

    @Test("非流式响应保留步骤顺序、签名和用量，编辑后不回放旧消息")
    func responseAndReplay() throws {
        let response = Data(#"{"status":"requires_action","steps":[{"type":"thought","signature":"sig-a","summary":[{"type":"text","text":"思考"}]},{"type":"model_output","content":[{"type":"text","text":"查询中"}]},{"type":"function_call","id":"call-1","name":"lookup","arguments":{"q":"天气"}}],"usage":{"total_input_tokens":20,"total_output_tokens":8,"total_thought_tokens":6,"total_cached_tokens":10,"total_tokens":34}}"#.utf8)
        var message = try adapter.parseResponse(data: response)
        #expect(message.content == "查询中")
        #expect(message.reasoningContent == "思考")
        #expect(message.tokenUsage?.thinkingTokens == 6)
        #expect(message.tokenUsage?.cacheReadTokens == 10)
        #expect(message.tokenUsage?.totalTokens == 34)
        let steps = try #require(try payload(request(messages: [message]))["input"] as? [[String: Any]])
        #expect(steps.compactMap { $0["type"] as? String } == ["thought", "model_output", "function_call"])
        #expect(steps.first?["signature"] as? String == "sig-a")
        let requiredSteps = try #require(try payload(request(messages: [message], common: [ReasoningContentEchoPayload.key: "never"]))["input"] as? [[String: Any]])
        #expect(requiredSteps.first?["signature"] as? String == "sig-a")
        #expect((requiredSteps.first?["summary"] as? [[String: String]])?.first?["text"] == "思考")
        message.content = "已编辑"
        let edited = try #require(try payload(request(messages: [message]))["input"] as? [[String: Any]])
        #expect(!edited.contains { $0["type"] as? String == "thought" })
        #expect((edited.first?["content"] as? [[String: Any]])?.first?["text"] as? String == "已编辑")
    }

    @Test("普通响应收敛保留 Interactions 正文原貌，关闭思考回传也保留必需签名")
    func responseFinalizationPreservesReplay() throws {
        let service = ChatService()
        for content in ["\n  缩进正文  \n", "<think>正文中的示例</think>\n答案"] {
            let data = try JSONSerialization.data(withJSONObject: [
                "status": "completed", "steps": [
                    ["type": "thought", "signature": "required-signature"],
                    ["type": "model_output", "content": [["type": "text", "text": content]]]
                ]
            ])
            var message = try adapter.parseResponse(data: data)
            let finalized = service.parseResponseThoughtTags(from: message)
            #expect(finalized.content == content)
            #expect(finalized.reasoning.isEmpty)
            message.content = finalized.content
            for mode in ReasoningContentEchoMode.allCases {
                let body = try payload(request(messages: [message], common: [ReasoningContentEchoPayload.key: mode.rawValue]))
                let steps = try #require(body["input"] as? [[String: Any]])
                #expect(steps.first?["signature"] as? String == "required-signature")
                #expect((steps.last?["content"] as? [[String: String]])?.first?["text"] == content)
            }
        }
        let legacy = service.parseResponseThoughtTags(from: ChatMessage(role: .assistant, content: "<think>推理</think> 答案 "))
        #expect(legacy.content == "答案")
        #expect(legacy.reasoning == "推理")
    }

    @Test("流式工具参数与思考签名按消息累积，并发流互不污染")
    func streamingReplayAndIsolation() throws {
        let events: [[String: Any]] = [
            ["event_type": "step.start", "index": 0, "step": ["type": "thought"]],
            ["event_type": "step.delta", "index": 0, "delta": ["type": "thought_summary", "content": ["type": "text", "text": "准备查询"]]],
            ["event_type": "step.delta", "index": 0, "delta": ["type": "thought_signature", "signature": "sig-stream"]],
            ["event_type": "step.start", "index": 1, "step": ["type": "function_call", "id": "call-stream", "name": "lookup", "arguments": [:]]],
            ["event_type": "step.delta", "index": 1, "delta": ["type": "arguments_delta", "arguments": "{\"q\":"]],
            ["event_type": "step.delta", "index": 1, "delta": ["type": "arguments_delta", "arguments": "\"天气\"}"]],
            ["event_type": "step.stop", "index": 1]
        ]
        var stored: JSONValue?
        var arguments = ""
        var reasoning = ""
        for value in events {
            let part = try event(value)
            reasoning += part.reasoningContent ?? ""
            if let metadata = part.providerResponseMetadata?[GeminiInteractionsAdapter.stepsKey] {
                stored = GeminiInteractionsAdapter.mergingSteps(existing: stored, incoming: metadata)
            }
            for delta in part.toolCallDeltas ?? [] {
                if let replacement = delta.argumentsReplacement { arguments = replacement }
                else { arguments += delta.argumentsFragment ?? "" }
            }
            #expect(part.streamTermination == nil)
            // 同一适配器交错解析另一条会话，状态必须仍完全属于各自消息。
            let other = try event(["event_type": "step.delta", "index": 0, "delta": ["type": "text", "text": "其他会话"]])
            #expect(other.content == "其他会话")
        }
        #expect(arguments == #"{"q":"天气"}"#)
        #expect(reasoning == "准备查询")
        let message = ChatMessage(role: .assistant, content: "", reasoningContent: reasoning,
            providerResponseMetadata: [GeminiInteractionsAdapter.stepsKey: try #require(stored)],
            toolCalls: [.init(id: "call-stream", toolName: "lookup", arguments: arguments)])
        let body = try payload(request(messages: [message]))
        let steps = try #require(body["input"] as? [[String: Any]])
        #expect(steps.count == 2)
        #expect(steps.first?["signature"] as? String == "sig-stream")
        #expect((steps.last?["arguments"] as? [String: String])?["q"] == "天气")
    }

    @Test("流结束、错误和截断状态有明确语义，完成事件不重复正文")
    func streamingTermination() throws {
        for status in ["completed", "requires_action"] {
            let part = try event(["event_type": "interaction.completed", "interaction": ["status": status,
                "usage": ["total_input_tokens": 12, "total_output_tokens": 3, "total_tokens": 15],
                "steps": [["type": "model_output", "content": [["type": "text", "text": "重复全文"]]]]]])
            #expect(part.streamTermination == .completed)
            #expect(part.content == nil)
            #expect(part.tokenUsage?.totalTokens == 15)
        }
        for status in ["failed", "cancelled", "incomplete", "in_progress"] {
            let part = try event(["event_type": "interaction.completed", "interaction": ["status": status]])
            guard case .failed = part.streamTermination else { Issue.record("异常状态不能视为成功"); continue }
            let data = try JSONSerialization.data(withJSONObject: ["status": status, "steps": []])
            #expect(throws: (any Error).self) { try adapter.parseResponse(data: data) }
        }
        let waiting = try event(["event_type": "interaction.status_update", "status": "requires_action"])
        #expect(waiting.streamTermination == nil)
        #expect(try event(["event_type": "error", "error": ["message": "quota"]]).streamTermination == .failed(reason: "quota"))
        #expect(adapter.parseStreamingResponse(line: "data: [DONE]") == nil)
        #expect(adapter.parseStreamingResponse(line: "event: step.delta") == nil)
        #expect(adapter.requiresExplicitStreamingTermination)
    }

    @Test("文本增量与引用归入模型输出步骤，默认响应日志隐藏原生步骤")
    func streamedTextAndLogRedaction() throws {
        let events: [[String: Any]] = [
            ["event_type": "step.start", "index": 2, "step": ["type": "model_output"]],
            ["event_type": "step.delta", "index": 2, "delta": ["type": "text", "text": "答"]],
            ["event_type": "step.delta", "index": 2, "delta": ["type": "text", "text": "案"]],
            ["event_type": "step.delta", "index": 2, "delta": ["type": "text_annotation_delta", "annotations": [["type": "url_citation", "url": "https://example.invalid"]]]]
        ]
        var stored: JSONValue?
        for value in events {
            let part = try event(value)
            if let incoming = part.providerResponseMetadata?[GeminiInteractionsAdapter.stepsKey] {
                stored = GeminiInteractionsAdapter.mergingSteps(existing: stored, incoming: incoming)
            }
        }
        let message = ChatMessage(role: .assistant, content: "答案", providerResponseMetadata: [GeminiInteractionsAdapter.stepsKey: try #require(stored)])
        let steps = try #require(adapter.replaySteps(for: message))
        let content = try #require(steps.first?["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "答案")
        #expect((content.first?["annotations"] as? [[String: String]])?.count == 1)
        let response = #"{"status":"completed","steps":[{"type":"thought","signature":"private-signature"}]}"#
        #expect(!AppLogRedactor.sanitizeResponseBodyForLog(response, exposesMessageFields: false).contains("private-signature"))
        let stream = #"data: {"event_type":"step.start","step":{"type":"thought","signature":"private-signature"}}"#
        #expect(!AppLogRedactor.sanitizeResponseBodyForLog(stream, exposesMessageFields: false).contains("private-signature"))
    }

    @Test("向导真实流式消费保留签名，零参数工具无需等待参数分片")
    func guideStreamRetainsNativeSteps() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiInteractionsGuideURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = ChatService(urlSession: session)
        let model = runnable(baseURL: "https://interactions.test/v1")
        let message = try await service.generateGuideChatCompletion(
            messages: [ChatMessage(role: .user, content: "查看当前页面")],
            tools: [.init(name: "inspect_page", description: "读取页面", parameters: .dictionary(["type": .string("object")]))],
            runnableModel: model, onContentDelta: { _ in }
        )
        #expect(message.toolCalls?.first?.arguments == "{}")
        let replay = try #require(adapter.replaySteps(for: message))
        #expect(replay.first?["signature"] as? String == "guide-signature")
        #expect(replay.last?["id"] as? String == "guide-call")
        #expect((replay.last?["arguments"] as? [String: String])?.isEmpty == true)
    }

    @Test("基础地址保留网关版本，模型列表不过滤仅支持新协议的模型")
    func discoveryAndAuthentication() throws {
        for (base, path) in [("https://generativelanguage.googleapis.com", "/v1/interactions"),
                             ("https://proxy.invalid/google/v1beta", "/google/v1beta/interactions"),
                             ("https://generativelanguage.googleapis.com/v1beta/openai", "/v1beta/interactions")] {
            let request = try #require(request(messages: [ChatMessage(role: .user, content: "你好")], model: runnable(baseURL: base)))
            #expect(request.url?.path == path)
            #expect(request.url?.query == nil)
        }
        let models = try adapter.parseModelListResponse(data: Data(#"{"models":[{"name":"models/new-model","supportedGenerationMethods":["createInteraction"]},{"name":"models/gemini-embedding-001","supportedGenerationMethods":["embedContent"]}]}"#.utf8))
        #expect(models.map(\.modelName) == ["new-model", "gemini-embedding-001"])
        #expect(models.last?.kind == .embedding)
        let list = try #require(adapter.buildModelListRequest(for: runnable().provider))
        #expect(list.url?.path == "/v1/models")
        var provider = runnable().provider
        provider.apiKeys = ["test-key", "next-key"]
        provider.multiKeyEnabled = true
        let rotated = provider.rotatingAPIKey(in: list, apiFormat: "gemini-interactions")
        #expect(rotated.value(forHTTPHeaderField: "x-goog-api-key") == "next-key")
        #expect(rotated.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("图片生成使用 Interactions，嵌入仍使用 Gemini 原生端点")
    func imageAndEmbeddingOperations() throws {
        let imageRequest = try #require(adapter.buildImageGenerationRequest(for: runnable(), prompt: "画一只猫", referenceImages: []))
        let body = try payload(imageRequest)
        #expect(imageRequest.url?.path == "/v1/interactions")
        #expect((body["response_format"] as? [[String: String]])?.first?["type"] == "image")
        #expect((body["response_format"] as? [[String: String]])?.first?["delivery"] == "inline")
        #expect(body["stream"] as? Bool == false)
        let images = try adapter.parseImageGenerationResponse(data: Data(#"{"status":"completed","steps":[{"type":"model_output","content":[{"type":"text","text":"猫"},{"type":"image","mime_type":"image/png","data":"AQID"}]}]}"#.utf8))
        #expect(images.first?.data == Data([1, 2, 3]))
        #expect(images.first?.revisedPrompt == "猫")
        let embedding = try #require(adapter.buildEmbeddingRequest(for: runnable(), texts: ["你好"]))
        #expect(embedding.url?.path.contains("embedContent") == true)
    }

    @Test("官方视频上传独立使用 Files 版本，上传与状态查询保留网关路径")
    func videoFilesAPIVersion() throws {
        for (base, upload, status) in [
            ("https://generativelanguage.googleapis.com/v1", "/upload/v1beta/files", "/v1beta/files/video"),
            ("https://generativelanguage.googleapis.com", "/upload/v1beta/files", "/v1beta/files/video"),
            ("https://proxy.invalid/google/v1", "/google/upload/v1/files", "/google/v1/files/video"),
            ("https://proxy.invalid/google", "/google/upload/v1beta/files", "/google/v1beta/files/video")
        ] {
            let url = try #require(URL(string: base))
            #expect(GeminiVideoUploadRequestBuilder.uploadStartURL(from: url)?.path == upload)
            #expect(GeminiVideoUploadRequestBuilder.statusURL(from: url, fileName: "files/video")?.path == status)
        }
    }

    @Test("视频换 Key 只替换原生视频 URI，不改写文本和工具参数")
    func videoRebinding() throws {
        let id = UUID()
        let old = FileAttachment(data: Data([1]), mimeType: "video/mp4", fileName: "v.mp4", remoteFileURI: "old-uri")
        let new = FileAttachment(data: Data([1]), mimeType: "video/mp4", fileName: "v.mp4", remoteFileURI: "new-uri")
        var original = URLRequest(url: URL(string: "https://example.invalid/v1/interactions")!)
        original.httpBody = Data(#"{"input":[{"type":"user_input","content":[{"type":"video","uri":"old-uri"},{"type":"text","text":"old-uri"}]},{"type":"function_call","arguments":{"uri":"old-uri"}}]}"#.utf8)
        let updated = try GeminiVideoRequestRebinding.replacingFileReferences(in: original, previous: [id: [old]], updated: [id: [new]])
        let input = try #require(try payload(updated)["input"] as? [[String: Any]])
        let content = try #require(input.first?["content"] as? [[String: Any]])
        #expect(content.first?["uri"] as? String == "new-uri")
        #expect(content.last?["text"] as? String == "old-uri")
        #expect((input.last?["arguments"] as? [String: String])?["uri"] == "old-uri")
    }

    @Test("协议分类、同步、导入、思考控制与向导知识保留独立格式")
    func configurationIntegration() throws {
        #expect(ProviderAPIFormatOption.allCases.contains(.geminiInteractions))
        #expect(ProviderAPIFormatFamily(apiFormat: "gemini-interactions") == .geminiInteractions)
        #expect(SyncEngine.canonicalProviderAPIFormat("gemini-interactions") == "gemini-interactions")
        #expect(ThirdPartyImportService.normalizeProviderFormat(typeHint: "gemini-interactions", modelIDs: []) == "gemini-interactions")
        #expect(ThirdPartyImportService.normalizeBaseURL(nil, for: "gemini-interactions") == "https://generativelanguage.googleapis.com/v1")
        let control = ModelRequestBodyControlDefaults.thinkingOptionGroup(for: "gemini-interactions")
        #expect(control.options.map(\.id) == ["minimal", "low", "medium", "high"])
        #expect(control.options.allSatisfy { $0.payload["generationConfig"] == nil && $0.payload["generation_config"] != nil })
        #expect(ModelRequestBodyControlDefaults.isThinkingControl(control))
        let toggle = ModelRequestBodyControlDefaults.initialToggleControl(existingControls: [], apiFormat: "gemini-interactions")
        #expect(toggle.payload["temperature"] == nil)
        #expect(toggle.payload["generation_config"] == .dictionary(["max_output_tokens": .int(8192)]))
        let document = try #require(GuideDocumentCatalog.documents.first { $0.id == "provider-model-basics" })
        #expect(document.content.contains("gemini-interactions"))
        #expect(document.content.contains("store=false"))
        let provider = runnable().provider
        let proposal = try GuideProviderModelsProposalSupport.buildProposal(
            call: InternalToolCall(id: "configure", toolName: GuideToolCatalog.updateProviderModels.name,
                arguments: #"{"models":[{"model_id":"video-model","api_format_override":"gemini-interactions","input_modalities":["text","video"]}]}"#),
            pageID: "provider-models", provider: provider
        )
        let updated = try GuideProviderModelsProposalSupport.apply(proposal, to: provider).provider
        #expect(updated.models.first?.apiFormatOverride == "gemini-interactions")
        #expect(updated.models.first?.inputModalities.contains(.video) == true)
    }
}

private final class GeminiInteractionsGuideURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "interactions.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let stream = """
        data: {"event_type":"step.start","index":0,"step":{"type":"thought"}}

        data: {"event_type":"step.delta","index":0,"delta":{"type":"thought_signature","signature":"guide-signature"}}

        data: {"event_type":"step.start","index":1,"step":{"type":"function_call","name":"inspect_page","id":"guide-call"}}

        data: {"event_type":"step.stop","index":1}

        data: {"event_type":"interaction.completed","interaction":{"id":"interaction-guide","status":"requires_action"}}


        """
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stream.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
