import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ChatAvatarTarget: Hashable, Sendable {
    case assistant, user, prompt(UUID), character(UUID), persona(UUID)

    public var key: String {
        switch self {
        case .assistant: "assistant"
        case .user: "user"
        case .prompt(let id): "prompt-\(id)"
        case .character(let id): "character-\(id)"
        case .persona(let id): "persona-\(id)"
        }
    }
}

struct ChatAvatarConfiguration: Codable, Equatable, Sendable {
    var showAssistant = false
    var showUser = false
    var files: [String: String] = [:]

    func isVisible(role: MessageRole) -> Bool {
        switch role {
        case .assistant: showAssistant
        case .user: showUser
        default: false
        }
    }
}

struct ChatAvatarPair: Equatable, Sendable {
    var assistant: String?
    var user: String?

    /// 缺少酒馆头像时仍可使用普通聊天头像；HTML 开关不参与原生气泡的选择。
    static func resolve(configuration: ChatAvatarConfiguration, promptID: UUID?, character: RoleplayCharacter?, persona: PersonaProfile?) -> Self {
        Self(assistant: character?.avatarFileName
             ?? promptID.flatMap { configuration.files[ChatAvatarTarget.prompt($0).key] }
             ?? configuration.files[ChatAvatarTarget.assistant.key],
             user: persona?.avatarFileName ?? configuration.files[ChatAvatarTarget.user.key])
    }
}

/// 图片与配置写入均由后台调用；串行修改避免两个设置页互相覆盖。
public final class ChatAvatarStore: @unchecked Sendable {
    public static let shared = ChatAvatarStore()
    public static let didChange = Notification.Name("com.ETOS.chatAvatars.didChange")
    static let storageKey = "chat_avatars_v1"
    private let queue = DispatchQueue(label: "com.ETOS.chatAvatars")

    func load() -> ChatAvatarConfiguration {
        queue.sync { loadUnlocked() }
    }

    private func loadUnlocked() -> ChatAvatarConfiguration {
        Persistence.loadAuxiliaryBlob(ChatAvatarConfiguration.self, forKey: Self.storageKey) ?? .init()
    }

    func setVisibility(assistant: Bool, visible: Bool) throws {
        try queue.sync {
            var configuration = loadUnlocked()
            if assistant { configuration.showAssistant = visible } else { configuration.showUser = visible }
            guard Persistence.saveAuxiliaryBlob(configuration, forKey: Self.storageKey) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        notifyChange()
    }

    func fileName(for target: ChatAvatarTarget) -> String? {
        switch target {
        case .character(let id): RoleplayStore.shared.character(id: id)?.avatarFileName
        case .persona(let id): RoleplayStore.shared.persona(id: id)?.avatarFileName
        default: load().files[target.key]
        }
    }

    public func setImage(_ data: Data?, for target: ChatAvatarTarget) throws {
        try queue.sync {
            let previous: String?
            switch target {
            case .character(let id): previous = RoleplayStore.shared.character(id: id)?.avatarFileName
            case .persona(let id): previous = RoleplayStore.shared.persona(id: id)?.avatarFileName
            default: previous = loadUnlocked().files[target.key]
            }
            let name = try data.map { data in
                let png = try Self.prepareImage(data)
                let name = "chat-avatar-\(UUID().uuidString).png"
                guard Persistence.saveImage(png, fileName: name) != nil else { throw CocoaError(.fileWriteUnknown) }
                return name
            }
            do {
                switch target {
                case .character(let id):
                    guard let original = RoleplayStore.shared.character(id: id) else { throw RoleplayDraftWriteError.changedExternally }
                    var draft = original
                    draft.avatarFileName = name
                    try RoleplayStore.shared.saveCharacterDraft(draft, replacing: original)
                case .persona(let id):
                    guard let original = RoleplayStore.shared.persona(id: id) else { throw RoleplayDraftWriteError.changedExternally }
                    var draft = original
                    draft.avatarFileName = name
                    try RoleplayStore.shared.savePersonaDraft(draft, replacing: original)
                default:
                    if case .prompt(let id) = target,
                       !GlobalSystemPromptStore.load().entries.contains(where: { $0.id == id }) {
                        throw RoleplayDraftWriteError.changedExternally
                    }
                    var configuration = loadUnlocked()
                    configuration.files[target.key] = name
                    guard Persistence.saveAuxiliaryBlob(configuration, forKey: Self.storageKey) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
            } catch {
                if let name { Persistence.deleteImage(fileName: name) }
                throw error
            }
            // 只清理本功能创建且没有其他引用的文件；导入角色卡的原始资源始终保留。
            if let previous, previous.hasPrefix("chat-avatar-"), previous != name {
                let library = RoleplayStore.shared.queue.sync { RoleplayStore.shared.loadLibraryUnlocked() }
                var referenced = Set(loadUnlocked().files.values)
                referenced.formUnion(library.characters.compactMap(\.avatarFileName))
                referenced.formUnion(library.characters.flatMap { $0.assets ?? [] }.compactMap(\.localFileName))
                referenced.formUnion(library.personas.compactMap(\.avatarFileName))
                if !referenced.contains(previous) { Persistence.deleteImage(fileName: previous) }
            }
        }
        notifyChange()
    }

    func copyPromptAvatar(from source: UUID, to destination: UUID) {
        queue.sync {
            var configuration = loadUnlocked()
            configuration.files[ChatAvatarTarget.prompt(destination).key] = configuration.files[ChatAvatarTarget.prompt(source).key]
            _ = Persistence.saveAuxiliaryBlob(configuration, forKey: Self.storageKey)
        }
        notifyChange()
    }

    /// 只保留显示需要的位图，去掉照片元数据并限制解码后的存储尺寸。
    static func prepareImage(_ data: Data) throws -> Data {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return result as Data
    }

    private func notifyChange() {
        WatchDatabaseSyncService.markDatabaseChanged(.config)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
    }
}
