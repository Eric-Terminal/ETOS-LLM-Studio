import CryptoKit
import Foundation

/// 锚点保存文件版本而非仅保存 ID，避免每次刷新都把未变化的文件重新交给系统。
public struct ETOSWorkspaceSyncSnapshot: Codable, Equatable {
    public let versions: [String: Data]

    public init(versions: [String: Data]) {
        self.versions = versions
    }

    public func updatedIdentifiers(since previous: Self) -> Set<String> {
        Set(versions.keys.filter { versions[$0] != previous.versions[$0] })
    }

    public func deletedIdentifiers(since previous: Self) -> Set<String> {
        Set(previous.versions.keys).subtracting(versions.keys)
    }
}

public struct ETOSWorkspaceSyncAnchorStore {
    public enum AnchorError: Error {
        case expired
    }

    private let directory: URL
    private let fileManager: FileManager

    public init(receipts: URL, containerIdentifier: String, fileManager: FileManager = .default) {
        let digest = SHA256.hash(data: Data(containerIdentifier.utf8))
            .map { String(format: "%02x", $0) }.joined()
        directory = receipts.appendingPathComponent("FileProviderAnchors", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
        self.fileManager = fileManager
    }

    public func save(_ snapshot: ETOSWorkspaceSyncSnapshot) throws -> Data {
        let token = UUID().uuidString
        try ETOSSharedFileStore.write(
            snapshot,
            to: directory.appendingPathComponent("\(token).json"),
            fileManager: fileManager
        )
        return Data(token.utf8)
    }

    public func load(_ anchor: Data) throws -> ETOSWorkspaceSyncSnapshot {
        guard let token = String(data: anchor, encoding: .utf8), UUID(uuidString: token) != nil else {
            throw AnchorError.expired
        }
        let url = directory.appendingPathComponent("\(token).json")
        do {
            return try ETOSSharedFileStore.read(
                ETOSWorkspaceSyncSnapshot.self, from: url, maximumBytes: 64 * 1_024 * 1_024
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw AnchorError.expired
        } catch is DecodingError {
            // 旧版锚点只含顶层 ID，无法补报之前漏掉的删除，必须让系统重新枚举。
            throw AnchorError.expired
        }
    }

    /// 只在系统拿着有效旧锚点请求增量后回收更早记录，保留本轮前后两份以容纳重试。
    public func prune(keeping anchors: [Data]) throws {
        let names = Set(anchors.compactMap { String(data: $0, encoding: .utf8) }.map { "\($0).json" })
        for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard url.pathExtension == "json", !names.contains(url.lastPathComponent) else { continue }
            try fileManager.removeItem(at: url)
        }
    }
}
