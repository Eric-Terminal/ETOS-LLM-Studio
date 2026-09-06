// ============================================================================
// VideoAnalysisResultTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证视频解析结果替换与提示词投影行为。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("视频解析结果测试")
struct VideoAnalysisResultTests {
    @Test("重新解析会按文件名替换旧结果")
    func replacingResultKeepsOtherVideos() {
        let first = VideoAnalysisResult(
            fileName: "first.mp4",
            content: "旧解析",
            modelIdentifier: "old-model",
            modelDisplayName: "旧模型"
        )
        let second = VideoAnalysisResult(
            fileName: "second.mov",
            content: "第二个视频",
            modelIdentifier: "video-model",
            modelDisplayName: "视频模型"
        )
        let replacement = VideoAnalysisResult(
            fileName: "first.mp4",
            content: "新解析",
            modelIdentifier: "new-model",
            modelDisplayName: "新模型"
        )
        var message = ChatMessage(
            role: .user,
            content: "看看视频",
            videoAnalysisResults: [first, second]
        )

        message.replaceVideoAnalysisResult(replacement)

        #expect(message.videoAnalysisResults?.count == 2)
        #expect(message.videoAnalysisResult(for: "first.mp4") == replacement)
        #expect(message.videoAnalysisResult(for: "second.mov") == second)
    }

    @Test("视频解析附加提示词会保留边界和解析文字")
    func appendixPromptPreservesBoundaryAndContent() {
        let rendered = BuiltInPromptStore.render(
            .videoAnalysisAppendix,
            variables: ["attachments": "<video name=\"demo.mp4\">画面内容</video>"]
        )

        #expect(rendered.contains("<video_analysis_attachments>"))
        #expect(rendered.contains("demo.mp4"))
        #expect(rendered.contains("画面内容"))
        #expect(!rendered.contains("{attachments}"))
    }
}
