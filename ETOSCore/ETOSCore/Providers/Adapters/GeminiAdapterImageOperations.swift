// ============================================================================
// GeminiAdapterImageOperations.swift
// ============================================================================
// ETOS LLM Studio
//
// Gemini 适配器的图像生成请求与响应解析逻辑。
// ============================================================================

import Foundation
import os.log

extension GeminiAdapter {
    public func buildImageGenerationRequest(for model: RunnableModel, prompt: String, referenceImages: [ImageAttachment]) -> URLRequest? {
        guard let baseURL = normalizedGeminiBaseURL(from: model.provider.baseURL) else {
            logger.error("构建 Gemini 生图请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }

        guard let apiKey = model.provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建 Gemini 生图请求失败: 提供商 '\(model.provider.name)' 缺少有效的 API Key")
            return nil
        }

        let requestModelName = resolvedRequestModelName(
            for: model,
            overrides: model.effectiveOverrideParameters.mapValues { $0.toAny() }
        )
        var imageURL = baseURL.appendingPathComponent("models/\(requestModelName):generateContent")
        var urlComponents = URLComponents(url: imageURL, resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        imageURL = urlComponents.url!

        var request = URLRequest(url: imageURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: apiKey, to: &request)

        let overrides = model.effectiveOverrideParameters.mapValues { $0.toAny() }
        var parts: [[String: Any]] = []
        if referenceImages.isEmpty {
            parts.append(["text": prompt])
        } else {
            // 与 Gemini 官方示例保持一致：先给参考图，再给编辑指令文本。
            for image in referenceImages {
                parts.append([
                    "inline_data": [
                        "mime_type": image.mimeType,
                        "data": image.data.base64EncodedString()
                    ]
                ])
            }
            parts.append(["text": prompt])
        }

        var payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": parts
                ]
            ]
        ]

        var generationConfig: [String: Any] = [:]
        if let temperature = overrides["temperature"] {
            generationConfig["temperature"] = temperature
        }
        if let topP = overrides["top_p"] {
            generationConfig["topP"] = topP
        }
        if let topK = overrides["top_k"] {
            generationConfig["topK"] = topK
        }
        if let maxTokens = overrides["max_tokens"] {
            generationConfig["maxOutputTokens"] = maxTokens
        }
        if let responseModalities = overrides["response_modalities"] ?? overrides["responseModalities"] {
            generationConfig["responseModalities"] = responseModalities
        } else {
            generationConfig["responseModalities"] = ["IMAGE"]
        }
        payload["generationConfig"] = generationConfig

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            return request
        } catch {
            logger.error("构建 Gemini 生图请求失败: JSON 序列化错误 - \(error.localizedDescription)")
            return nil
        }
    }

    public func parseImageGenerationResponse(data: Data) throws -> [GeneratedImageResult] {
        let response = try JSONDecoder().decode(GeminiResponse.self, from: data)
        if let error = response.error {
            throw NSError(domain: "GeminiImageAPIError", code: error.code ?? -1, userInfo: [NSLocalizedDescriptionKey: error.message ?? "未知错误"])
        }

        var results: [GeneratedImageResult] = []
        var revisedPrompts: [String] = []

        for candidate in response.candidates ?? [] {
            for part in candidate.content?.parts ?? [] {
                if let text = part.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    revisedPrompts.append(text)
                }
                if let inlineData = part.inlineData,
                   let b64 = inlineData.data,
                   let imageData = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
                    let mimeType = inlineData.mimeType ?? inferredImageMimeType(from: imageData)
                    results.append(GeneratedImageResult(
                        data: imageData,
                        mimeType: mimeType,
                        remoteURL: nil,
                        revisedPrompt: nil
                    ))
                }
            }
        }

        let revisedPrompt = revisedPrompts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !revisedPrompt.isEmpty {
            results = results.map { result in
                GeneratedImageResult(
                    data: result.data,
                    mimeType: result.mimeType,
                    remoteURL: result.remoteURL,
                    revisedPrompt: revisedPrompt
                )
            }
        }

        if results.isEmpty {
            throw NSError(domain: "GeminiImageAdapter", code: 3, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("响应中未包含可用图片数据", comment: "Image generation missing image data error")])
        }
        return results
    }
}
