// ============================================================================
// DisplaySettingsFontSupport.swift
// ============================================================================
// DisplaySettingsView 的字体设置支持视图
// - 负责字体导入、样式优先级、回退范围与预览
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore
import UniformTypeIdentifiers

struct FontSettingsView: View {
    @Environment(\.editMode) private var editMode
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var assets: [FontAssetRecord] = []
    @State private var routes: FontRouteConfiguration = .init()
    @State private var selectedRole: FontSemanticRole = .body
    @State private var isShowingIntroDetails = false
    @State private var showImporter = false
    @State private var importErrorMessage: String?
    @State private var deleteErrorMessage: String?

    private var isCustomFontEnabled: Bool {
        get { appConfig.fontUseCustomFonts }
        nonmutating set { appConfig.fontUseCustomFonts = newValue }
    }

    private var fallbackScopeRawValue: String {
        get { appConfig.fontFallbackScope }
        nonmutating set { appConfig.fontFallbackScope = newValue }
    }

    private var customFontScale: Double {
        get { appConfig.fontCustomScale }
        nonmutating set { appConfig.fontCustomScale = newValue }
    }

    var body: some View {
        Form {
            Section {
                settingsIntroCard(
                    title: NSLocalizedString("字体样式优先级", comment: "Font style priority intro title"),
                    summary: NSLocalizedString("管理每个样式槽位的字体候选链；越靠上优先级越高。", comment: "Font style priority intro summary"),
                    details: NSLocalizedString("字体样式优先级说明正文", comment: "Font style priority intro details"),
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section {
                Toggle(NSLocalizedString("启用自定义字体", comment: ""), isOn: customFontEnabledBinding)
            } footer: {
                Text(NSLocalizedString("关闭后全局回退为系统字体；已导入字体与优先级配置会保留。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            fontScaleSection
            fallbackScopeSection

            fontFilesSection
            stylePrioritySection
            previewSection
        }
        .navigationTitle(NSLocalizedString("字体设置", comment: ""))
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
        .onChange(of: isCustomFontEnabled) { _, isEnabled in
            if isEnabled {
                FontLibrary.registerAllFontsIfNeeded()
            }
            NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
        }
        .onChange(of: fallbackScopeRawValue) { _, _ in
            FontLibrary.preloadRuntimeCacheAsync(forceReload: true)
            NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
        }
        .onChange(of: customFontScale) { _, newValue in
            let normalizedValue = FontLibrary.normalizedFontScale(newValue)
            if normalizedValue != newValue {
                customFontScale = normalizedValue
                return
            }
            NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: supportedFontTypes,
            allowsMultipleSelection: true
        ) { result in
            handleImportResult(result)
        }
        .alert(NSLocalizedString("导入失败", comment: ""), isPresented: Binding(
            get: { importErrorMessage != nil },
            set: { if !$0 { importErrorMessage = nil } }
        )) {
            Button(NSLocalizedString("确定", comment: ""), role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? NSLocalizedString("未知错误", comment: ""))
        }
        .alert(NSLocalizedString("删除失败", comment: ""), isPresented: Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )) {
            Button(NSLocalizedString("确定", comment: ""), role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? NSLocalizedString("未知错误", comment: ""))
        }
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString(title, comment: "显示设置介绍卡片标题"))
                .etFont(.headline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(NSLocalizedString(summary, comment: "显示设置介绍卡片摘要"))
                .etFont(.subheadline)
                .foregroundStyle(.primary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: ""))
                    .etFont(.footnote.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .sheet(isPresented: isExpanded) {
            NavigationStack {
                ScrollView {
                    Text(NSLocalizedString(details, comment: "显示设置介绍卡片详情"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(NSLocalizedString(title, comment: "显示设置介绍卡片详情标题"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private var chainRecords: [FontAssetRecord] {
        let map = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        return routes.chain(for: selectedRole).compactMap { map[$0] }
    }

    private var availableAssetsForSelectedRole: [FontAssetRecord] {
        let selectedIDs = Set(routes.chain(for: selectedRole))
        return assets.filter { !selectedIDs.contains($0.id) }
    }

    private var isEditing: Bool {
        editMode?.wrappedValue.isEditing == true
    }

    private var customFontEnabledBinding: Binding<Bool> {
        Binding(
            get: { isCustomFontEnabled },
            set: { isCustomFontEnabled = $0 }
        )
    }

    private var fallbackScope: FontFallbackScope {
        FontFallbackScope(rawValue: fallbackScopeRawValue) ?? .segment
    }

    private var fallbackScopeBinding: Binding<FontFallbackScope> {
        Binding(
            get: { fallbackScope },
            set: { fallbackScopeRawValue = $0.rawValue }
        )
    }

    private var fontScaleBinding: Binding<Double> {
        Binding(
            get: { FontLibrary.normalizedFontScale(customFontScale) },
            set: { customFontScale = FontLibrary.normalizedFontScale($0) }
        )
    }

    private var allFallbackScopes: [FontFallbackScope] {
        FontFallbackScope.allCases
    }

    private var fontScaleSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(NSLocalizedString("字号比例", comment: ""))
                    Spacer(minLength: 8)
                    Text("\(Int((fontScaleBinding.wrappedValue * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: fontScaleBinding,
                    in: FontLibrary.minimumFontScale...FontLibrary.maximumFontScale,
                    step: FontLibrary.fontScaleStep
                )
            }
            Button(NSLocalizedString("恢复默认字号", comment: "")) {
                fontScaleBinding.wrappedValue = FontLibrary.defaultFontScale
            }
            .disabled(abs(fontScaleBinding.wrappedValue - FontLibrary.defaultFontScale) < 0.001)
        } header: {
            Text(NSLocalizedString("字体大小", comment: ""))
        } footer: {
            Text(NSLocalizedString("仅调整自定义字体的显示大小，范围为 50% 到 200%；系统动态字号仍会继续生效。", comment: ""))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var fallbackScopeSection: some View {
        Section {
            NavigationLink {
                FontFallbackScopeSelectionView(
                    allScopes: allFallbackScopes,
                    selectedScope: fallbackScopeBinding
                )
            } label: {
                HStack {
                    Text(NSLocalizedString("字体回退范围", comment: ""))
                    Text(fallbackScope.title)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        } header: {
            Text(NSLocalizedString("回退范围", comment: ""))
        } footer: {
            Text(fallbackScope.summary)
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var fontFilesSection: some View {
        Section(NSLocalizedString("字体文件", comment: "")) {
            Button {
                showImporter = true
            } label: {
                Label(NSLocalizedString("上传字体文件", comment: ""), systemImage: "square.and.arrow.down")
            }
            if assets.isEmpty {
                Text(NSLocalizedString("还没有导入字体。支持 TTF / OTF / TTC / WOFF / WOFF2。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(assets) { asset in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(asset.displayName)
                        Text(asset.postScriptName)
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete(perform: deleteAssets)
            }
        }
    }

    private var stylePrioritySection: some View {
        Section(
            header: Text(NSLocalizedString("样式优先级", comment: "")),
            footer: Text(NSLocalizedString("点击右上角“编辑”后，可拖拽右侧把手调整优先级，并通过“添加字体到当前槽位”补入未加入的字体。对槽位内字体右滑可移除。越靠上优先级越高。", comment: ""))
        ) {
            Picker(NSLocalizedString("样式槽位", comment: ""), selection: $selectedRole) {
                ForEach(FontSemanticRole.allCases) { role in
                    Text(role.title).tag(role)
                }
            }
            if chainRecords.isEmpty {
                Text(NSLocalizedString("当前槽位没有可用字体，将使用系统默认字体。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(chainRecords) { asset in
                    HStack {
                        Text(asset.displayName)
                            .foregroundStyle(.primary)
                        Spacer()
                        HStack(spacing: 6) {
                            Text(asset.postScriptName)
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            removeAssetFromSelectedRole(asset.id)
                        } label: {
                            Label(NSLocalizedString("移除", comment: ""), systemImage: "trash")
                        }
                    }
                }
                .onMove(perform: movePriority)
                .onDelete(perform: removeAssetsFromSelectedRole)
            }

            if isEditing {
                if availableAssetsForSelectedRole.isEmpty {
                    Text(NSLocalizedString("当前槽位没有可添加字体。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Menu {
                        ForEach(availableAssetsForSelectedRole) { asset in
                            Button {
                                addAssetToSelectedRole(asset.id)
                            } label: {
                                Text(asset.displayName)
                            }
                        }
                    } label: {
                        Label(NSLocalizedString("添加字体到当前槽位", comment: ""), systemImage: "plus.circle")
                    }
                }
            }
        }
    }

    private var previewSection: some View {
        Section(NSLocalizedString("预览", comment: "")) {
            Text(NSLocalizedString("The quick brown fox jumps over the lazy dog.", comment: "Font preview sample"))
                .font(FontRoutePreview.font(for: .body, sample: "The quick brown fox"))
            Text(NSLocalizedString("中文：风来疏竹，风过而竹不留声。", comment: ""))
                .font(FontRoutePreview.font(for: .body, sample: "风来疏竹，风过而竹不留声。"))
            Text(NSLocalizedString("斜体预览 / Emphasis", comment: ""))
                .font(FontRoutePreview.font(for: .emphasis, sample: "斜体预览 Emphasis"))
                .italic()
            Text(NSLocalizedString("粗体预览 / Strong", comment: ""))
                .font(FontRoutePreview.font(for: .strong, sample: "粗体预览 Strong"))
                .fontWeight(.bold)
            Text(NSLocalizedString("let message = \"Code Preview\"", comment: "Font preview code sample"))
                .font(FontRoutePreview.font(for: .code, sample: "let message = \"Code Preview\""))
        }
    }

    private var supportedFontTypes: [UTType] {
        let candidates: [UTType?] = [
            UTType(filenameExtension: "ttf"),
            UTType(filenameExtension: "otf"),
            UTType(filenameExtension: "ttc"),
            UTType(filenameExtension: "woff"),
            UTType(filenameExtension: "woff2"),
            UTType(mimeType: "font/woff"),
            UTType(mimeType: "font/woff2")
        ]

        var seen = Set<String>()
        return candidates
            .compactMap { $0 }
            .filter { seen.insert($0.identifier).inserted }
    }

    private func reloadData() {
        let loadedAssets = FontLibrary.loadAssets()
        if loadedAssets.contains(where: { !$0.isEnabled }) {
            let normalizedAssets = loadedAssets.map { asset in
                var mutable = asset
                mutable.isEnabled = true
                return mutable
            }
            _ = FontLibrary.saveAssets(normalizedAssets)
            assets = normalizedAssets
        } else {
            assets = loadedAssets
        }
        routes = FontLibrary.loadRouteConfiguration()
    }

    private func movePriority(from source: IndexSet, to destination: Int) {
        var chain = routes.chain(for: selectedRole)
        chain.move(fromOffsets: source, toOffset: destination)
        routes.setChain(chain, for: selectedRole)
        FontLibrary.updateChain(chain, for: selectedRole)
        NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
    }

    private func addAssetToSelectedRole(_ assetID: UUID) {
        var chain = routes.chain(for: selectedRole)
        guard !chain.contains(assetID) else { return }
        chain.append(assetID)
        routes.setChain(chain, for: selectedRole)
        FontLibrary.updateChain(chain, for: selectedRole)
        NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
    }

    private func removeAssetsFromSelectedRole(at offsets: IndexSet) {
        var chain = routes.chain(for: selectedRole)
        chain.remove(atOffsets: offsets)
        routes.setChain(chain, for: selectedRole)
        FontLibrary.updateChain(chain, for: selectedRole)
        NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
    }

    private func removeAssetFromSelectedRole(_ assetID: UUID) {
        var chain = routes.chain(for: selectedRole)
        guard chain.contains(assetID) else { return }
        chain.removeAll { $0 == assetID }
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

private struct FontFallbackScopeSelectionView: View {
    @Environment(\.dismiss) private var dismiss

    let allScopes: [FontFallbackScope]
    @Binding var selectedScope: FontFallbackScope

    var body: some View {
        List {
            ForEach(allScopes) { scope in
                Button {
                    selectedScope = scope
                    dismiss()
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(scope.title)
                                .foregroundStyle(.primary)
                            Text(scope.summary)
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer(minLength: 8)

                        if selectedScope == scope {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(NSLocalizedString("字体回退范围", comment: ""))
    }
}

private enum FontRoutePreview {
    static func font(for role: FontSemanticRole, sample: String, size: CGFloat = 17) -> Font {
        let scaledSize = size * CGFloat(FontLibrary.customFontScale)
        if let postScriptName = FontLibrary.resolvePostScriptName(for: role, sampleText: sample) {
            return .custom(postScriptName, size: scaledSize)
        }
        switch role {
        case .code:
            return .system(size: scaledSize, design: .monospaced)
        default:
            return .system(size: scaledSize)
        }
    }
}
