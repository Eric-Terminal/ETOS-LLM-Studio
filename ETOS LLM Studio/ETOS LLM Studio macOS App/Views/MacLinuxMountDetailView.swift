import ETOSCore
import SwiftUI
import UniformTypeIdentifiers

struct MacLinuxMountDetailView: View {
    let mountID: UUID
    let isActive: Bool
    @ObservedObject var runtime: MacLinuxModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var configuration = AppConfigStore.shared
    @StateObject private var model = MacLinuxStorageModel()
    @State private var original: LocalLinuxMountRecord?
    @State private var requestedEnabled: Bool
    @State private var requestedAccess: LocalLinuxMountAccess
    @State private var visible = false
    @State private var choosingDirectory = false
    @State private var selection: MacLinuxMountSelection?
    @State private var removing: MacLinuxMountRemoval?
    private var allowed: Bool { isActive && workspace.canManageLocalModels && !runtime.isSuspended }
    private var active: Bool { visible && allowed }

    init(record: LocalLinuxMountRecord, isActive: Bool, runtime: MacLinuxModel) {
        mountID = record.id; self.isActive = isActive; self.runtime = runtime
        _original = State(initialValue: nil)
        _requestedEnabled = State(initialValue: record.isEnabled)
        _requestedAccess = State(initialValue: record.access)
    }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "linux-mount-detail", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac Linux 挂载使用说明", comment: ""), documentID: "macos-workspace",
                    isActive: allowed && !choosingDirectory && removing == nil)
                Button(NSLocalizedString("重新载入草稿", comment: "")) {
                    original = nil; model.error = nil
                    model.reload()
                }.disabled(model.isWorking || model.isLoading)
            }
            if let row = model.catalog?.mountByID[mountID] {
                Section(NSLocalizedString("挂载", comment: "")) {
                    LabeledContent(NSLocalizedString("目录", comment: ""), value: row.record.displayName)
                    LabeledContent(NSLocalizedString("Linux 路径", comment: ""), value: row.record.guestPath).textSelection(.enabled)
                    LabeledContent(NSLocalizedString("授权", comment: ""), value: row.authorization)
                    LabeledContent(NSLocalizedString("权限", comment: ""), value: row.access)
                    LabeledContent(NSLocalizedString("使用中", comment: ""), value: "\(row.record.activeLeaseCount)")
                }
                Section {
                    Toggle(NSLocalizedString("启用挂载", comment: ""), isOn: $requestedEnabled)
                    Button(NSLocalizedString("应用启用状态", comment: "")) { saveEnabled() }
                        .disabled(requestedEnabled == row.record.isEnabled)
                } footer: { Text(NSLocalizedString("Mac 挂载草稿说明", comment: "")).font(.footnote).foregroundStyle(.secondary) }
                Section {
                    Picker(NSLocalizedString("重新授权后的权限", comment: ""), selection: $requestedAccess) {
                        ForEach(LocalLinuxMountAccess.allCases, id: \.self) { access in Text(access.displayName).tag(access) }
                    }
                    Button(NSLocalizedString("重新选择目录并应用权限…", comment: "")) {
                        selection = MacLinuxMountSelection(lease: model.lease, access: requestedAccess)
                        choosingDirectory = true
                    }
                } footer: {
                    Text(NSLocalizedString("提升为读写需要再次通过系统文件选择器确认目录。活跃任务持有租约时，请先停止任务再普通卸载。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button(NSLocalizedString("移除挂载…", comment: ""), role: .destructive) {
                        removing = MacLinuxMountRemoval(record: row.record, lease: model.lease)
                    }
                }
            }
            if model.isWorking || model.isLoading { ProgressView(NSLocalizedString("处理中", comment: "")) }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .formStyle(.grouped).navigationTitle(NSLocalizedString("挂载", comment: "")).disabled(!allowed || model.isWorking)
        .onAppear { visible = true; if active { model.open() } }
        .onDisappear { visible = false; close(clearContent: false) }
        .onChange(of: active) { _, value in if value { model.open() } else { close(clearContent: visible) } }
        .onChange(of: runtime.epoch) { _, _ in close(); if active { model.open() } }
        .onChange(of: mountID) { _, _ in close(); if active { model.open() } }
        .onChange(of: model.version) { _, _ in
            if original == nil, let current = model.catalog?.mountByID[mountID]?.record { adopt(current) }
        }
        .onChange(of: configuration.appLanguage) { _, _ in model.reload() }
        .fileImporter(isPresented: $choosingDirectory, allowedContentTypes: [.folder]) { result in
            guard active, let target = selection, let expected = original else { return }
            selection = nil
            do {
                let url = try result.get()
                Task {
                    do {
                        let record = try await model.perform(expectedLease: target.lease, revision: target.revision) { services in
                            try await services.mounts.reauthorize(id: expected.id, with: url, access: target.access, expected: expected)
                        }
                        adopt(record)
                    } catch { }
                }
            } catch { if model.lease == target.lease { model.error = error.localizedDescription } }
        }
        .confirmationDialog(NSLocalizedString("移除此挂载？", comment: ""), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible, presenting: removing) { target in
            Button(NSLocalizedString("移除挂载", comment: ""), role: .destructive) { remove(target, force: false) }
            if target.record.activeLeaseCount > 0 {
                Button(NSLocalizedString("立即停止使用并移除", comment: ""), role: .destructive) { remove(target, force: true) }
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) { removing = nil }
        } message: { _ in Text(NSLocalizedString("移除只会撤销 Linux 的目录入口，不会删除外部文件。强制移除可能中断正在使用它的任务。", comment: "")) }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-linux-mount-\(mountID)-\(model.lease)-\(model.version)-\(runtime.epoch)"), title: NSLocalizedString("挂载", comment: ""),
            documents: [GuideDocumentReference(id: "local-linux", title: "Local Linux"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: active && original != nil && !model.isWorking && !choosingDirectory && removing == nil && model.catalog?.mountByID[mountID] != nil,
            settings: [
                .bool("enabled_draft", label: NSLocalizedString("启用挂载", comment: ""), get: { requestedEnabled }, set: { requestedEnabled = $0 }),
                .string("reauthorization_access_draft", label: NSLocalizedString("重新授权后的权限", comment: ""), allowedValues: ["read_only", "read_write"],
                    get: { requestedAccess.rawValue }, set: { if let value = LocalLinuxMountAccess(rawValue: $0) { requestedAccess = value } }),
                .readOnly("mount_id", label: NSLocalizedString("挂载", comment: ""), value: { .string(mountID.uuidString) }),
                .readOnly("saved_enabled", label: NSLocalizedString("启用", comment: ""), value: { .bool(model.catalog?.mountByID[mountID]?.record.isEnabled ?? false) }),
                .readOnly("saved_access", label: NSLocalizedString("权限", comment: ""), value: { .string(model.catalog?.mountByID[mountID]?.record.access.rawValue ?? "") }),
                .readOnly("authorization", label: NSLocalizedString("授权", comment: ""), value: { .string(model.catalog?.mountByID[mountID]?.record.authorizationState.rawValue ?? "") }),
                .readOnly("active_leases", label: NSLocalizedString("使用中", comment: ""), value: { .int(Int(clamping: model.catalog?.mountByID[mountID]?.record.activeLeaseCount ?? 0)) }),
                .readOnly("draft_only", label: NSLocalizedString("Mac 挂载草稿说明", comment: ""), value: { .bool(true) })
            ])
    }

    private func adopt(_ record: LocalLinuxMountRecord) { original = record; requestedEnabled = record.isEnabled; requestedAccess = record.access }
    private func close(clearContent: Bool = true) {
        choosingDirectory = false; selection = nil; removing = nil; model.close(clearContent: clearContent)
        if clearContent { original = nil; requestedEnabled = false; requestedAccess = .readOnly }
    }

    private func saveEnabled() {
        guard let expected = original else { return }
        let enabled = requestedEnabled, lease = model.lease, revision = LocalLinuxActivityBarrier.shared.revision
        Task {
            do {
                let record = try await model.perform(expectedLease: lease, revision: revision) { services in
                    try await services.mounts.setEnabled(enabled, id: expected.id, expected: expected)
                }
                original = record; requestedEnabled = record.isEnabled
            } catch { }
        }
    }

    private func remove(_ target: MacLinuxMountRemoval, force: Bool) {
        guard active else { return }
        Task {
            do {
                try await model.perform(expectedLease: target.lease, revision: target.revision) { services in
                    try await services.mounts.delete(id: target.record.id, force: force, expected: target.record)
                }
                dismiss()
            } catch { }
        }
    }
}

private struct MacLinuxMountRemoval: Identifiable, Sendable {
    let id = UUID()
    let record: LocalLinuxMountRecord
    let lease: UUID
    let revision = LocalLinuxActivityBarrier.shared.revision
}
