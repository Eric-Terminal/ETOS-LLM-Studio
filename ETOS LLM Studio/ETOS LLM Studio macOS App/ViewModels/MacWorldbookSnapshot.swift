import ETOSCore
import Foundation

struct MacWorldbookEntryRow: Identifiable, Sendable {
    let entry: WorldbookEntry
    let title: String
    let preview: String
    var id: UUID { entry.id }
}

struct MacWorldbookRow: Identifiable, Sendable {
    let book: Worldbook
    let summary: String
    let date: String
    let entries: [MacWorldbookEntryRow]
    let guideValue: JSONValue
    var id: UUID { book.id }
}

struct MacWorldbookSnapshot: Sendable {
    let allBooks: [Worldbook]
    let rows: [MacWorldbookRow]
    let byID: [UUID: MacWorldbookRow]
    let guideValue: JSONValue

    static func prepare(_ books: [Worldbook], query: String) -> Self {
        let all = books.map { book in
            let entries = book.entries.map { entry in
                let title = entry.comment.trimmingCharacters(in: .whitespacesAndNewlines)
                return MacWorldbookEntryRow(entry: entry, title: title.isEmpty ? String(entry.content.prefix(80)) : title,
                                           preview: String(entry.content.prefix(180)))
            }
            let value = JSONValue.dictionary([
                "id": .string(book.id.uuidString), "name": .string(book.name), "enabled": .bool(book.isEnabled),
                "entry_count": .int(book.entries.count)
            ])
            return MacWorldbookRow(book: book,
                                   summary: String(format: NSLocalizedString("worldbook.binding.entries", comment: ""), book.entries.filter(\.isEnabled).count, book.entries.count),
                                   date: book.updatedAt.formatted(date: .abbreviated, time: .shortened), entries: entries, guideValue: value)
        }
        let rows = all.filter { row in
            query.isEmpty || row.book.name.localizedStandardContains(query) || row.book.description.localizedStandardContains(query)
                || row.entries.contains { $0.entry.comment.localizedStandardContains(query) || $0.entry.content.localizedStandardContains(query)
                    || $0.entry.keys.contains { $0.localizedStandardContains(query) }
                    || $0.entry.secondaryKeys.contains { $0.localizedStandardContains(query) } }
        }
        return Self(allBooks: books, rows: rows, byID: Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) }),
                    guideValue: .array(rows.map(\.guideValue)))
    }
}

struct MacWorldbookEntryDraft: Identifiable, Sendable {
    var entry: WorldbookEntry
    var keysText: String
    var secondaryKeysText: String
    var secondaryKeysEnabled: Bool
    var id: UUID { entry.id }

    init(entry: WorldbookEntry) {
        self.entry = entry
        keysText = entry.keys.joined(separator: "\n")
        secondaryKeysText = entry.secondaryKeys.joined(separator: "\n")
        secondaryKeysEnabled = entry.secondaryKeysEnabled
    }

    func preparedEntry() throws -> WorldbookEntry {
        var result = entry
        result.keys = Self.keywords(keysText)
        result.secondaryKeys = Self.keywords(secondaryKeysText)
        result.metadata[WorldbookMetadataKey.etosSecondaryKeysEnabled] = result.secondaryKeys.isEmpty ? nil : .bool(secondaryKeysEnabled)
        // 从原条目副本写回，保留 uid、未展示的兼容字段和未知扩展。
        result.comment = result.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        result.content = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.content.isEmpty else { throw MacWorldbookEntryError.contentRequired }
        guard result.constant || !result.keys.isEmpty else { throw MacWorldbookEntryError.keywordsRequired }
        result.probability = min(100, max(1, result.probability))
        result.order = max(0, result.order)
        if result.position == .atDepth { result.depth = max(0, result.depth ?? 0) }
        result.scanDepth = result.scanDepth.map { max(1, $0) }
        result.sticky = result.sticky.map { max(1, $0) }
        result.cooldown = result.cooldown.map { max(1, $0) }
        result.delay = result.delay.map { max(1, $0) }
        return result
    }

    private static func keywords(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: CharacterSet(charactersIn: ",，\n")).compactMap {
            let word = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, seen.insert(word.lowercased()).inserted else { return nil }
            return word
        }
    }
}

enum MacWorldbookEntryError: LocalizedError {
    case contentRequired
    case keywordsRequired
    var errorDescription: String? {
        switch self {
        case .contentRequired: return NSLocalizedString("请填写条目正文。", comment: "")
        case .keywordsRequired: return NSLocalizedString("普通条目需要主关键词；无需关键词时请开启常驻激活。", comment: "")
        }
    }
}
