import Combine
import SwiftUI

@MainActor
public final class ChatAvatarModel: ObservableObject {
    public static let shared = ChatAvatarModel()
    @Published var configuration = ChatAvatarConfiguration()
    @Published private var ordinary = ChatAvatarPair()
    @Published private var sessions: [UUID: ChatAvatarPair] = [:]
    @Published var errorMessage: String?
    private var pendingWrite: Task<Void, Never>?
    private var pendingVisibility: [Bool: (id: UUID, visible: Bool)] = [:]
    private var observations = Set<AnyCancellable>()
    private var revision = UUID()

    private init() {
        for name in [ChatAvatarStore.didChange, .globalSystemPromptStoreDidChange,
                     RoleplayStore.didChangeNotification, AppConfigStore.persistentStoreDidLoadNotification, .snapshotRestoreDidFinish] {
            NotificationCenter.default.publisher(for: name)
                .filter { notification in
                    notification.name != RoleplayStore.didChangeNotification
                    || notification.userInfo?[RoleplayStore.changeKindUserInfoKey] as? String != RoleplayStore.variablesChangeKind
                }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.reload() }
                .store(in: &observations)
        }
        reload()
    }

    public func reload() {
        let token = UUID()
        revision = token
        Task { [weak self] in
            let result = await Task.detached {
                let configuration = ChatAvatarStore.shared.load()
                let promptID = GlobalSystemPromptStore.load().selectedEntryID
                let store = RoleplayStore.shared
                let library = store.queue.sync { store.loadLibraryUnlocked() }
                let characters = Dictionary(uniqueKeysWithValues: library.characters.map { ($0.id, $0) })
                let personas = Dictionary(uniqueKeysWithValues: library.personas.map { ($0.id, $0) })
                let ordinary = ChatAvatarPair.resolve(configuration: configuration, promptID: promptID, character: nil, persona: nil)
                var sessions: [UUID: ChatAvatarPair] = [:]
                for binding in library.bindings {
                    // 与酒馆运行时一致：至少一个有效角色才启用酒馆身份。
                    guard let character = binding.characterIDs.compactMap({ characters[$0] }).first else { continue }
                    sessions[binding.sessionID] = .resolve(configuration: configuration, promptID: promptID,
                        character: character, persona: binding.personaID.flatMap { personas[$0] })
                }
                return (configuration, ordinary, sessions)
            }.value
            guard let self, self.revision == token else { return }
            var configuration = result.0
            if let pending = self.pendingVisibility[true] { configuration.showAssistant = pending.visible }
            if let pending = self.pendingVisibility[false] { configuration.showUser = pending.visible }
            self.configuration = configuration
            self.ordinary = result.1
            self.sessions = result.2
        }
    }

    func setVisibility(assistant: Bool, visible: Bool) {
        let id = UUID()
        pendingVisibility[assistant] = (id, visible)
        if assistant { configuration.showAssistant = visible } else { configuration.showUser = visible }
        let previous = pendingWrite
        pendingWrite = Task { [weak self] in
            await previous?.value
            do {
                try await Task.detached {
                    try ChatAvatarStore.shared.setVisibility(assistant: assistant, visible: visible)
                }.value
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            if self?.pendingVisibility[assistant]?.id == id { self?.pendingVisibility[assistant] = nil }
            self?.reload()
        }
    }

    public func isVisible(role: MessageRole) -> Bool {
        configuration.isVisible(role: role)
    }

    func fileName(role: MessageRole, sessionID: UUID?) -> String? {
        let pair = sessionID.flatMap { sessions[$0] } ?? ordinary
        return role == .user ? pair.user : pair.assistant
    }
}

/// 每行只查已准备好的字典；图片加载器在后台合并同一头像的请求与缓存。
public struct ChatMessageAvatar: View {
    @ObservedObject private var model = ChatAvatarModel.shared
    let role: MessageRole
    let sessionID: UUID?

    public init(role: MessageRole, sessionID: UUID?) {
        self.role = role
        self.sessionID = sessionID
    }

    public var body: some View {
        if model.isVisible(role: role) {
            ChatAvatarImage(fileName: model.fileName(role: role, sessionID: sessionID), isUser: role == .user)
                .accessibilityHidden(true)
        }
    }
}

public struct ChatAvatarImage: View {
    let fileName: String?
    let isUser: Bool
    @State private var image: PreparedDisplayImage?
    @Environment(\.displayScale) private var scale
    #if os(watchOS)
    public static let diameter: CGFloat = 24
    #else
    public static let diameter: CGFloat = 32
    #endif

    public init(fileName: String?, isUser: Bool = false) {
        self.fileName = fileName
        self.isUser = isUser
    }

    public var body: some View {
        Group {
            if let image {
                #if canImport(UIKit)
                Image(uiImage: image.image).resizable().scaledToFill()
                #else
                Image(nsImage: image.image).resizable().scaledToFill()
                #endif
            } else {
                Image(systemName: isUser ? "person.crop.circle.fill" : "sparkles")
                    .resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .clipShape(Circle())
        .task(id: "\(fileName ?? "")|\(scale)") {
            image = nil
            guard let fileName else { return }
            let prepared = await DisplayImageLoader.shared.attachment(named: fileName,
                target: DisplayImageTarget(size: CGSize(width: Self.diameter, height: Self.diameter), scale: scale))
            guard !Task.isCancelled else { return }
            image = prepared
        }
    }
}
