import ETOSCore
import SwiftUI
import UniformTypeIdentifiers

struct MacLocalModelLibraryView: View {
    let isActive: Bool
    @ObservedObject var library: MacLocalModelLibraryModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var editor: MacLocalModelEditorSource?
    @State private var importing = false
    @State private var downloading = false
    @State private var importEpoch = UUID()
    @State private var preparation: Task<Void, Never>?
    @State private var pageEpoch = UUID()
    @State private var importPageEpoch = UUID()
    @State private var pageIsVisible = false

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "local-models", title: NSLocalizedString("使用说明", comment: ""),
                                     details: NSLocalizedString("Mac 本地模型管理使用说明", comment: ""), documentID: "local-models")
                Toggle(NSLocalizedString("启用本地模型提供商", comment: ""), isOn: setting(.localModelsEnabled, value: configuration.localModelsEnabled))
            } footer: {
                Text(NSLocalizedString("关闭后不会删除权重；重新开启时会自动把“本地模型”提供商加回模型管理。", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Toggle(NSLocalizedString("性能监视面板", comment: ""), isOn: setting(.localModelPerformanceMonitorEnabled, value: configuration.localModelPerformanceMonitorEnabled))
                Toggle(NSLocalizedString("模型缓存", comment: ""), isOn: setting(.localModelCacheEnabled, value: configuration.localModelCacheEnabled))
                Toggle(NSLocalizedString("对话 KV 缓存", comment: ""), isOn: setting(.localModelKVCacheEnabled, value: configuration.localModelKVCacheEnabled))
            } footer: {
                Text(NSLocalizedString("减少重复加载；关闭后释放缓存。", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button {
                    importEpoch = library.epoch; importPageEpoch = pageEpoch; importing = true
                } label: {
                    Label(NSLocalizedString("导入 GGUF 权重", comment: ""), systemImage: "square.and.arrow.down")
                }
                Button { downloading = true } label: {
                    Label(NSLocalizedString("下载权重", comment: ""), systemImage: "arrow.down.circle")
                }
                if library.isWorking { ProgressView(NSLocalizedString("处理中", comment: "")) }
            } footer: {
                Text(NSLocalizedString("可一次选择模型权重和对应的 mmproj 投影器；导入后的文件只保存在本机。", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                if !library.isLoaded { ProgressView() }
                else if library.rows.isEmpty {
                    Text(NSLocalizedString("还没有本地模型。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(library.rows) { row in
                    Button {
                        preparation?.cancel()
                        preparation = Task {
                            let source = await library.editorSource(for: row)
                            if !Task.isCancelled { editor = source }
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            Label(row.title, systemImage: row.record.isActivated ? "checkmark.circle" : "circle")
                            Text(row.record.fileName).font(.caption).foregroundStyle(.secondary)
                            Text(row.size).font(.caption).foregroundStyle(.secondary)
                            if !row.fileExists {
                                Text(NSLocalizedString("文件缺失", comment: "")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.buttonStyle(.plain)
                }
            } header: { Text(NSLocalizedString("本地模型", comment: "")) }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("本地模型", comment: ""))
        .disabled(!library.canWrite || !workspace.canManageLocalModels)
        .task { await library.start() }
        .onAppear { pageIsVisible = true }
        .onChange(of: configuration.appLanguage) { _, _ in library.refresh() }
        .onChange(of: library.epoch) { _, _ in editor = nil; importing = false; downloading = false }
        .onChange(of: isActive) { _, active in
            if !active { pageEpoch = UUID(); preparation?.cancel(); editor = nil; importing = false; downloading = false }
        }
        .onDisappear { pageIsVisible = false; pageEpoch = UUID(); preparation?.cancel() }
        .sheet(item: $editor) { source in MacLocalModelEditor(source: source, library: library) }
        .sheet(isPresented: $downloading) {
            MacLocalModelDownloadView(library: library, isActive: isActive && pageIsVisible && workspace.canManageLocalModels)
                .environment(\.isEnabled, workspace.canManageLocalModels)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data], allowsMultipleSelection: true) { result in
            guard isActive, pageIsVisible, importPageEpoch == pageEpoch, importEpoch == library.epoch, workspace.canManageLocalModels else { return }
            switch result {
            case .success(let urls):
                let page = pageEpoch, token = importEpoch
                Task {
                    guard pageIsVisible, page == pageEpoch else { return }
                    _ = await library.importFiles(urls, expectedEpoch: token)
                }
            case .failure(let error): library.error = error.localizedDescription
            }
        }
        .alert(NSLocalizedString("本地模型", comment: ""), isPresented: Binding(
            get: { editor == nil && !downloading && library.error != nil }, set: { if !$0 { library.error = nil } }
        )) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) { library.error = nil }
        } message: { Text(library.error ?? "") }
        .guideSettingsPageContext(
            id: "mac-local-models", title: NSLocalizedString("本地模型", comment: ""),
            documents: [GuideDocumentReference(id: "local-models", title: "Local Models")],
            isActive: isActive && pageIsVisible && editor == nil && !importing && !downloading && workspace.canManageLocalModels,
            settings: guideSettings
        )
    }

    private func setting(_ key: AppConfigKey, value: Bool) -> Binding<Bool> {
        Binding(get: { value }, set: { library.updateSetting(key, enabled: $0, service: workspace.service) })
    }

    private var guideSettings: [GuidePageSetting] {
        var fields: [GuidePageSetting] = [
            .readOnly("models", label: NSLocalizedString("本地模型", comment: ""), value: { library.guideRows }),
            .readOnly("working", label: NSLocalizedString("处理中", comment: ""), value: { .bool(library.isWorking) }),
            .readOnly("requires_save", label: NSLocalizedString("保存", comment: ""), value: { .bool(false) })
        ]
        if library.canWrite {
            fields += [
                .bool("enabled", label: NSLocalizedString("启用本地模型提供商", comment: ""), get: { configuration.localModelsEnabled }, set: { library.updateSetting(.localModelsEnabled, enabled: $0, service: workspace.service) }),
                .bool("performance_monitor_enabled", label: NSLocalizedString("性能监视面板", comment: ""), get: { configuration.localModelPerformanceMonitorEnabled }, set: { library.updateSetting(.localModelPerformanceMonitorEnabled, enabled: $0, service: workspace.service) }),
                .bool("model_cache_enabled", label: NSLocalizedString("模型缓存", comment: ""), get: { configuration.localModelCacheEnabled }, set: { library.updateSetting(.localModelCacheEnabled, enabled: $0, service: workspace.service) }),
                .bool("kv_cache_enabled", label: NSLocalizedString("对话 KV 缓存", comment: ""), get: { configuration.localModelKVCacheEnabled }, set: { library.updateSetting(.localModelKVCacheEnabled, enabled: $0, service: workspace.service) })
            ]
        }
        return fields
    }
}
