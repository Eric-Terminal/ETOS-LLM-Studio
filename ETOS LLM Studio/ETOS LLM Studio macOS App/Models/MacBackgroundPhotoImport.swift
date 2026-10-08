@preconcurrency import CoreTransferable
import Foundation
import ImageIO
@preconcurrency import PhotosUI
import UniformTypeIdentifiers

extension MacBackgroundLibrary {
    func importPhoto(_ item: PhotosPickerItem) async throws -> MacBackgroundFile {
        try Task.checkCancellation()
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            guard let video = try await item.loadTransferable(type: MacPickedBackgroundVideo.self) else { throw LibraryError.invalidMedia }
            defer { video.file.remove() }
            try Task.checkCancellation()
            return try await importFile(video.file.url)
        }
        guard let data = try await item.loadTransferable(type: Data.self),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw LibraryError.invalidMedia }
        try Task.checkCancellation()
        let size = try MacBackgroundImageEditing.pixelSize(source)
        let image = try MacBackgroundImageEditing.decode(source, maximumDimension: Int(max(size.width, size.height)))
        return try await importImage(image)
    }
}

private struct MacPickedBackgroundVideo: Transferable, Sendable {
    let file: MacBackgroundPhotoFile
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let source = received.file
            // 系统交付文件的有效期只覆盖此回调；后台复制完成后才交还控制权。
            let worker = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let file = try MacBackgroundPhotoFile(copying: source)
                do { try Task.checkCancellation(); return file }
                catch { file.remove(); throw error }
            }
            let file = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            return Self(file: file)
        }
    }
}

/// PhotosUI 取消可能丢弃已完成转换的结果；引用所有权保证该临时文件仍会回收。
/// 正常路径由后台导入 actor 显式删除，析构路径只排队清理，不在主线程做磁盘操作。
private final class MacBackgroundPhotoFile: @unchecked Sendable {
    let url: URL
    private var removed = false
    private static let cleanupQueue = DispatchQueue(label: "com.etos.mac-background-photo-cleanup", qos: .utility)

    init(copying source: URL) throws {
        let suffix = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("background-photo-\(UUID().uuidString).\(suffix)")
        do { try FileManager.default.copyItem(at: source, to: url) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
    }

    func remove() {
        guard !removed else { return }
        removed = true
        try? FileManager.default.removeItem(at: url)
    }

    deinit {
        if !removed {
            let url = url
            Self.cleanupQueue.async { try? FileManager.default.removeItem(at: url) }
        }
    }
}
