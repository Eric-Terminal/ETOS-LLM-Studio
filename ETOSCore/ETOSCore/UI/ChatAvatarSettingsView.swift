import Combine
import SwiftUI
import UniformTypeIdentifiers
#if !os(watchOS)
import PhotosUI
#endif

public struct ChatAvatarSettingsView: View {
    @ObservedObject private var model = ChatAvatarModel.shared
    private let decorate: (AnyView) -> AnyView
    private let isActive: Bool

    public init(isActive: Bool = true, decorate: @escaping (AnyView) -> AnyView = { $0 }) {
        self.isActive = isActive
        self.decorate = decorate
    }

    public var body: some View {
        Form {
            Section {
                Toggle(NSLocalizedString("avatar.show_ai", value: "Show AI Avatar", comment: ""), isOn: Binding(
                    get: { model.configuration.showAssistant }, set: { model.setVisibility(assistant: true, visible: $0) }))
                Toggle(NSLocalizedString("avatar.show_user", value: "Show User Avatar", comment: ""), isOn: Binding(
                    get: { model.configuration.showUser }, set: { model.setVisibility(assistant: false, visible: $0) }))
            } footer: {
                Text(NSLocalizedString("avatar.visibility_help", value: "The two avatars can be shown independently. Changes apply to all conversations.", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                NavigationLink(NSLocalizedString("avatar.default_ai", value: "Default AI Avatar", comment: "")) {
                    decorate(AnyView(ChatAvatarEditorView(target: .assistant, isActive: isActive)))
                }
                NavigationLink(NSLocalizedString("avatar.default_user", value: "User Avatar", comment: "")) {
                    decorate(AnyView(ChatAvatarEditorView(target: .user, isActive: isActive)))
                }
            }
            Section {
                settingsIntroCard
            }
            if let error = model.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .navigationTitle(NSLocalizedString("avatar.settings", value: "Chat Avatars", comment: ""))
        .guideSettingsPageContext(id: "settings-chat-avatars",
            title: NSLocalizedString("avatar.settings", value: "Chat Avatars", comment: ""),
            documents: [GuideDocumentReference(id: "chat-avatars", title: "Chat Avatars")], isActive: isActive,
            settings: [
                .bool("show_ai_avatar", label: NSLocalizedString("avatar.show_ai", value: "Show AI Avatar", comment: ""),
                      get: { model.configuration.showAssistant }, set: { model.setVisibility(assistant: true, visible: $0) }),
                .bool("show_user_avatar", label: NSLocalizedString("avatar.show_user", value: "Show User Avatar", comment: ""),
                      get: { model.configuration.showUser }, set: { model.setVisibility(assistant: false, visible: $0) }),
                .readOnly("has_default_ai_avatar", label: NSLocalizedString("avatar.default_ai", value: "Default AI Avatar", comment: ""),
                          value: { .bool(model.configuration.files[ChatAvatarTarget.assistant.key] != nil) }),
                .readOnly("has_user_avatar", label: NSLocalizedString("avatar.default_user", value: "User Avatar", comment: ""),
                          value: { .bool(model.configuration.files[ChatAvatarTarget.user.key] != nil) })
            ])
    }

    private var settingsIntroCard: some View {
        VStack(alignment: .leading) {
            Label(NSLocalizedString("avatar.help_title", value: "How Avatars Are Chosen", comment: ""), systemImage: "info.circle")
                .font(.headline)
            Text(NSLocalizedString("avatar.visibility_help", value: "The two avatars can be shown independently. Changes apply to all conversations.", comment: ""))
                .font(.footnote).foregroundStyle(.secondary)
            NavigationLink(NSLocalizedString("进一步了解…", value: "Learn more…", comment: "")) {
                decorate(AnyView(ChatAvatarIntroductionView(isActive: isActive)))
            }
            .font(.footnote)
            .buttonStyle(.plain)
        }
    }
}

private struct ChatAvatarIntroductionView: View {
    let isActive: Bool
    var body: some View {
        List {
            Text(NSLocalizedString("avatar.help", value: "Enable AI and user avatars separately. AI avatars appear to the left of messages; your avatar appears to the right. Without an image, a system symbol is shown.\n\nChoose default images in Chat Avatars. In the global prompt list, use Set Avatar to give a prompt its own AI image. Selecting that prompt also selects its avatar.\n\nFor roleplay conversations, the first active character card and the bound user persona take priority. Change the character image in the card details and the user image in User Personas. Missing images fall back to the prompt or default image. Native avatars do not depend on HTML support in the card.\n\nImage changes save immediately and affect existing messages as well. Choose a photo or image file on iPhone and Mac; on Apple Watch, load an image from an HTTP or HTTPS URL. Clear an image to use the next available source. Avatars are only for display and are not sent to the model.", comment: ""))
                .font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle(NSLocalizedString("avatar.help_title", value: "How Avatars Are Chosen", comment: ""))
        .guideSettingsPageContext(id: "settings-chat-avatars-introduction",
            title: NSLocalizedString("avatar.help_title", value: "How Avatars Are Chosen", comment: ""),
            documents: [GuideDocumentReference(id: "chat-avatars", title: "Chat Avatars")], isActive: isActive, settings: [])
    }
}

public struct ChatAvatarEditorView: View {
    let target: ChatAvatarTarget
    let isActive: Bool
    @State private var fileName: String?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var urlText = ""
    #if !os(watchOS)
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    #endif

    public init(target: ChatAvatarTarget, isActive: Bool = true) {
        self.target = target
        self.isActive = isActive
    }

    public var body: some View {
        Form {
            Section {
                ChatAvatarImage(fileName: fileName, isUser: isUser)
                    .accessibilityLabel(NSLocalizedString("头像", value: "Avatar", comment: ""))
                #if !os(watchOS)
                PhotosPicker(selection: $photo, matching: .images) {
                    Label(NSLocalizedString("从照片选择", value: "Choose from Photos", comment: ""), systemImage: "photo")
                }
                Button { importing = true } label: {
                    Label(NSLocalizedString("从文件选择", value: "Choose from Files", comment: ""), systemImage: "folder")
                }
                #else
                TextField(NSLocalizedString("头像链接", value: "Avatar URL", comment: ""), text: $urlText)
                Button(NSLocalizedString("从 URL 载入头像", value: "Load Avatar from URL", comment: "")) { loadURL() }
                #endif
                if fileName != nil {
                    Button(NSLocalizedString("avatar.clear", value: "Clear Avatar", comment: ""), role: .destructive) { save(nil) }
                }
            } footer: {
                Text(NSLocalizedString("avatar.editor_help", value: "Changes save immediately. Clearing this image uses the next available avatar or a system symbol.", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if isWorking { ProgressView() }
            if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
        }
        .buttonStyle(.borderless)
        .disabled(isWorking)
        .navigationTitle(NSLocalizedString("avatar.set", value: "Set Avatar", comment: ""))
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: ChatAvatarStore.didChange).receive(on: DispatchQueue.main)) { _ in
            Task { await reload() }
        }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "settings-avatar-\(target.key)"),
            title: NSLocalizedString("avatar.set", value: "Set Avatar", comment: ""),
            documents: [GuideDocumentReference(id: "chat-avatars", title: "Chat Avatars")], isActive: isActive,
            settings: [
                .readOnly("has_avatar", label: NSLocalizedString("头像", value: "Avatar", comment: ""), value: { .bool(fileName != nil) }),
                .readOnly("saving", label: NSLocalizedString("保存", value: "Save", comment: ""), value: { .bool(isWorking) })
            ])
        #if !os(watchOS)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                isWorking = true
                Task {
                    defer { isWorking = false }
                    do {
                        let data = try await Task.detached {
                            let access = url.startAccessingSecurityScopedResource()
                            defer { if access { url.stopAccessingSecurityScopedResource() } }
                            return try Data(contentsOf: url)
                        }.value
                        try await persist(data)
                    } catch { errorMessage = error.localizedDescription }
                }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            isWorking = true
            Task {
                defer { isWorking = false; photo = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                    try await persist(data)
                } catch { errorMessage = error.localizedDescription }
            }
        }
        #endif
    }

    private var isUser: Bool {
        switch target {
        case .user, .persona: true
        default: false
        }
    }

    private func reload() async {
        let target = target
        fileName = await Task.detached { ChatAvatarStore.shared.fileName(for: target) }.value
    }

    private func persist(_ data: Data?) async throws {
        let target = target
        try await Task.detached { try ChatAvatarStore.shared.setImage(data, for: target) }.value
        errorMessage = nil
        await reload()
    }

    private func save(_ data: Data?) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do { try await persist(data) } catch { errorMessage = error.localizedDescription }
        }
    }

    private func loadURL() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            errorMessage = NSLocalizedString("仅支持 http/https 链接。", value: "Only HTTP and HTTPS URLs are supported.", comment: "")
            return
        }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                try await persist(data)
                urlText = ""
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
