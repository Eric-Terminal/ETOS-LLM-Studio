import Foundation

/// 只把列表需要的摘要交给界面，条目计数、排序和角色来源解析都在后台完成。
struct WorldbookBindingSnapshot: Sendable {
    struct Row: Identifiable, Sendable {
        let id: UUID
        let name: String
        let entryCount: Int
        let enabledEntryCount: Int
        let isEnabled: Bool
        let roleplaySource: String?
    }

    let rows: [Row]
    let availableIDs: Set<UUID>
    let roleplayIDs: Set<UUID>
    let guideValue: JSONValue
    let selectionSchema: JSONValue

    static func load(sessionID: UUID?) -> Self {
        let service = ChatService.shared
        return Self(
            worldbooks: service.loadWorldbooks(),
            characters: service.loadRoleplayCharacters(),
            binding: sessionID.flatMap { service.roleplayBinding(sessionID: $0) }
        )
    }

    init(worldbooks: [Worldbook], characters: [RoleplayCharacter], binding: SessionRoleplayBinding?) {
        var sources: [UUID: [String]] = [:]
        if let binding {
            let charactersByID = Dictionary(uniqueKeysWithValues: characters.map { ($0.id, $0) })
            let boundCharacters = binding.characterIDs.compactMap { charactersByID[$0] }
            // 与请求侧一致：只有实际绑定了可用角色时，角色附加世界书才会参与注入。
            if !boundCharacters.isEmpty {
                for character in boundCharacters {
                    if let id = character.embeddedWorldbookID {
                        sources[id, default: []].append(character.name)
                    }
                }
                for id in binding.additionalWorldbookIDs where sources[id] == nil {
                    sources[id] = [NSLocalizedString("worldbook.binding.role_additional", value: "Roleplay settings", comment: "角色扮演附加世界书来源")]
                }
            }
        }
        rows = worldbooks.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }.map { book in
            Row(
                id: book.id,
                name: book.name,
                entryCount: book.entries.count,
                enabledEntryCount: book.entries.filter(\.isEnabled).count,
                isEnabled: book.isEnabled,
                roleplaySource: sources[book.id]?.joined(separator: ", ")
            )
        }
        availableIDs = Set(rows.map(\.id))
        roleplayIDs = Set(sources.keys).intersection(availableIDs)
        guideValue = .array(rows.map { row in
            .dictionary([
                "id": .string(row.id.uuidString),
                "name": .string(row.name),
                "enabled": .bool(row.isEnabled),
                "entry_count": .int(row.entryCount),
                "enabled_entry_count": .int(row.enabledEntryCount),
                "roleplay_source": row.roleplaySource.map(JSONValue.string) ?? .null
            ])
        })
        selectionSchema = .dictionary([
            "type": .string("array"),
            "items": .dictionary([
                "type": .string("string"),
                "enum": .array(rows.map { .string($0.id.uuidString) })
            ]),
            "uniqueItems": .bool(true)
        ])
    }

    func selection(from value: JSONValue) throws -> Set<UUID> {
        guard case .array(let values) = value else { throw GuideError.invalidToolArguments }
        var ids = Set<UUID>()
        for value in values {
            guard case .string(let rawValue) = value,
                  let id = UUID(uuidString: rawValue),
                  availableIDs.contains(id), ids.insert(id).inserted else {
                throw GuideError.invalidToolArguments
            }
        }
        return ids
    }
}
