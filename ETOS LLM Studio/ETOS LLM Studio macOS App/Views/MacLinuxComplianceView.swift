import ETOSCore
import SwiftUI

struct MacLinuxComplianceView: View {
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @StateObject private var model = MacLinuxComplianceModel()
    @State private var visible = false
    private var allowed: Bool { isActive && workspace.canManageLocalModels }
    private var active: Bool { visible && allowed }

    var body: some View {
        List {
            Section(NSLocalizedString("内置系统", comment: "")) {
                MacSettingsIntroCard(id: "linux-compliance", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac Linux 许可与源码使用说明", comment: ""), documentID: "macos-workspace", isActive: allowed)
                Text(model.content).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                Button(NSLocalizedString("刷新", comment: "")) { model.reload() }.disabled(model.isLoading)
            }
            Section {
                ForEach(model.rows) { row in
                    NavigationLink { MacLinuxComplianceDocumentView(document: row.document, isActive: allowed) }
                        label: { Label(row.title, systemImage: row.symbol) }
                }
            } header: { Text(NSLocalizedString("许可与源码", comment: "")) } footer: {
                Text(NSLocalizedString("这些文件与当前 App 内置的 RootFS 一起签名交付，可用于核对版本、许可证、来源与构建材料。", comment: "")).font(.footnote).foregroundStyle(.secondary)
            }
            if model.isLoading { ProgressView(NSLocalizedString("正在读取…", comment: "")) }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .navigationTitle(NSLocalizedString("许可与源码", comment: "")).disabled(!allowed)
        .onAppear { visible = true; if active { model.open() } }
        .onDisappear { visible = false; model.close(clearContent: false) }
        .onChange(of: active) { _, value in if value { model.open() } else { model.close(clearContent: visible) } }
        .onChange(of: configuration.appLanguage) { _, _ in model.reload() }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-linux-compliance-\(model.lease)"), title: NSLocalizedString("许可与源码", comment: ""),
            documents: [GuideDocumentReference(id: "local-linux", title: "Local Linux"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: active && !model.isLoading,
            settings: [
                .readOnly("bundled_seed", label: NSLocalizedString("内置系统", comment: ""), value: { .string(model.content) }),
                .readOnly("document_count", label: NSLocalizedString("许可与源码", comment: ""), value: { .int(model.rows.count) })
            ])
    }
}

private struct MacLinuxComplianceDocumentView: View {
    let document: LocalLinuxComplianceDocument
    let isActive: Bool
    @ObservedObject private var configuration = AppConfigStore.shared
    @StateObject private var model: MacLinuxComplianceModel
    @State private var visible = false
    init(document: LocalLinuxComplianceDocument, isActive: Bool) {
        self.document = document; self.isActive = isActive
        _model = StateObject(wrappedValue: MacLinuxComplianceModel(document: document))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {
                MacSettingsIntroCard(id: "linux-compliance-\(document.id)", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac Linux 许可与源码使用说明", comment: ""), documentID: "macos-workspace", isActive: isActive)
                if model.isLoading { ProgressView(NSLocalizedString("正在读取…", comment: "")) }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                Text(model.content).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.padding()
        }
        .navigationTitle(document.displayName).disabled(!isActive)
        .toolbar {
            Button(NSLocalizedString("刷新", comment: "")) { model.reload() }.disabled(!isActive || model.isLoading)
            if let url = model.resourceURL {
                ShareLink(item: url) { Label(NSLocalizedString("导出", comment: ""), systemImage: "square.and.arrow.up") }.disabled(!isActive || model.isLoading)
            }
        }
        .onAppear { visible = true; if isActive { model.open() } }
        .onDisappear { visible = false; model.close(clearContent: false) }
        .onChange(of: isActive) { _, value in if value && visible { model.open() } else if !value { model.close() } }
        .onChange(of: configuration.appLanguage) { _, _ in model.reload() }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-linux-compliance-document-\(document.id)-\(model.lease)"), title: document.displayName,
            documents: [GuideDocumentReference(id: "local-linux", title: "Local Linux"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: visible && isActive && !model.isLoading,
            settings: [
                .readOnly("document", label: NSLocalizedString("许可与源码", comment: ""), value: { .string(document.id) }),
                .readOnly("available", label: NSLocalizedString("导出", comment: ""), value: { .bool(model.resourceURL != nil) }),
                .readOnly("read_only", label: NSLocalizedString("使用说明", comment: ""), value: { .bool(true) })
            ])
    }
}
