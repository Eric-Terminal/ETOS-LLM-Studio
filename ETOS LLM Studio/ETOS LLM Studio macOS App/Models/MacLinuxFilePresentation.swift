import ETOSCore
import Foundation

struct MacLinuxFileRow: Identifiable, Sendable {
    let node: LocalLinuxBrowserNode
    let name: String
    let size: String
    let symbol: String
    var id: String { node.path }
}

struct MacLinuxFileDirectory: Sendable {
    let id = UUID()
    let snapshot: LocalLinuxBrowserDirectory
    let rows: [MacLinuxFileRow]
    let parentPath: String
    let guide: JSONValue
    var path: String { snapshot.node.path }

    static func prepare(_ snapshot: LocalLinuxBrowserDirectory, previous: [MacLinuxFileRow] = []) -> Self {
        let path = snapshot.node.path
        var entries: [String: MacLinuxFileRow] = [:]
        for info in previous.map(\.node.info) + snapshot.page.entries {
            guard let name = info.name, name != ".", name != ".." else { continue }
            let child = path == "/" ? "/\(name)" : "\(path)/\(name)"
            entries[name] = MacLinuxFileRow(node: LocalLinuxBrowserNode(path: child, info: info), name: name,
                size: ByteCountFormatter.string(fromByteCount: Int64(clamping: info.size), countStyle: .file),
                symbol: info.isSymbolicLink ? "link" : info.isDirectory ? "folder" : "doc")
        }
        let rows = entries.values.sorted {
            if $0.node.info.isDirectory != $1.node.info.isDirectory { return $0.node.info.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let parent = (path as NSString).deletingLastPathComponent
        return Self(snapshot: snapshot, rows: rows, parentPath: parent.isEmpty ? "/" : parent,
            guide: .dictionary(["entry_count": .int(rows.count), "complete": .bool(snapshot.page.isComplete), "is_root": .bool(path == "/")]))
    }
}

struct MacLinuxFileEditorTarget: Identifiable, Sendable {
    let id: UUID
    let preview: LocalLinuxBrowserPreview
    let title: String
    let size: String
    let notice: String?

    static func prepare(_ preview: LocalLinuxBrowserPreview, id: UUID = UUID()) -> Self {
        let notice: String?
        switch preview.readOnlyReason {
        case .large: notice = NSLocalizedString("仅预览前 256 KiB；为避免覆盖未显示内容，此文件不可编辑。", comment: "")
        case .binary: notice = NSLocalizedString("二进制文件不提供文本编辑。", comment: "")
        case .invalidUTF8: notice = NSLocalizedString("此文件不是有效的 UTF-8 文本，仅供预览。", comment: "")
        case .special: notice = NSLocalizedString("设备、管道和其他特殊文件不提供文本预览。", comment: "")
        case nil: notice = nil
        }
        return Self(id: id, preview: preview, title: (preview.node.path as NSString).lastPathComponent,
            size: ByteCountFormatter.string(fromByteCount: Int64(clamping: preview.resolvedInfo.size), countStyle: .file), notice: notice)
    }
}

enum MacLinuxFileOpenResult: Sendable {
    case directory(String)
    case file(MacLinuxFileEditorTarget)
}

struct MacLinuxFileDeletion: Identifiable, Sendable {
    let id = UUID()
    let node: LocalLinuxBrowserNode
    let lease: UUID
    let revision: UUID
}
