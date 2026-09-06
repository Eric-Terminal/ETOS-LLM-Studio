// ============================================================================
// MCPNativeVisionExecutor.swift
// ============================================================================
// ETOS LLM Studio
//
// 图片从受控文件 URI 解码；Vision 同步请求只在独立 actor 中执行，不进入 UI 渲染链路。
// ============================================================================

import Foundation
#if canImport(Vision) && canImport(ImageIO)
@preconcurrency import Vision
import ImageIO
#endif

actor MCPNativeVisionExecutor {
    private static let maximumInputBytes = 100 * 1_024 * 1_024
    private static let maximumPixels = 48_000_000

    func execute(toolName: String, arguments: [String: Any]) async throws -> [String: Any] {
        #if canImport(Vision) && canImport(ImageIO)
        let source = try arguments.nativeRequiredString("source")
        let image = try loadImage(source: source)
        let orientation = try imageOrientation(arguments.nativeInt("orientation") ?? 1)
        switch toolName {
        case "vision.recognize_text":
            return try recognizeText(
                image: image,
                orientation: orientation,
                source: source,
                arguments: arguments
            )
        case "vision.detect_barcodes":
            return try detectBarcodes(
                image: image,
                orientation: orientation,
                source: source,
                arguments: arguments
            )
        case "vision.classify_image":
            return try classifyImage(
                image: image,
                orientation: orientation,
                source: source,
                arguments: arguments
            )
        case "vision.detect_document":
            return try detectDocument(image: image, orientation: orientation, source: source)
        default:
            throw MCPNativeCapabilityError.unsupportedTool(toolName)
        }
        #else
        throw MCPNativeCapabilityError.unavailable(
            NSLocalizedString("当前平台没有 Vision 图片分析能力。", comment: "Vision unavailable")
        )
        #endif
    }
}

#if canImport(Vision) && canImport(ImageIO)
private extension MCPNativeVisionExecutor {
    func loadImage(source: String) throws -> CGImage {
        let url = try MCPNativeFileAccess.readableURL(for: source)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize <= Self.maximumInputBytes else {
            throw MCPNativeCapabilityError.invalidArgument(
                NSLocalizedString("Vision 输入必须是不超过 100 MiB 的普通图片文件。", comment: "Vision input file limit")
            )
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw MCPNativeCapabilityError.invalidArgument(
                NSLocalizedString("无法解码指定的 Vision 输入图片。", comment: "Vision image decode failed")
            )
        }
        guard image.width > 0,
              image.height > 0,
              image.width <= Self.maximumPixels / image.height else {
            throw MCPNativeCapabilityError.invalidArgument(
                NSLocalizedString("Vision 输入图片超过 4800 万像素预算。", comment: "Vision pixel limit")
            )
        }
        return image
    }

    func imageOrientation(_ rawValue: Int) throws -> CGImagePropertyOrientation {
        guard let orientation = CGImagePropertyOrientation(rawValue: UInt32(rawValue)) else {
            throw MCPNativeCapabilityError.invalidArgument(
                NSLocalizedString("orientation 必须是 1 到 8 的 EXIF 方向。", comment: "Invalid Vision orientation")
            )
        }
        return orientation
    }

    func recognizeText(
        image: CGImage,
        orientation: CGImagePropertyOrientation,
        source: String,
        arguments: [String: Any]
    ) throws -> [String: Any] {
        let request = VNRecognizeTextRequest()
        switch arguments.nativeString("recognition_level") ?? "accurate" {
        case "accurate": request.recognitionLevel = .accurate
        case "fast": request.recognitionLevel = .fast
        default:
            throw MCPNativeCapabilityError.invalidArgument(
                NSLocalizedString("recognition_level 必须是 accurate 或 fast。", comment: "Invalid OCR level")
            )
        }
        if let languages = arguments["languages"] as? [String], !languages.isEmpty {
            request.recognitionLanguages = Array(languages.prefix(32))
        }
        request.usesLanguageCorrection = arguments.nativeBool("uses_language_correction") != false
        try perform(request, image: image, orientation: orientation)
        let maximum = min(max(arguments.nativeInt("maximum_results") ?? 100, 1), 300)
        let observations = (request.results ?? []).prefix(maximum)
        var remainingCharacters = 32_768
        var items: [[String: Any]] = []
        for observation in observations {
            guard remainingCharacters > 0,
                  let candidate = observation.topCandidates(1).first else { break }
            let text = String(candidate.string.prefix(remainingCharacters))
            remainingCharacters -= text.count
            items.append([
                "text": text,
                "confidence": candidate.confidence,
                "bounding_box": rectangle(observation.boundingBox)
            ])
        }
        return imageResult(source: source, image: image, extra: [
            "text": items.map { $0["text"] as? String ?? "" }.joined(separator: "\n"),
            "observations": items,
            "count": items.count,
            "truncated": (request.results?.count ?? 0) > items.count || remainingCharacters == 0
        ])
    }

    func detectBarcodes(
        image: CGImage,
        orientation: CGImagePropertyOrientation,
        source: String,
        arguments: [String: Any]
    ) throws -> [String: Any] {
        let request = VNDetectBarcodesRequest()
        if let rawValues = arguments["symbologies"] as? [String], !rawValues.isEmpty {
            request.symbologies = Array(rawValues.prefix(32)).map(VNBarcodeSymbology.init(rawValue:))
        }
        try perform(request, image: image, orientation: orientation)
        let maximum = min(max(arguments.nativeInt("maximum_results") ?? 50, 1), 100)
        let total = request.results?.count ?? 0
        let items = (request.results ?? []).prefix(maximum).map { observation in
            [
                "symbology": observation.symbology.rawValue,
                "payload": observation.payloadStringValue.map { String($0.prefix(8_192)) } ?? NSNull(),
                "confidence": observation.confidence,
                "bounding_box": rectangle(observation.boundingBox)
            ] as [String: Any]
        }
        return imageResult(source: source, image: image, extra: [
            "barcodes": Array(items),
            "count": items.count,
            "truncated": total > items.count
        ])
    }

    func classifyImage(
        image: CGImage,
        orientation: CGImagePropertyOrientation,
        source: String,
        arguments: [String: Any]
    ) throws -> [String: Any] {
        let request = VNClassifyImageRequest()
        try perform(request, image: image, orientation: orientation)
        let minimumConfidence = min(max(arguments.nativeDouble("minimum_confidence") ?? 0.01, 0), 1)
        let maximum = min(max(arguments.nativeInt("maximum_results") ?? 20, 1), 100)
        let filtered = (request.results ?? []).filter { Double($0.confidence) >= minimumConfidence }
        let classifications = filtered.prefix(maximum).map { observation in
            ["identifier": observation.identifier, "confidence": observation.confidence] as [String: Any]
        }
        return imageResult(source: source, image: image, extra: [
            "classifications": Array(classifications),
            "count": classifications.count,
            "truncated": filtered.count > classifications.count
        ])
    }

    func detectDocument(
        image: CGImage,
        orientation: CGImagePropertyOrientation,
        source: String
    ) throws -> [String: Any] {
        let request = VNDetectDocumentSegmentationRequest()
        try perform(request, image: image, orientation: orientation)
        let document = request.results?.first
        return imageResult(source: source, image: image, extra: [
            "found": document != nil,
            "document": document.map { observation in
                [
                    "confidence": observation.confidence,
                    "bounding_box": rectangle(observation.boundingBox),
                    "top_left": point(observation.topLeft),
                    "top_right": point(observation.topRight),
                    "bottom_left": point(observation.bottomLeft),
                    "bottom_right": point(observation.bottomRight)
                ] as [String: Any]
            } ?? NSNull()
        ])
    }

    func perform<R: VNImageBasedRequest>(
        _ request: R,
        image: CGImage,
        orientation: CGImagePropertyOrientation
    ) throws {
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        try handler.perform([request])
    }

    func imageResult(
        source: String,
        image: CGImage,
        extra: [String: Any]
    ) -> [String: Any] {
        var result: [String: Any] = [
            "source": source,
            "image_width": image.width,
            "image_height": image.height,
            "coordinate_space": "vision_normalized_bottom_left"
        ]
        result.merge(extra) { _, new in new }
        return result
    }

    func rectangle(_ value: CGRect) -> [String: Double] {
        ["x": value.origin.x, "y": value.origin.y, "width": value.width, "height": value.height]
    }

    func point(_ value: CGPoint) -> [String: Double] {
        ["x": value.x, "y": value.y]
    }
}
#endif
