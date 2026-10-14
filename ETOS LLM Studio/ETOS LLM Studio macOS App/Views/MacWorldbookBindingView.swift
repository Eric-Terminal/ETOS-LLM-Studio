import ETOSCore
import SwiftUI

struct MacWorldbookBindingView: View {
    @ObservedObject var model: MacWorldbookModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    let session: ChatSession
    @State private var library: WorldbookBindingSnapshot?
    @State private var selected = Set<UUID>()
    @State private var refreshID = UUID()
    @State private var isSaving = false
    @State private var error: String?

    init(model: MacWorldbookModel, session: ChatSession) {
        self.model = model
        self.session = session
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { LabeledContent(NSLocalizedString("当前会话", comment: ""), value: session.name) }
                Section {
                    if let library {
                        ForEach(library.rows) { row in
                            Toggle(isOn: Binding(get: { selected.contains(row.id) }, set: {
                                if $0 { selected.insert(row.id) } else { selected.remove(row.id) }
                            })) {
                                VStack(alignment: .leading) {
                                    Text(row.name)
                                    Text(String(format: NSLocalizedString("worldbook.binding.entries", comment: ""), row.enabledEntryCount, row.entryCount))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if !row.isEnabled { Text(NSLocalizedString("worldbook.binding.disabled", comment: "")).font(.caption).foregroundStyle(.secondary) }
                                    if let source = row.roleplaySource {
                                        Text(String(format: NSLocalizedString("worldbook.binding.role_source", comment: ""), source)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if library.rows.isEmpty { Text(NSLocalizedString("worldbook.binding.empty", comment: "")).font(.footnote).foregroundStyle(.secondary) }
                    } else { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
                } footer: {
                    Text(NSLocalizedString("修改保留为草稿，点击保存后生效。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                    Text(NSLocalizedString("worldbook.binding.role_hint", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    MacSettingsIntroCard(id: "worldbook-binding", title: NSLocalizedString("世界书", comment: ""),
                                         details: NSLocalizedString("Mac 世界书使用说明", comment: ""), documentID: "worldbooks")
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .disabled(isSaving || workspace.isRestoringData)
            .navigationTitle(NSLocalizedString("会话绑定世界书", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) { save() }.disabled(library == nil || isSaving || model.isWorking || workspace.isRestoringData)
                }
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-worldbook-binding-\(session.id)"), title: NSLocalizedString("会话绑定世界书", comment: ""),
                documents: [GuideDocumentReference(id: "worldbooks", title: "Worldbooks"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
                settings: guideSettings
            )
        }
        .modifier(MacGuideInspector())
        .interactiveDismissDisabled(isSaving)
        .frame(minWidth: 500, minHeight: 440)
        .task(id: refreshID) {
            let session = session
            let result = await Task.detached { (WorldbookBindingSnapshot.load(sessionID: session.id), Set(session.lorebookIDs)) }.value
            guard !Task.isCancelled else { return }
            if library == nil { selected = result.1 }
            library = result.0
        }
        .onReceive(NotificationCenter.default.publisher(for: WorldbookStore.didChangeNotification).receive(on: DispatchQueue.main)) { _ in refreshID = UUID() }
        .onReceive(NotificationCenter.default.publisher(for: RoleplayStore.didChangeNotification).receive(on: DispatchQueue.main)) { notification in
            if notification.userInfo?[RoleplayStore.changeKindUserInfoKey] as? String == RoleplayStore.libraryChangeKind { refreshID = UUID() }
        }
    }

    private var guideSettings: [GuidePageSetting] {
        var settings: [GuidePageSetting] = [
            .readOnly("session_id", label: NSLocalizedString("当前会话", comment: ""), value: { .string(session.id.uuidString) }),
            .readOnly("books", label: NSLocalizedString("世界书列表", comment: ""), value: { library?.guideValue ?? .array([]) }),
            .readOnly("requires_save", label: NSLocalizedString("修改后需要保存", comment: ""), value: { .bool(true) })
        ]
        if !isSaving, !workspace.isRestoringData, let library {
            settings.append(.json("selected_ids", label: NSLocalizedString("当前会话绑定的世界书", comment: ""), schema: library.selectionSchema,
                                  get: { .array(selected.map(\.uuidString).sorted().map(JSONValue.string)) },
                                  normalize: { .array(try library.selection(from: $0).map(\.uuidString).sorted().map(JSONValue.string)) },
                                  set: { selected = try library.selection(from: $0) }))
        }
        return settings
    }

    private func save() {
        isSaving = true
        Task {
            defer { isSaving = false }
            do { try await model.saveBindings(selected, replacing: session); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}
