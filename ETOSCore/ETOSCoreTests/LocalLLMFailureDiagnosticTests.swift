// ============================================================================
// LocalLLMFailureDiagnosticTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证本地运行时失败诊断包含定位信息且不会泄露模型绝对路径。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("本地推理失败诊断测试")
struct LocalLLMFailureDiagnosticTests {
    @Test("诊断记录运行参数并隐藏模型绝对路径")
    func diagnosticIncludesRuntimeSnapshotWithoutAbsolutePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalLLMFailureDiagnosticTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let modelURL = root.appendingPathComponent("tiny.gguf")
        let projectorURL = root.appendingPathComponent("mmproj.gguf")
        try Data(repeating: 0, count: 128).write(to: modelURL)
        let record = LocalModelRecord(
            displayName: "Tiny",
            fileName: modelURL.lastPathComponent,
            relativePath: modelURL.lastPathComponent,
            fileSize: 128,
            ggufArchitecture: "llama"
        )
        let options = LocalLLMGenerationOptions(
            mmprojPath: projectorURL.path,
            contextSize: 2_048,
            maxOutputTokens: 256,
            gpuLayers: 12,
            batchSize: 128,
            ubatchSize: 64
        )
        let diagnostic = LocalLLMFailureDiagnostic(
            error: LocalLLMEngineError.generationFailed(
                "无法加载 \(modelURL.path)，投影文件：\(projectorURL.path)"
            ),
            record: record,
            modelURL: modelURL,
            options: options,
            requestID: UUID()
        )

        #expect(!diagnostic.displayText.contains(root.path))
        #expect(diagnostic.displayText.contains("tiny.gguf"))
        #expect(diagnostic.displayText.contains("mmproj.gguf"))
        #expect(diagnostic.displayText.contains("context_size=2048"))
        #expect(diagnostic.payload["actual_file_size_bytes"] == "128")
        #expect(diagnostic.payload["gguf_architecture"] == "llama")
    }
}
