// ============================================================================
// CloudEmbeddingServiceTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责云端嵌入服务的路由选择与原生适配器映射测试。
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("CloudEmbeddingService Tests")
struct CloudEmbeddingServiceTests {
    @Test("默认嵌入服务会按 Gemini 格式选择原生适配器")
    func testDefaultServiceRoutesGeminiEmbeddingModelToGeminiAdapter() async throws {
        let backupProviders = ConfigLoader.loadProviders()
        defer {
            restoreProviders(backupProviders)
            MockURLProtocol.mockResponses = [:]
        }
        clearAllProviders()
        MockURLProtocol.mockResponses = [:]

        let providerID = UUID()
        let modelID = UUID()
        let model = Model(
            id: modelID,
            modelName: "gemini-embedding-001",
            displayName: "Gemini Embedding",
            kind: .embedding
        )
        let provider = Provider(
            id: providerID,
            name: "Gemini 嵌入测试",
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            apiKeys: ["test-key"],
            apiFormat: "gemini",
            models: [model]
        )
        ConfigLoader.saveProvider(provider)

        let expectedURL = try #require(URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-001:embedContent?key=test-key"))
        let response = try #require(HTTPURLResponse(
            url: expectedURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let responseData = Data(#"{"embedding":{"values":[0.1,0.2,0.3]}}"#.utf8)
        MockURLProtocol.mockResponses[expectedURL] = .success((response, responseData))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let service = CloudEmbeddingService(urlSession: URLSession(configuration: configuration))

        let embeddings = try await service.generateEmbeddings(
            for: ["用户喜欢冷萃咖啡。"],
            preferredModelID: "\(providerID.uuidString)-\(modelID.uuidString)"
        )

        #expect(embeddings.count == 1)
        #expect(embeddings.first?.count == 3)
    }

    private func clearAllProviders() {
        ConfigLoader.loadProviders().forEach { ConfigLoader.deleteProvider($0) }
    }

    private func restoreProviders(_ providers: [Provider]) {
        clearAllProviders()
        providers.forEach { ConfigLoader.saveProvider($0) }
    }
}
