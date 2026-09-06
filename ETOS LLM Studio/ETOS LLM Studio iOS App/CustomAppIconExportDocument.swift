// ============================================================================
// CustomAppIconExportDocument.swift
// ============================================================================
// 文件导出器直接使用已编码的数据，避免在界面刷新时重复编码图片。
// ============================================================================

import Foundation
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct CustomAppIconExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
