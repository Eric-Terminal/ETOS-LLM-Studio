import ETOSCore
import Foundation

enum MacSessionScope: Hashable, Sendable {
    case all, unfiled, folder(UUID), tag(UUID)
}

struct MacSessionFolderRow: Identifiable, Sendable {
    let folder: SessionFolder
    let path: String
    let ancestorIDs: Set<UUID>
    let count: Int
    var id: UUID { folder.id }
}

struct MacSessionTagRow: Identifiable, Sendable {
    let tag: SessionTag
    let name: String
    let count: Int
    var id: UUID { tag.id }
}

struct MacSessionLibraryRow: Identifiable, Sendable {
    let session: ChatSession
    let tagIDs: Set<UUID>
    let colors: [SessionTagColor]
    let subtitle: String
    var id: UUID { session.id }
}

/// 文件夹路径、计数、标签和搜索摘要在后台一次性准备，行视图只读取结果。
struct MacSessionLibrarySnapshot: Sendable {
    var folders: [MacSessionFolderRow] = []
    var tags: [MacSessionTagRow] = []
    var colorTags: [MacSessionTagRow] = []
    var sessions: [MacSessionLibraryRow] = []
    var scope: MacSessionScope = .all
    var title = NSLocalizedString("对话", comment: "")
    var allCount = 0
    var unfiledCount = 0
    var folderGuideValues: JSONValue = .array([])
    var tagGuideValues: JSONValue = .array([])
    var folderGuideIDs = [""]

    static func prepare(
        sessions: [ChatSession], folders: [SessionFolder], tags: [SessionTag],
        scope: MacSessionScope, query: String,
        messageLoader: (UUID) -> [ChatMessage]
    ) -> Self {
        var result = Self()
        let sessions = sessions.filter { !$0.isEmbeddedSubagent }
        let foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var tagsByID = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
        for color in SessionTagColor.allCases {
            let tag = SessionTag.systemColorTag(for: color)
            tagsByID[tag.id] = tag
        }
        let folderCounts = Dictionary(grouping: sessions, by: \.folderID).mapValues(\.count)
        var tagCounts: [UUID: Int] = [:]
        for session in sessions {
            for tagID in Set(session.tagIDs) { tagCounts[tagID, default: 0] += 1 }
        }
        result.folders = folders.map { folder in
            var visited: Set<UUID> = [folder.id]
            var names = [folder.name]
            var parentID = folder.parentID
            // 同步数据中损坏的父链不能让桌面列表无限递归。
            while let id = parentID, visited.insert(id).inserted, let parent = foldersByID[id] {
                names.append(parent.name)
                parentID = parent.parentID
            }
            return MacSessionFolderRow(folder: folder, path: names.reversed().joined(separator: " / "), ancestorIDs: visited, count: folderCounts[folder.id] ?? 0)
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        result.tags = tags.filter { !$0.isSystemColorTag }.map {
            MacSessionTagRow(tag: $0, name: $0.name, count: tagCounts[$0.id] ?? 0)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        result.colorTags = SessionTagColor.allCases.map { color in
            let tag = tagsByID[SessionTag.systemColorTagID(for: color)]!
            return MacSessionTagRow(tag: tag, name: color.localizedName, count: tagCounts[tag.id] ?? 0)
        }
        result.folderGuideValues = .array(result.folders.map {
            .dictionary(["id": .string($0.id.uuidString), "path": .string($0.path)])
        })
        result.folderGuideIDs += result.folders.map { $0.id.uuidString }
        result.tagGuideValues = .array((result.tags + result.colorTags).map {
            .dictionary(["id": .string($0.id.uuidString), "name": .string($0.name), "color": .string($0.tag.color?.rawValue ?? ""),
                         "system_color": .bool($0.tag.isSystemColorTag), "count": .int($0.count)])
        })
        result.allCount = sessions.count
        result.unfiledCount = sessions.filter { $0.folderID == nil || foldersByID[$0.folderID!] == nil }.count
        result.scope = scope
        switch scope {
        case .folder(let id):
            if let row = result.folders.first(where: { $0.id == id }) { result.title = row.path }
            else { result.scope = .all }
        case .tag(let id):
            if let tag = tagsByID[id] { result.title = tag.name }
            else { result.scope = .all }
        case .unfiled: result.title = NSLocalizedString("未分类", comment: "")
        case .all: break
        }
        let scoped = sessions.filter { session in
            switch result.scope {
            case .all: true
            case .unfiled: session.folderID == nil || foldersByID[session.folderID!] == nil
            case .folder(let id): session.folderID == id
            case .tag(let id): session.tagIDs.contains(id)
            }
        }
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hits = searching ? SessionHistorySearchSupport.searchHits(sessions: scoped, query: query, messageLoader: messageLoader) : [:]
        result.sessions = scoped.compactMap { session in
            guard !searching || hits[session.id] != nil else { return nil }
            let assigned = session.tagIDs.compactMap { tagsByID[$0] }
            return MacSessionLibraryRow(
                session: session, tagIDs: Set(session.tagIDs), colors: Array(Set(assigned.compactMap(\.color))).sorted { $0.rawValue < $1.rawValue },
                subtitle: hits[session.id]?.preview ?? assigned.map(\.name).joined(separator: " · ")
            )
        }
        return result
    }
}
