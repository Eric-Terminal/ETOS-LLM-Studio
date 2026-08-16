// ============================================================================
// ExternalStorageMountViews.swift
// ============================================================================
// 存储管理与本地 Linux 共用外部目录授权；文件浏览期间持续持有安全作用域。
// ============================================================================

import ETOSCore
import SwiftUI
import UniformTypeIdentifiers

struct ExternalStorageMountSection: View {
    @State private var mounts: [LocalLinuxMountRecord] = []
    @State private var requestedAccess = LocalLinuxMountAccess.readWrite
    @State private var isImporterPresented = false
    @State private var isPreparingMount = false
    @State private var pendingRemoval: LocalLinuxMountRecord?
    @State private var errorMessage: String?

    var body: some View {
        Section {
            if mounts.isEmpty {
                Text(NSLocalizedString("还没有外部挂载。", comment: "No external storage mounts"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(mounts) { mount in
                NavigationLink {
                    ExternalStorageDirectoryView(record: mount) { updated in
                        replaceRecord(updated)
                    }
                } label: {
                    ExternalStorageMountRow(record: mount)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingRemoval = mount
                    } label: {
                        Label(NSLocalizedString("移除挂载", comment: "Remove external storage mount"), systemImage: "eject")
                    }
                }
            }

            Menu {
                Button {
                    presentImporter(access: .readOnly)
                } label: {
                    Label(NSLocalizedString("只读", comment: "Read-only external storage mount"), systemImage: "lock")
                }
                Button {
                    presentImporter(access: .readWrite)
                } label: {
                    Label(NSLocalizedString("读写", comment: "Read-write external storage mount"), systemImage: "pencil")
                }
            } label: {
                Label(NSLocalizedString("选择外部文件夹…", comment: "Add external storage folder"), systemImage: "folder.badge.plus")
            }
            .disabled(isPreparingMount)

            if isPreparingMount {
                HStack {
                    ProgressView()
                    Text(NSLocalizedString("正在准备文件", comment: "Preparing external storage mount"))
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(NSLocalizedString("外部文件夹", comment: "External storage folders section"))
        } footer: {
            Text(NSLocalizedString("挂载记录与本地 Linux 共用；AI 无需启动 Linux 即可通过 app://ETOSMounts/<挂载 ID> 访问。选择只读时，存储管理、AI 文件工具和 Linux 都不会提供删除或写入操作。", comment: "External storage mounts footer"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task {
            await reload()
        }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.folder]) { result in
            do {
                let url = try result.get()
                addMount(url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog(
            NSLocalizedString("移除此挂载？", comment: "Remove external storage mount confirmation"),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("移除挂载", comment: "Confirm removing external storage mount"), role: .destructive) {
                removePendingMount()
            }
            Button(NSLocalizedString("取消", comment: "Cancel removing external storage mount"), role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            Text(NSLocalizedString("移除只会撤销 ETOS 对此文件夹的入口，不会删除文件夹中的内容。正在使用它的 Linux 任务需要先停止。", comment: "External storage mount removal explanation"))
        }
        .alert(
            NSLocalizedString("挂载失败", comment: "External storage mount error title"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(NSLocalizedString("好", comment: "Dismiss external storage mount error"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func presentImporter(access: LocalLinuxMountAccess) {
        requestedAccess = access
        isImporterPresented = true
    }

    private func addMount(_ url: URL) {
        Task {
            isPreparingMount = true
            defer { isPreparingMount = false }
            do {
                _ = try await LocalLinuxMountManager.shared.addExternalDirectory(
                    url,
                    displayName: url.lastPathComponent,
                    access: requestedAccess
                )
                await reload()
            } catch {
                await reload()
                errorMessage = error.localizedDescription
            }
        }
    }

    private func removePendingMount() {
        guard let mount = pendingRemoval else { return }
        pendingRemoval = nil
        Task {
            do {
                try await LocalLinuxMountManager.shared.delete(id: mount.id, force: false)
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func replaceRecord(_ record: LocalLinuxMountRecord) {
        guard let index = mounts.firstIndex(where: { $0.id == record.id }) else { return }
        mounts[index] = record
    }

    private func reload() async {
        mounts = await LocalLinuxMountManager.shared.records()
    }
}

private struct ExternalStorageMountRow: View {
    let record: LocalLinuxMountRecord

    var body: some View {
        HStack {
            Image(systemName: "externaldrive.connected.to.line.below")
                .foregroundStyle(.blue)

            VStack(alignment: .leading) {
                Text(record.displayName)
                Text("\(record.access.displayName) · \(record.authorizationState.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(LocalLinuxMountManager.appMountURI(id: record.id))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct ExternalStorageDirectoryView: View {
    @State private var record: LocalLinuxMountRecord
    @State private var directoryAccess: LocalLinuxDirectoryAccess?
    @State private var isLoading = true
    @State private var isImporterPresented = false
    @State private var errorMessage: String?

    private let onRecordChange: (LocalLinuxMountRecord) -> Void

    init(
        record: LocalLinuxMountRecord,
        onRecordChange: @escaping (LocalLinuxMountRecord) -> Void
    ) {
        _record = State(initialValue: record)
        self.onRecordChange = onRecordChange
    }

    var body: some View {
        Group {
            if let directoryAccess {
                StorageDirectoryBrowserView(
                    title: record.displayName,
                    rootDirectory: directoryAccess.url,
                    currentDirectory: directoryAccess.url,
                    emptyTitle: NSLocalizedString("空文件夹", comment: "Empty external storage folder title"),
                    emptyDescription: NSLocalizedString("这个文件夹里还没有内容。", comment: "Empty external storage folder description"),
                    footerText: browserFooter,
                    allowsDeletion: record.access == .readWrite
                )
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(NSLocalizedString("打开文件夹失败", comment: "Open external storage folder failure"), systemImage: "folder.badge.questionmark")
                } description: {
                    Text(errorMessage ?? "")
                } actions: {
                    Button(NSLocalizedString("重新选择目录…", comment: "Reauthorize external storage folder")) {
                        isImporterPresented = true
                    }
                }
            }
        }
        .navigationTitle(record.displayName)
        .task {
            await loadDirectory()
        }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.folder]) { result in
            do {
                let url = try result.get()
                reauthorize(with: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var browserFooter: String {
        switch record.access {
        case .readOnly:
            return NSLocalizedString("此文件夹以只读方式挂载；可以浏览和预览内容，不能从这里删除文件。", comment: "Read-only external storage browser footer")
        case .readWrite:
            return NSLocalizedString("此文件夹同时用于存储管理和本地 Linux；删除操作会直接修改原文件。", comment: "Read-write external storage browser footer")
        }
    }

    private func loadDirectory() async {
        isLoading = true
        directoryAccess = nil
        do {
            directoryAccess = try await LocalLinuxMountManager.shared.accessExternalDirectory(id: record.id)
            errorMessage = nil
            let records = await LocalLinuxMountManager.shared.records()
            if let updated = records.first(where: { $0.id == record.id }) {
                record = updated
                onRecordChange(updated)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func reauthorize(with url: URL) {
        Task {
            isLoading = true
            directoryAccess = nil
            do {
                let updated = try await LocalLinuxMountManager.shared.reauthorize(
                    id: record.id,
                    with: url,
                    access: record.access
                )
                record = updated
                onRecordChange(updated)
                await loadDirectory()
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}
