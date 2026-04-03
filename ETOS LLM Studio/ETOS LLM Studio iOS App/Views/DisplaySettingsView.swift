// ============================================================================
// DisplaySettingsView.swift
// ============================================================================
// DisplaySettingsView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Foundation
import Shared
import UniformTypeIdentifiers

struct DisplaySettingsView: View {
    @Binding var enableMarkdown: Bool
    @Binding var enableBackground: Bool
    @Binding var backgroundBlur: Double
    @Binding var backgroundOpacity: Double
    @Binding var enableAutoRotateBackground: Bool
    @Binding var currentBackgroundImage: String
    @Binding var backgroundContentMode: String
    @Binding var enableLiquidGlass: Bool
    @Binding var enableAdvancedRenderer: Bool
    @Binding var enableExperimentalToolResultDisplay: Bool
    @Binding var enableAutoReasoningPreview: Bool
    
    let allBackgrounds: [String]
    
    var body: some View {
        Form {
            Section("内容表现") {
                Toggle("渲染 Markdown", isOn: $enableMarkdown)
                if enableMarkdown {
                    Toggle("使用高级渲染器", isOn: $enableAdvancedRenderer)
                    Text("启用后可使用更强的 Markdown/LaTeX 渲染能力。")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
                Toggle("增强工具结果显示（实验性）", isOn: $enableExperimentalToolResultDisplay)
                Text("启用后会优先提取工具结果正文并折叠原始 JSON；关闭后恢复为原始结果文本展示。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("自动预览思考过程", isOn: $enableAutoReasoningPreview)
                Text("开启后，AI 回复仅有思考内容时会自动展开；一旦出现正文会自动收起。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                NavigationLink {
                    FontSettingsView()
                } label: {
                    Label("字体设置", systemImage: "textformat.alt")
                }
                if #available(iOS 26.0, *) {
                    Toggle("液态玻璃效果", isOn: $enableLiquidGlass)
                }
            }
            
            Section("背景") {
                Toggle("显示背景", isOn: $enableBackground)
                
                if enableBackground {
                    Picker("填充模式", selection: $backgroundContentMode) {
                        Text("填充 (居中裁剪)").tag("fill")
                        Text("适应 (完整显示)").tag("fit")
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: NSLocalizedString("模糊 %.1f", comment: ""), backgroundBlur))
                        Slider(value: $backgroundBlur, in: 0...25, step: 0.5)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: NSLocalizedString("不透明度 %.2f", comment: ""), backgroundOpacity))
                        Slider(value: $backgroundOpacity, in: 0.1...1.0, step: 0.05)
                    }
                    
                    Toggle("自动轮换背景", isOn: $enableAutoRotateBackground)
                    
                    NavigationLink {
                        BackgroundPickerView(allBackgrounds: allBackgrounds, selectedBackground: $currentBackgroundImage)
                    } label: {
                        Label("选择背景图", systemImage: "photo.on.rectangle")
                    }
                }
            }
        }
        .navigationTitle("显示设置")
        .onChange(of: enableMarkdown) { _, isEnabled in
            if !isEnabled, enableAdvancedRenderer {
                enableAdvancedRenderer = false
            }
        }
    }
}

private struct FontSettingsView: View {
    @State private var assets: [FontAssetRecord] = []
    @State private var routes: FontRouteConfiguration = .init()
    @State private var selectedRole: FontSemanticRole = .body
    @State private var showImporter = false
    @State private var importErrorMessage: String?
    @State private var deleteErrorMessage: String?

    var body: some View {
        Form {
            Section("字体文件") {
                Button {
                    showImporter = true
                } label: {
                    Label("上传字体文件", systemImage: "square.and.arrow.down")
                }
                if assets.isEmpty {
                    Text("还没有导入字体。支持 TTF / OTF / TTC。")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(assets) { asset in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(asset.displayName)
                                Text(asset.postScriptName)
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("启用", isOn: enabledBinding(for: asset))
                                .labelsHidden()
                        }
                    }
                    .onDelete(perform: deleteAssets)
                }
            }

            Section("样式优先级") {
                Picker("样式槽位", selection: $selectedRole) {
                    ForEach(FontSemanticRole.allCases) { role in
                        Text(role.title).tag(role)
                    }
                }
                if chainRecords.isEmpty {
                    Text("当前槽位没有可用字体，将使用系统默认字体。")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(chainRecords) { asset in
                        HStack {
                            Text(asset.displayName)
                                .foregroundStyle(asset.isEnabled ? .primary : .secondary)
                            Spacer()
                            HStack(spacing: 6) {
                                if !asset.isEnabled {
                                    Text("已停用")
                                        .etFont(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Text(asset.postScriptName)
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onMove(perform: movePriority)
                }
            }

            Section("预览") {
                Text("The quick brown fox jumps over the lazy dog.")
                    .etFont(FontRoutePreview.etFont(for: .body, sample: "The quick brown fox"))
                Text("中文：风来疏竹，风过而竹不留声。")
                    .etFont(FontRoutePreview.etFont(for: .body, sample: "风来疏竹，风过而竹不留声。"))
                Text("斜体预览 / Emphasis")
                    .etFont(FontRoutePreview.etFont(for: .emphasis, sample: "斜体预览 Emphasis"))
                    .italic()
                Text("粗体预览 / Strong")
                    .etFont(FontRoutePreview.etFont(for: .strong, sample: "粗体预览 Strong"))
                    .fontWeight(.bold)
                Text("let message = \"Code Preview\"")
                    .etFont(FontRoutePreview.etFont(for: .code, sample: "let message = \"Code Preview\""))
            }
        }
        .navigationTitle("字体设置")
        .toolbar {
            EditButton()
        }
        .onAppear {
            reloadData()
            FontLibrary.registerAllFontsIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncFontsUpdated)) { _ in
            reloadData()
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: supportedFontTypes,
            allowsMultipleSelection: true
        ) { result in
            handleImportResult(result)
        }
        .alert("导入失败", isPresented: Binding(
            get: { importErrorMessage != nil },
            set: { if !$0 { importErrorMessage = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "未知错误")
        }
        .alert("删除失败", isPresented: Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "未知错误")
        }
    }

    private var chainRecords: [FontAssetRecord] {
        let map = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        return routes.chain(for: selectedRole).compactMap { map[$0] }
    }

    private var supportedFontTypes: [UTType] {
        ["ttf", "otf", "ttc"].compactMap { UTType(filenameExtension: $0) }
    }

    private func reloadData() {
        assets = FontLibrary.loadAssets()
        routes = FontLibrary.loadRouteConfiguration()
    }

    private func enabledBinding(for asset: FontAssetRecord) -> Binding<Bool> {
        Binding(
            get: {
                assets.first(where: { $0.id == asset.id })?.isEnabled ?? asset.isEnabled
            },
            set: { newValue in
                updateAssetEnabled(assetID: asset.id, isEnabled: newValue)
            }
        )
    }

    private func movePriority(from source: IndexSet, to destination: Int) {
        var chain = routes.chain(for: selectedRole)
        chain.move(fromOffsets: source, toOffset: destination)
        routes.setChain(chain, for: selectedRole)
        FontLibrary.updateChain(chain, for: selectedRole)
        NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
    }

    private func deleteAssets(at offsets: IndexSet) {
        for index in offsets {
            let target = assets[index]
            do {
                try FontLibrary.deleteFontAsset(id: target.id)
            } catch {
                deleteErrorMessage = error.localizedDescription
            }
        }
        reloadData()
        NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
    }

    private func updateAssetEnabled(assetID: UUID, isEnabled: Bool) {
        guard FontLibrary.setAssetEnabled(id: assetID, isEnabled: isEnabled) else { return }
        reloadData()
        NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importErrorMessage = error.localizedDescription
        case .success(let urls):
            importFonts(from: urls)
        }
    }

    private func importFonts(from urls: [URL]) {
        var firstError: String?
        for url in urls {
            let started = url.startAccessingSecurityScopedResource()
            defer {
                if started {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let data = try Data(contentsOf: url)
                _ = try FontLibrary.importFont(data: data, fileName: url.lastPathComponent)
            } catch {
                if firstError == nil {
                    firstError = error.localizedDescription
                }
            }
        }
        FontLibrary.registerAllFontsIfNeeded()
        reloadData()
        NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
        importErrorMessage = firstError
    }
}

private enum FontRoutePreview {
    static func etFont(for role: FontSemanticRole, sample: String, size: CGFloat = 17) -> Font {
        if let postScriptName = FontLibrary.resolvePostScriptName(for: role, sampleText: sample) {
            return .custom(postScriptName, size: size)
        }
        return .system(size: size)
    }
}
