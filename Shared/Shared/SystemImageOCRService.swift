// ============================================================================
// SystemImageOCRService.swift
// ============================================================================
// 系统图片 OCR 服务
// - 在支持 Vision 的 iOS 设备上使用系统文字识别
// - watchOS 不提供系统 OCR，调用方需选择第三方视觉模型
// ============================================================================

import Foundation
#if canImport(Vision) && !os(watchOS)
import Vision
#endif

public enum SystemImageOCRService {
    public enum RecognitionError: LocalizedError {
        case unsupportedPlatform
        case recognitionFailed(String)
        case emptyResult

        public var errorDescription: String? {
            switch self {
            case .unsupportedPlatform:
                return NSLocalizedString("当前平台不支持系统 OCR。", comment: "System OCR unsupported platform error")
            case .recognitionFailed(let message):
                return String(
                    format: NSLocalizedString("系统 OCR 识别失败：%@", comment: "System OCR recognition failed error"),
                    message
                )
            case .emptyResult:
                return NSLocalizedString("系统 OCR 未识别到有效文字。", comment: "System OCR empty result error")
            }
        }
    }

#if canImport(Vision) && !os(watchOS)
    public static func recognizeText(in imageData: Data) async throws -> String {
        try await recognizeText(imageData: imageData)
    }

    public static func recognizeText(imageData: Data) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(data: imageData, options: [:])
            do {
                try handler.perform([request])
            } catch {
                throw RecognitionError.recognitionFailed(error.localizedDescription)
            }

            let lines = (request.results ?? [])
                .compactMap { observation in
                    observation.topCandidates(1).first?.string
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .filter { !$0.isEmpty }

            guard !lines.isEmpty else {
                throw RecognitionError.emptyResult
            }
            return lines.joined(separator: "\n")
        }.value
    }
#else
    public static func recognizeText(in imageData: Data) async throws -> String {
        _ = imageData
        throw RecognitionError.unsupportedPlatform
    }
#endif
}
