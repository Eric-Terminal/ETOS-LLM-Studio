import ETOSCore
import SwiftUI
import UniformTypeIdentifiers

struct MacLinuxMountsView: View {
    let isActive: Bool
    @ObservedObject var runtime: MacLinuxModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @StateObject private var model = MacLinuxStorageModel()
    @State private var visible = false
    @State private var choosingDirectory = false
    @State private var selection: MacLinuxMountSelection?
    private var allowed: Bool { isActive && workspace.canManageLocalModels && !runtime.isSuspended }
    private var active: Bool { visible && allowed }

    var body: some View {
        List {
            Section {
                MacSettingsIntroCard(id: "linux-mounts", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac Linux 挂载使用说明", comment: ""), documentID: "macos-workspace", isActive: allowed && !choosingDirectory)
                NavigationLink {
                    MacLinuxWorkspacesView(isActive: isActive, runtime: runtime)
                } label: { Label(NSLocalizedString("管理工作区", comment: ""), systemImage: "folder") }
            }
            Section {
                Picker(NSLocalizedString("新挂载权限", comment: ""), selection: $configuration.localLinuxDefaultMountAccess) {
                    ForEach(LocalLinuxMountAccess.allCases, id: \.self) { access in Text(access.displayName).tag(access) }
                }
                Button(NSLocalizedString("选择外部文件夹…", comment: "")) {
                    selection = MacLinuxMountSelection(lease: model.lease, access: configuration.localLinuxDefaultMountAccess)
                    choosingDirectory = true
                }.disabled(model.isWorking)
                Button(NSLocalizedString("刷新", comment: "")) { model.error = nil; model.reload() }.disabled(model.isLoading || model.isWorking)
            } footer: { Text(NSLocalizedString("只读可保护原文件；读写操作会直接修改原文件。", comment: "")).font(.footnote).foregroundStyle(.secondary) }
            Section(NSLocalizedString("外部挂载", comment: "")) {
                if let catalog = model.catalog {
                    if catalog.mounts.isEmpty { Text(NSLocalizedString("还没有外部挂载。", comment: "")).font(.footnote).foregroundStyle(.secondary) }
                    ForEach(catalog.mounts) { row in
                        NavigationLink {
                            MacLinuxMountDetailView(record: row.record, isActive: isActive, runtime: runtime)
                        } label: {
                            VStack(alignment: .leading) {
                                HStack {
                                    Text(row.record.displayName)
                                    if !row.record.isEnabled { Text(NSLocalizedString("已停用", comment: "")).font(.caption).foregroundStyle(.secondary) }
                                }
                                Text(row.record.guestPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(row.access).font(.caption).foregroundStyle(.secondary)
                                Text(row.authorization).font(.caption).foregroundStyle(.secondary)
                                if row.record.activeLeaseCount > 0 { Text(row.usage).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            if model.isWorking || model.isLoading { ProgressView(NSLocalizedString("处理中", comment: "")) }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .navigationTitle(NSLocalizedString("工作区与挂载", comment: "")).disabled(!allowed)
        .onAppear { visible = true; if active { model.open() } }
        .onDisappear { visible = false; close(clearContent: false) }
        .onChange(of: active) { _, value in if value { model.open() } else { close(clearContent: visible) } }
        .onChange(of: runtime.epoch) { _, _ in close(); if active { model.open() } }
        .onChange(of: configuration.appLanguage) { _, _ in model.reload() }
        .fileImporter(isPresented: $choosingDirectory, allowedContentTypes: [.folder]) { result in
            guard active, let target = selection else { return }
            selection = nil
            do {
                let url = try result.get()
                Task {
                    _ = try? await model.perform(expectedLease: target.lease, revision: target.revision) { services in
                        try await services.mounts.addExternalDirectory(url, displayName: url.lastPathComponent, access: target.access)
                    }
                }
            } catch { if model.lease == target.lease { model.error = error.localizedDescription } }
        }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-linux-mounts-\(model.lease)-\(runtime.epoch)"), title: NSLocalizedString("工作区与挂载", comment: ""),
            documents: [GuideDocumentReference(id: "local-linux", title: "Local Linux"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: active && !choosingDirectory && !model.isWorking,
            settings: [
                .string("default_mount_access", label: NSLocalizedString("新挂载权限", comment: ""), allowedValues: ["read_only", "read_write"],
                    get: { configuration.localLinuxDefaultMountAccess.rawValue }, set: { if let value = LocalLinuxMountAccess(rawValue: $0) { configuration.localLinuxDefaultMountAccess = value } }),
                .readOnly("mounts", label: NSLocalizedString("外部挂载", comment: ""), value: { model.catalog?.guideMounts ?? .array([]) }),
                .readOnly("directory_selection_required", label: NSLocalizedString("选择外部文件夹…", comment: ""), value: { .bool(true) })
            ])
    }

    private func close(clearContent: Bool = true) { choosingDirectory = false; selection = nil; model.close(clearContent: clearContent) }
}

struct MacLinuxMountSelection: Sendable {
    let lease: UUID
    let access: LocalLinuxMountAccess
    let revision = LocalLinuxActivityBarrier.shared.revision
}
