// ============================================================================
// VideoFrameExtractorTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证视频识别、抽帧数量规划和配置边界。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("视频抽帧")
struct VideoFrameExtractorTests {
    @Test("可通过 MIME 或扩展名识别视频")
    func recognizesVideoAttachments() {
        #expect(VideoAttachmentSupport.isVideo(FileAttachment(
            data: Data(),
            mimeType: "video/mp4",
            fileName: "attachment.bin"
        )))
        #expect(VideoAttachmentSupport.isVideo(fileName: "clip.MOV"))
        #expect(!VideoAttachmentSupport.isVideo(fileName: "notes.pdf", mimeType: "application/pdf"))
    }

    @Test("只有启用视频模态的 Gemini 模型走原生视频")
    func nativeVideoRoutingRequiresGeminiAndVideoModality() {
        let geminiProvider = Provider(
            id: UUID(),
            name: "Gemini",
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKeys: ["key"],
            apiFormat: "gemini"
        )
        let openAIProvider = Provider(
            id: UUID(),
            name: "OpenAI",
            baseURL: "https://example.com/v1",
            apiKeys: ["key"],
            apiFormat: "openai-compatible"
        )
        let nativeModel = Model(
            modelName: "native-video",
            inputModalities: [.text, .video]
        )
        let frameOnlyModel = Model(
            modelName: "frame-only",
            inputModalities: [.text, .image]
        )

        #expect(VideoAttachmentSupport.usesNativeInput(for: RunnableModel(
            provider: geminiProvider,
            model: nativeModel
        )))
        #expect(!VideoAttachmentSupport.usesNativeInput(for: RunnableModel(
            provider: geminiProvider,
            model: frameOnlyModel
        )))
        #expect(!VideoAttachmentSupport.usesNativeInput(for: RunnableModel(
            provider: openAIProvider,
            model: nativeModel
        )))
    }

    @Test("固定 FPS 受最大画面数限制且时间保持递增")
    func fixedFPSPlanningHonorsFrameCap() {
        let configuration = VideoFrameExtractionConfiguration(
            mode: .fixedFPS,
            fixedFPS: 2,
            maximumFrameCount: 8
        )
        let timestamps = VideoFrameExtractor.plannedTimestamps(
            duration: 10,
            configuration: configuration
        )

        #expect(timestamps.count == 8)
        #expect(timestamps.first == 0)
        #expect(zip(timestamps, timestamps.dropFirst()).allSatisfy { $0.0 < $0.1 })
        #expect(timestamps.allSatisfy { $0 >= 0 && $0 < 10 })
    }

    @Test("智能抽帧按时长自适应并尊重用户上限")
    func smartFrameCountAdaptsToDuration() {
        #expect(VideoFrameExtractor.adaptiveSmartFrameCount(duration: 20, maximumFrameCount: 120) == 12)
        #expect(VideoFrameExtractor.adaptiveSmartFrameCount(duration: 50, maximumFrameCount: 120) == 20)
        #expect(VideoFrameExtractor.adaptiveSmartFrameCount(duration: 120, maximumFrameCount: 18) == 18)
        #expect(VideoFrameExtractor.adaptiveSmartFrameCount(duration: 900, maximumFrameCount: 120) == 60)
    }

    @Test("抽帧配置会收敛到安全范围")
    func configurationNormalizesBounds() {
        let configuration = VideoFrameExtractionConfiguration(
            mode: .fixedFPS,
            fixedFPS: 20,
            maximumFrameCount: 1
        )

        #expect(configuration.fixedFPS == 5)
        #expect(configuration.maximumFrameCount == 4)
    }
}
