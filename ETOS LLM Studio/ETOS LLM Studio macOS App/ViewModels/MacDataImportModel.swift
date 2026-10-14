import AppKit
import Combine
import ETOSCore
import UniformTypeIdentifiers

struct MacDataImportConfirmation: Identifiable, Sendable {
    let id: UUID
    let source: String
    let scope: String
    let requiresCredentials: Bool
}

@MainActor
final class MacDataImportModel: ObservableObject {
    @Published private(set) var source: ThirdPartyImportSource = .etosBackup
    @Published private(set) var preview: MacDataImportPreview?
    @Published private(set) var selected: Set<MacDataImportCategory> = []
    @Published private(set) var report: MacDataImportReport?
    @Published private(set) var fileName = ""
    @Published private(set) var isPreparing = false
    @Published private(set) var isImporting = false
    @Published private(set) var isPanelOpen = false
    @Published private(set) var revision = UUID()
    @Published var credentialsAcknowledged = false
    @Published var confirmation: MacDataImportConfirmation?
    @Published var snapshotFile: MacSnapshotFile?
    @Published var error: String?
    private weak var workspace: MacWorkspaceModel?
    private var active = false
    private var panel: NSOpenPanel?
    private var preparation: Task<Void, Never>?
    private var prepared: ThirdPartyImportPreparedResult?

    var canEdit: Bool { active && workspace?.canManageLocalModels == true && !isPreparing && !isImporting && !isPanelOpen && snapshotFile == nil }
    var canImport: Bool {
        canEdit && preview != nil && (preview?.fixedScope?.isEmpty == false || !selected.isEmpty) && report == nil
    }
    var requiresCredentials: Bool { preview?.requiresCredentialAcknowledgement(selection: selected) == true }
    var canConfirm: Bool { canImport && (!requiresCredentials || credentialsAcknowledged) }

    func setActive(_ value: Bool, workspace: MacWorkspaceModel, discardPreview: Bool = false) {
        self.workspace = workspace
        guard active != value || discardPreview else { return }
        active = value
        revision = UUID()
        if !value {
            cancelPreparation()
            let oldPanel = panel; panel = nil; isPanelOpen = false; oldPanel?.cancel(nil)
            confirmation = nil; credentialsAcknowledged = false
            if discardPreview && !isImporting {
                clearPreparedState()
                if !workspace.isRestoringData || AppLockManager.shared.state == .locked { snapshotFile = nil }
            }
        }
    }

    func changeSource(_ value: ThirdPartyImportSource) {
        guard canEdit, source != value else { return }
        source = value
        clearPreparedState()
    }

    func setSelected(_ category: MacDataImportCategory, enabled: Bool) {
        guard canEdit, confirmation == nil, preview?.fixedScope == nil, preview?.availableScopes.contains(category) == true else { return }
        if enabled { selected.insert(category) } else { selected.remove(category) }
        credentialsAcknowledged = false
        revision = UUID()
    }

    func chooseFiles() {
        guard canEdit, confirmation == nil else { return }
        let panel = NSOpenPanel(), expected = revision
        panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = source == .openMinis
        panel.allowedContentTypes = source.suggestedFileExtensions.map { UTType(filenameExtension: $0) ?? .data } + [.folder]
        panel.title = NSLocalizedString("选择文件并解析", comment: "")
        self.panel = panel; isPanelOpen = true
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard let self, let panel, self.panel === panel else { return }
            self.panel = nil; isPanelOpen = false
            guard response == .OK, revision == expected, canEdit else { return }
            prepare(urls: panel.urls)
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private func prepare(urls: [URL]) {
        clearPreparedState()
        let expected = revision, source = source
        isPreparing = true
        preparation = Task { [weak self] in
            defer {
                if let self, revision == expected { isPreparing = false; preparation = nil }
            }
            guard let operations = self?.workspace?.dataImportOperations,
                  self?.workspace?.canManageLocalModels == true, !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let prepared = try ThirdPartyImportService.prepareImport(source: source, fileURLs: urls)
                try Task.checkCancellation()
                let conflicts: MacDataImportConflicts
                if source == .etosBackup { conflicts = .empty }
                else { conflicts = try MacDataImportConflicts.load(for: prepared.package) }
                let preview = MacDataImportPreview(prepared: prepared, conflicts: conflicts)
                let name = urls.map(\.lastPathComponent).joined(separator: NSLocalizedString("、", comment: ""))
                try Task.checkCancellation()
                return (prepared, preview, name)
            }
            let readID = operations.trackPreview(worker)
            defer { operations.finishPreview(readID) }
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, active, workspace?.canManageLocalModels == true, revision == expected,
                      !Task.isCancelled, !worker.isCancelled else { return }
                prepared = result.0; preview = result.1; fileName = result.2
                selected = result.1.availableScopes
                isPreparing = false; preparation = nil
                revision = UUID()
            } catch let request as SnapshotRestoreRequest {
                guard let self, active, workspace?.canManageLocalModels == true, revision == expected,
                      !Task.isCancelled, !worker.isCancelled else { return }
                // 请求对象负责临时目录，工作表和已确认的恢复同时持有它。
                snapshotFile = MacSnapshotFile(url: request.fileURL, restoreRequest: request)
                isPreparing = false; preparation = nil; revision = UUID()
            } catch {
                guard let self, revision == expected, !Task.isCancelled else { return }
                if !(error is CancellationError) { self.error = error.localizedDescription }
                isPreparing = false; preparation = nil; revision = UUID()
            }
        }
    }

    func cancelPreparation() {
        preparation?.cancel(); preparation = nil
        isPreparing = false; revision = UUID()
    }

    func requestConfirmation() {
        guard canImport, let preview else { return }
        credentialsAcknowledged = false
        confirmation = MacDataImportConfirmation(id: revision, source: source.displayName,
            scope: preview.fixedScope ?? preview.scopeRows.filter { selected.contains($0) }.map(\.title).joined(separator: NSLocalizedString("、", comment: "")),
            requiresCredentials: requiresCredentials)
    }

    func confirmImport(_ confirmation: MacDataImportConfirmation) {
        guard confirmation.id == revision, canConfirm, let prepared, let workspace else { return }
        let selection = selected
        isImporting = true; error = nil; self.confirmation = nil; revision = UUID()
        // 此任务只由原生确认创建；页面退出可停止预览，但不能截断已确认的数据合并。
        Task {
            do {
                let package = try await Task.detached(priority: .userInitiated) {
                    try MacDataImportPreview.scopedPackage(prepared, selection: selection)
                }.value
                if let summary = try await workspace.importData(.package(package)) {
                    report = await Task.detached(priority: .userInitiated) {
                        MacDataImportReport(summary: summary, options: package.options, warnings: prepared.warnings)
                    }.value
                    self.prepared = nil; preview = nil; selected = []
                }
            } catch { self.error = error.localizedDescription }
            credentialsAcknowledged = false; isImporting = false; revision = UUID()
        }
    }

    func languageChanged() {
        // 文件解析提示已本地化；语言切换后清掉旧文字和提案，重新选择文件才能产生新预览。
        if isImporting { preview = nil; report = nil; revision = UUID(); return }
        cancelPreparation(); clearPreparedState(); confirmation = nil
        let oldPanel = panel; panel = nil; isPanelOpen = false; oldPanel?.cancel(nil)
    }

    private func clearPreparedState() {
        prepared = nil; preview = nil; report = nil; selected = []
        fileName = ""; error = nil; credentialsAcknowledged = false; revision = UUID()
    }

    static func sourceHint(_ source: ThirdPartyImportSource) -> String {
        switch source {
        case .etosBackup: NSLocalizedString("支持导入 .elsbackup 快照或旧版 ETOS JSON 数据包。", comment: "")
        case .cherryStudio: NSLocalizedString("支持 Cherry Studio 的 .json 或解压后的备份目录；若是 .zip / .bak，请先解压后再导入。", comment: "")
        case .rikkahub: NSLocalizedString("支持 RikkaHub 的 settings.json（可直接选文件或解压目录，当前先导入提供商配置）。", comment: "")
        case .kelivo: NSLocalizedString("支持 Kelivo 的 settings.json + chats.json（建议选择解压后的目录一次导入）。", comment: "")
        case .chatgpt: NSLocalizedString("支持 ChatGPT 官方 conversations.json（可直接选文件或包含该文件的目录）。", comment: "")
        case .chatbox: NSLocalizedString("支持 ChatBox 导出的 chatbox-exported-data JSON，可导入提供商配置与会话记录。", comment: "")
        case .openMinis: NSLocalizedString("支持 OpenMinis iOS/Android 会话 JSON/ZIP、Provider JSON、MCP JSON 与 Skill ZIP；Skill 需勾选后导入，且不会执行脚本或安装依赖。", comment: "")
        }
    }
}
