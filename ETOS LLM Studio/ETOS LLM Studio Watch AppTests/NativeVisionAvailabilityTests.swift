import Testing
@testable import ETOSCore

@Suite("watchOS 原生图片分析平台边界")
struct NativeVisionAvailabilityTests {
    @Test("直接调用图片分析工具时先返回平台不可用", arguments: [
        "vision.recognize_text", "vision.detect_barcodes",
        "vision.classify_image", "vision.detect_document"
    ])
    func visionExecutionIsUnavailable(toolID: String) async throws {
        do {
            // 使用空参数，确认平台判断先于参数校验和图片文件读取。
            _ = try await MCPNativeVisionExecutor().execute(toolName: toolID, arguments: [:])
            Issue.record("watchOS 不应执行当前平台没有提供的 Vision 请求。")
        } catch MCPNativeCapabilityError.unavailable {
        }
    }
}
