// ============================================================================
// FileAttachmentTextExtractor.swift
// ============================================================================
// 文件附件文本抽取服务
// - 在发送给模型前，把可读文件转换成纯文本
// - 支撑 iOS 与 watchOS 的业务一致性
// ============================================================================

import Foundation
import ZIPFoundation
#if canImport(PDFKit) && !os(watchOS)
import PDFKit
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

public enum FileAttachmentTextExtractionError: LocalizedError {
    case unsupportedFileType(fileName: String)
    case emptyText(fileName: String)
    case archiveEntryMissing(fileName: String, entry: String)
    case archiveReadFailed(fileName: String, reason: String)
    case pdfUnsupportedOnPlatform(fileName: String)
    case pdfReadFailed(fileName: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFileType(let fileName):
            return String(
                format: NSLocalizedString("无法将“%@”转换为纯文本。", comment: "Unsupported file text extraction error"),
                fileName
            )
        case .emptyText(let fileName):
            return String(
                format: NSLocalizedString("“%@”没有可发送的文本内容。", comment: "Empty extracted file text error"),
                fileName
            )
        case .archiveEntryMissing(let fileName, let entry):
            return String(
                format: NSLocalizedString("无法读取“%@”中的必要内容：%@。", comment: "Archive entry missing error"),
                fileName,
                entry
            )
        case .archiveReadFailed(let fileName, let reason):
            return String(
                format: NSLocalizedString("读取“%@”失败：%@。", comment: "Archive read failed error"),
                fileName,
                reason
            )
        case .pdfUnsupportedOnPlatform(let fileName):
            return String(
                format: NSLocalizedString("当前平台不支持读取 PDF 附件“%@”。请在 iOS 端发送，或先转换为纯文本。", comment: "PDF unsupported platform error"),
                fileName
            )
        case .pdfReadFailed(let fileName):
            return String(
                format: NSLocalizedString("无法读取 PDF 附件“%@”。", comment: "PDF read failed error"),
                fileName
            )
        }
    }
}

public struct FileAttachmentTextExtractor {
    private let textFileExtensions: Set<String> = [
        "txt",
        "text",
        "md",
        "markdown",
        "csv",
        "tsv",
        "json",
        "jsonl",
        "xml",
        "html",
        "htm",
        "yaml",
        "yml",
        "log",
        "rtf"
    ]
    private let textMimeTypes: Set<String> = [
        "text/plain",
        "text/markdown",
        "text/csv",
        "text/tab-separated-values",
        "text/html",
        "text/xml",
        "application/json",
        "application/xml",
        "application/xhtml+xml",
        "application/javascript",
        "application/x-yaml",
        "application/yaml",
        "application/rtf",
        "text/rtf"
    ]

    public init() {}

    public func extractText(from attachment: FileAttachment) throws -> String {
        let fileName = (attachment.fileName as NSString).lastPathComponent
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        let extractedText: String

        switch fileExtension {
        case "docx":
            extractedText = try extractDOCXText(from: attachment.data, fileName: fileName)
        case "pptx":
            extractedText = try extractPPTXText(from: attachment.data, fileName: fileName)
        case "xlsx":
            extractedText = try extractXLSXText(from: attachment.data, fileName: fileName)
        case "pdf":
            extractedText = try extractPDFText(from: attachment.data, fileName: fileName)
        default:
            if let text = decodePlainText(from: attachment.data),
               shouldTreatAsPlainText(fileExtension: fileExtension, mimeType: attachment.mimeType, decodedText: text) {
                extractedText = text
            } else {
                throw FileAttachmentTextExtractionError.unsupportedFileType(fileName: fileName)
            }
        }

        let normalized = normalizeWhitespace(in: extractedText)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FileAttachmentTextExtractionError.emptyText(fileName: fileName)
        }
        return normalized
    }

    private func extractDOCXText(from data: Data, fileName: String) throws -> String {
        let archive = try makeArchive(from: data, fileName: fileName)
        let documentData = try entryData(for: "word/document.xml", in: archive, fileName: fileName)
        return extractXMLText(from: documentData, tags: ["t"])
    }

    private func extractPPTXText(from data: Data, fileName: String) throws -> String {
        let archive = try makeArchive(from: data, fileName: fileName)
        let slidePaths = archive
            .map(\.path)
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted(by: compareNumberedPaths)
        guard !slidePaths.isEmpty else {
            throw FileAttachmentTextExtractionError.archiveEntryMissing(fileName: fileName, entry: "ppt/slides/slide*.xml")
        }

        let slideTexts = try slidePaths.map { path in
            let slideData = try entryData(for: path, in: archive, fileName: fileName)
            return extractXMLText(from: slideData, tags: ["t"])
        }
        return slideTexts.joined(separator: "\n")
    }

    private func extractXLSXText(from data: Data, fileName: String) throws -> String {
        let archive = try makeArchive(from: data, fileName: fileName)
        let sharedStrings: [String]
        if archive["xl/sharedStrings.xml"] != nil {
            let sharedStringsData = try entryData(for: "xl/sharedStrings.xml", in: archive, fileName: fileName)
            sharedStrings = extractSharedStrings(from: sharedStringsData)
        } else {
            sharedStrings = []
        }

        let sheetPaths = archive
            .map(\.path)
            .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted(by: compareNumberedPaths)
        guard !sheetPaths.isEmpty else {
            throw FileAttachmentTextExtractionError.archiveEntryMissing(fileName: fileName, entry: "xl/worksheets/sheet*.xml")
        }

        let sheetTexts = try sheetPaths.map { path in
            let sheetData = try entryData(for: path, in: archive, fileName: fileName)
            return extractSheetText(from: sheetData, sharedStrings: sharedStrings)
        }
        return sheetTexts.joined(separator: "\n")
    }

    private func extractPDFText(from data: Data, fileName: String) throws -> String {
        #if canImport(PDFKit) && !os(watchOS)
        guard let document = PDFDocument(data: data) else {
            throw FileAttachmentTextExtractionError.pdfReadFailed(fileName: fileName)
        }
        var pageTexts: [String] = []
        for pageIndex in 0..<document.pageCount {
            guard let pageText = document.page(at: pageIndex)?.string else { continue }
            pageTexts.append(pageText)
        }
        return pageTexts.joined(separator: "\n")
        #else
        throw FileAttachmentTextExtractionError.pdfUnsupportedOnPlatform(fileName: fileName)
        #endif
    }

    private func makeArchive(from data: Data, fileName: String) throws -> Archive {
        do {
            return try Archive(data: data, accessMode: .read)
        } catch {
            throw FileAttachmentTextExtractionError.archiveReadFailed(fileName: fileName, reason: error.localizedDescription)
        }
    }

    private func entryData(for path: String, in archive: Archive, fileName: String) throws -> Data {
        guard let entry = archive[path] else {
            throw FileAttachmentTextExtractionError.archiveEntryMissing(fileName: fileName, entry: path)
        }

        do {
            var entryData = Data()
            _ = try archive.extract(entry) { chunk in
                entryData.append(chunk)
            }
            return entryData
        } catch {
            throw FileAttachmentTextExtractionError.archiveReadFailed(fileName: fileName, reason: error.localizedDescription)
        }
    }

    private func decodePlainText(from data: Data) -> String? {
        let encodings: [String.Encoding] = [
            .utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .isoLatin1,
            .windowsCP1252
        ]
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        return nil
    }

    private func shouldTreatAsPlainText(fileExtension: String, mimeType: String, decodedText: String) -> Bool {
        if textFileExtensions.contains(fileExtension) {
            return true
        }

        let normalizedMimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedMimeType.hasPrefix("text/") {
            return true
        }
        if textMimeTypes.contains(normalizedMimeType) {
            return true
        }
        return looksLikePlainText(decodedText)
    }

    private func looksLikePlainText(_ text: String) -> Bool {
        let sample = text.prefix(4096)
        guard !sample.isEmpty else { return false }

        let scalars = sample.unicodeScalars
        let invalidCount = scalars.filter { scalar in
            scalar.value == 0
                || (scalar.value < 0x20 && scalar.value != 0x0A && scalar.value != 0x0D && scalar.value != 0x09)
                || scalar.value == 0xFFFD
        }.count
        return Double(invalidCount) / Double(scalars.count) < 0.02
    }

    private func extractXMLText(from data: Data, tags: Set<String>) -> String {
        let collector = XMLTextCollector(acceptedTags: tags)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        _ = parser.parse()
        return collector.text
    }

    private func extractSharedStrings(from data: Data) -> [String] {
        let collector = XLSXSharedStringCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        _ = parser.parse()
        return collector.values
    }

    private func extractSheetText(from data: Data, sharedStrings: [String]) -> String {
        let collector = XLSXSheetTextCollector(sharedStrings: sharedStrings)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        _ = parser.parse()
        return collector.text
    }

    private func compareNumberedPaths(_ lhs: String, _ rhs: String) -> Bool {
        let lhsNumber = trailingNumber(in: lhs) ?? Int.max
        let rhsNumber = trailingNumber(in: rhs) ?? Int.max
        if lhsNumber == rhsNumber {
            return lhs < rhs
        }
        return lhsNumber < rhsNumber
    }

    private func trailingNumber(in path: String) -> Int? {
        let fileName = (path as NSString).lastPathComponent
        let digits = fileName.reversed().drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber }).reversed()
        return Int(String(digits))
    }

    private func normalizeWhitespace(in text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct FileAttachmentPreviewPayload: Identifiable {
    public let id = UUID()
    public let fileName: String
    public let fileSize: Int64
    public let text: String?
    public let errorMessage: String?
    public let lineCount: Int

    public var canPreview: Bool {
        text != nil
    }
}

public enum FileAttachmentPreviewLoader {
    public static func load(fileName: String, extractor: FileAttachmentTextExtractor = FileAttachmentTextExtractor()) -> FileAttachmentPreviewPayload {
        guard let data = Persistence.loadFile(fileName: fileName) else {
            return FileAttachmentPreviewPayload(
                fileName: fileName,
                fileSize: 0,
                text: nil,
                errorMessage: NSLocalizedString("无法读取此文件的内容。", comment: ""),
                lineCount: 0
            )
        }

        return makePayload(data: data, fileName: fileName, extractor: extractor)
    }

    public static func load(fileURL: URL, extractor: FileAttachmentTextExtractor = FileAttachmentTextExtractor()) -> FileAttachmentPreviewPayload {
        do {
            let data = try Data(contentsOf: fileURL)
            return makePayload(data: data, fileName: fileURL.lastPathComponent, extractor: extractor)
        } catch {
            return FileAttachmentPreviewPayload(
                fileName: fileURL.lastPathComponent,
                fileSize: 0,
                text: nil,
                errorMessage: NSLocalizedString("无法读取此文件的内容。", comment: ""),
                lineCount: 0
            )
        }
    }

    private static func makePayload(
        data: Data,
        fileName: String,
        extractor: FileAttachmentTextExtractor
    ) -> FileAttachmentPreviewPayload {
        let attachment = FileAttachment(
            data: data,
            mimeType: resolvedMimeType(for: fileName),
            fileName: fileName
        )

        do {
            let text = try extractor.extractText(from: attachment)
            return FileAttachmentPreviewPayload(
                fileName: fileName,
                fileSize: Int64(data.count),
                text: text,
                errorMessage: nil,
                lineCount: lineCount(in: text)
            )
        } catch {
            return FileAttachmentPreviewPayload(
                fileName: fileName,
                fileSize: Int64(data.count),
                text: nil,
                errorMessage: error.localizedDescription,
                lineCount: 0
            )
        }
    }

    private static func lineCount(in text: String) -> Int {
        let newlineCount = text.reduce(0) { count, character in
            character.isNewline ? count + 1 : count
        }
        return text.isEmpty ? 0 : newlineCount + 1
    }

    private static func resolvedMimeType(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else {
            return "application/octet-stream"
        }
        #if canImport(UniformTypeIdentifiers)
        if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime
        }
        #endif
        return "application/octet-stream"
    }
}

private final class XMLTextCollector: NSObject, XMLParserDelegate {
    private let acceptedTags: Set<String>
    private var isCollecting = false
    private var parts: [String] = []

    var text: String {
        parts.joined(separator: " ")
    }

    init(acceptedTags: Set<String>) {
        self.acceptedTags = acceptedTags
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        isCollecting = acceptedTags.contains(Self.localName(from: elementName))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isCollecting else { return }
        parts.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if acceptedTags.contains(Self.localName(from: elementName)) {
            isCollecting = false
        }
    }

    private static func localName(from elementName: String) -> String {
        elementName.split(separator: ":").last.map(String.init) ?? elementName
    }
}

private final class XLSXSharedStringCollector: NSObject, XMLParserDelegate {
    private var isCollectingText = false
    private var currentParts: [String] = []
    private var valuesBuffer: [String] = []

    var values: [String] {
        valuesBuffer
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localName = Self.localName(from: elementName)
        if localName == "si" {
            currentParts = []
        } else if localName == "t" {
            isCollectingText = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isCollectingText else { return }
        currentParts.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let localName = Self.localName(from: elementName)
        if localName == "t" {
            isCollectingText = false
        } else if localName == "si" {
            valuesBuffer.append(currentParts.joined())
            currentParts = []
        }
    }

    private static func localName(from elementName: String) -> String {
        elementName.split(separator: ":").last.map(String.init) ?? elementName
    }
}

private final class XLSXSheetTextCollector: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private var currentCellType: String?
    private var isInValue = false
    private var isInInlineText = false
    private var currentValue = ""
    private var parts: [String] = []

    var text: String {
        parts.joined(separator: " ")
    }

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localName = Self.localName(from: elementName)
        switch localName {
        case "c":
            currentCellType = attributeDict["t"]
            currentValue = ""
        case "v":
            isInValue = true
            currentValue = ""
        case "t":
            isInInlineText = true
            currentValue = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInValue || isInInlineText {
            currentValue += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let localName = Self.localName(from: elementName)
        switch localName {
        case "v":
            isInValue = false
        case "t":
            if isInInlineText {
                parts.append(currentValue)
            }
            isInInlineText = false
        case "c":
            appendCellValueIfNeeded()
            currentCellType = nil
            currentValue = ""
        default:
            break
        }
    }

    private func appendCellValueIfNeeded() {
        let trimmedValue = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return }
        if currentCellType == "s", let index = Int(trimmedValue), sharedStrings.indices.contains(index) {
            parts.append(sharedStrings[index])
        } else if currentCellType != "inlineStr" {
            parts.append(trimmedValue)
        }
    }

    private static func localName(from elementName: String) -> String {
        elementName.split(separator: ":").last.map(String.init) ?? elementName
    }
}

#if DEBUG
enum FileAttachmentTextFixtureFactory {
    static func makeDOCXFixture() throws -> Data {
        try makeArchive(entries: [
            "word/document.xml": """
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
              <w:body>
                <w:p><w:r><w:t>DOCX 第一段</w:t></w:r></w:p>
                <w:p><w:r><w:t>DOCX 第二段</w:t></w:r></w:p>
              </w:body>
            </w:document>
            """
        ])
    }

    static func makePPTXFixture() throws -> Data {
        try makeArchive(entries: [
            "ppt/slides/slide1.xml": """
            <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
              <p:cSld>
                <p:spTree>
                  <p:sp><p:txBody><a:p><a:r><a:t>PPTX 第一页</a:t></a:r></a:p></p:txBody></p:sp>
                </p:spTree>
              </p:cSld>
            </p:sld>
            """,
            "ppt/slides/slide2.xml": """
            <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
              <p:cSld>
                <p:spTree>
                  <p:sp><p:txBody><a:p><a:r><a:t>PPTX 第二页</a:t></a:r></a:p></p:txBody></p:sp>
                </p:spTree>
              </p:cSld>
            </p:sld>
            """
        ])
    }

    static func makeXLSXFixture() throws -> Data {
        try makeArchive(entries: [
            "xl/sharedStrings.xml": """
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <si><t>XLSX 共享文本</t></si>
              <si><t>XLSX 第二项</t></si>
            </sst>
            """,
            "xl/worksheets/sheet1.xml": """
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <sheetData>
                <row>
                  <c t="s"><v>0</v></c>
                  <c><v>42</v></c>
                  <c t="inlineStr"><is><t>XLSX 内联文本</t></is></c>
                </row>
              </sheetData>
            </worksheet>
            """
        ])
    }

    private static func makeArchive(entries: [String: String]) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create)
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        for (path, content) in entries {
            let fileURL = tempDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("xml")
            try Data(content.utf8).write(to: fileURL, options: .atomic)
            try archive.addEntry(with: path, fileURL: fileURL, compressionMethod: .none)
        }

        guard let data = archive.data else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}
#endif
