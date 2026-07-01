// ============================================================================
// FileAttachmentTextExtractorTests.swift
// ============================================================================
// 文件附件文本抽取测试
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

@Suite("文件附件文本抽取测试")
struct FileAttachmentTextExtractorTests {
    @Test("纯文本附件可以直接抽取")
    func plainTextAttachmentCanBeExtracted() throws {
        let extractor = FileAttachmentTextExtractor()
        let attachment = FileAttachment(
            data: Data("纯文本内容".utf8),
            mimeType: "text/plain",
            fileName: "notes.txt"
        )

        let text = try extractor.extractText(from: attachment)

        #expect(text == "纯文本内容")
    }

    @Test("未知后缀的纯文本附件也可以抽取")
    func unknownExtensionPlainTextAttachmentCanBeExtracted() throws {
        let extractor = FileAttachmentTextExtractor()
        let attachment = FileAttachment(
            data: Data("没有常规后缀但仍是文本".utf8),
            mimeType: "application/octet-stream",
            fileName: "notes.payload"
        )

        let text = try extractor.extractText(from: attachment)

        #expect(text == "没有常规后缀但仍是文本")
    }

    @Test("本地文件预览会读取 jsonl 等纯文本文件")
    func localFilePreviewReadsJSONLText() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-\(UUID().uuidString)")
            .appendingPathExtension("jsonl")
        try Data("{\"a\":1}\n{\"b\":2}".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let payload = FileAttachmentPreviewLoader.load(fileURL: fileURL)

        #expect(payload.canPreview)
        #expect(payload.text == "{\"a\":1}\n{\"b\":2}")
        #expect(payload.lineCount == 2)
    }

    @Test("本地文件预览会按字符截断超长文本")
    func localFilePreviewTruncatesLongText() throws {
        let limit = FileAttachmentPreviewLimits.textCharacterLimit
        let text = String(repeating: "长", count: limit + 12)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-long-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        try Data(text.utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let payload = FileAttachmentPreviewLoader.load(fileURL: fileURL)

        #expect(payload.canPreview)
        #expect(payload.isTextTruncated)
        #expect(payload.text?.count == limit)
        #expect(payload.originalCharacterCount == limit + 12)
        #expect(payload.previewCharacterLimit == limit)
    }

    @Test("DOCX 附件会抽取主文档文本")
    func docxAttachmentCanBeExtracted() throws {
        let extractor = FileAttachmentTextExtractor()
        let attachment = FileAttachment(
            data: try FileAttachmentTextFixtureFactory.makeDOCXFixture(),
            mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            fileName: "sample.docx"
        )

        let text = try extractor.extractText(from: attachment)

        #expect(text.contains("DOCX 第一段"))
        #expect(text.contains("DOCX 第二段"))
    }

    @Test("PPTX 附件会按幻灯片顺序抽取文本")
    func pptxAttachmentCanBeExtracted() throws {
        let extractor = FileAttachmentTextExtractor()
        let attachment = FileAttachment(
            data: try FileAttachmentTextFixtureFactory.makePPTXFixture(),
            mimeType: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            fileName: "slides.pptx"
        )

        let text = try extractor.extractText(from: attachment)

        #expect(text.contains("PPTX 第一页"))
        #expect(text.contains("PPTX 第二页"))
        #expect(text.contains("PPTX 第一页\nPPTX 第二页"))
    }

    @Test("XLSX 附件会抽取共享字符串、数字与内联文本")
    func xlsxAttachmentCanBeExtracted() throws {
        let extractor = FileAttachmentTextExtractor()
        let attachment = FileAttachment(
            data: try FileAttachmentTextFixtureFactory.makeXLSXFixture(),
            mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            fileName: "sheet.xlsx"
        )

        let text = try extractor.extractText(from: attachment)

        #expect(text.contains("XLSX 共享文本"))
        #expect(text.contains("42"))
        #expect(text.contains("XLSX 内联文本"))
    }

    @Test("未知二进制附件会返回不支持错误")
    func unsupportedBinaryAttachmentThrows() {
        let extractor = FileAttachmentTextExtractor()
        let attachment = FileAttachment(
            data: Data([0, 1, 2, 3, 4, 5]),
            mimeType: "application/octet-stream",
            fileName: "binary.bin"
        )

        #expect(throws: FileAttachmentTextExtractionError.self) {
            _ = try extractor.extractText(from: attachment)
        }
    }

    @Test("PDF 在不支持的平台会返回平台限制错误")
    func pdfUnsupportedPlatformThrows() {
        #if !(canImport(PDFKit) && !os(watchOS))
        let extractor = FileAttachmentTextExtractor()
        let attachment = FileAttachment(
            data: Data("%PDF-1.4\n%%EOF".utf8),
            mimeType: "application/pdf",
            fileName: "sample.pdf"
        )

        #expect(throws: FileAttachmentTextExtractionError.self) {
            _ = try extractor.extractText(from: attachment)
        }
        #endif
    }

    @Test("iOS 上可以抽取 PDF 文本")
    func pdfAttachmentCanBeExtractedOniOS() throws {
        #if canImport(PDFKit) && !os(watchOS)
        let extractor = FileAttachmentTextExtractor()
        let attachment = FileAttachment(
            data: makePDFFixture(),
            mimeType: "application/pdf",
            fileName: "sample.pdf"
        )

        let text = try extractor.extractText(from: attachment)

        #expect(text.contains("PDF 第一行"))
        #expect(text.contains("PDF 第二行"))
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    private func makePDFFixture() -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200))
        return renderer.pdfData { context in
            context.beginPage()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14)
            ]
            "PDF 第一行".draw(at: CGPoint(x: 16, y: 24), withAttributes: attributes)
            "PDF 第二行".draw(at: CGPoint(x: 16, y: 48), withAttributes: attributes)
        }
    }
    #endif
}
