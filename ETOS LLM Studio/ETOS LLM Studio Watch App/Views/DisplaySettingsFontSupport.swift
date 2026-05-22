// ============================================================================
// DisplaySettingsFontSupport.swift
// ============================================================================
// ETOS LLM Studio Watch App 字体设置辅助视图
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct WatchFontSettingsView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var assets: [FontAssetRecord] = []
    @State private var routes: FontRouteConfiguration = .init()
    @State private var selectedRole: FontSemanticRole = .body
    @State private var isShowingIntroDetails = false
    @State private var showAddAssetDialog = false
    @State private var importURLText: String = ""
    @State private var isImportingFromURL: Bool = false
    @State private var importErrorMessage: String?

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
        List {
            Section {
                settingsIntroCard(
                    title: "字体样式优先级",
                    summary: "按槽位管理字体顺序，越靠上优先级越高。",
                    details: """
                    快速上手
                    1. 可在手表粘贴字体链接直接导入，或在 iPhone 端导入后同步到手表。
                    2. 选择样式槽位（正文 / 斜体 / 粗体 / 代码）。
                    3. 拖拽右侧把手调整顺序。
                    4. 点击“添加字体到当前槽位”补入缺失字体。
                    5. 对槽位内字体右滑可“移除”，仅移出当前槽位。

                    规则说明
                    • 每个槽位互相独立。
                    • 同一字体可加入多个槽位。
                    • 当前槽位无可用字体时自动回退系统字体。
                    """,
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section {
                Toggle(NSLocalizedString("启用自定义字体", comment: ""), isOn: customFontEnabledBinding)
            } footer: {
                Text(NSLocalizedString("关闭后会全局回退系统字体；已导入字体与优先级配置会保留。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            fontScaleSection

            Section(NSLocalizedString("回退范围", comment: "")) {
                Picker(NSLocalizedString("字体回退范围", comment: ""), selection: fallbackScopeBinding) {
                    ForEach(FontFallbackScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                Text(fallbackScope.summary)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("字体来源", comment: "")) {
                TextField(NSLocalizedString("字体文件链接", comment: ""), text: $importURLText.watchKeyboardNewlineBinding())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    importFontsFromURL()
                } label: {
                    Label(isImportingFromURL ? NSLocalizedString("正在下载并导入...", comment: "") : NSLocalizedString("从链接导入", comment: ""), systemImage: "link.badge.plus")
                }
                .disabled(isImportingFromURL || importURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if isImportingFromURL {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(NSLocalizedString("正在下载并导入...", comment: ""))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(NSLocalizedString("支持 http/https 的 TTF / OTF / TTC / WOFF / WOFF2 链接。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let importErrorMessage, !importErrorMessage.isEmpty {
                Section(NSLocalizedString("导入错误", comment: "")) {
                    Text(importErrorMessage)
                        .etFont(.caption2)
                        .foregroundStyle(.red)
                }
            }

            Section(NSLocalizedString("已导入字体", comment: "")) {
                if assets.isEmpty {
                    Text(NSLocalizedString("暂无字体，可在手表上通过链接导入，或在 iPhone 导入后同步。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(assets) { asset in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(asset.displayName)
                                .etFont(.footnote)
                            Text(asset.postScriptName)
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section(
                header: Text(NSLocalizedString("样式优先级", comment: "")),
                footer: Text(NSLocalizedString("拖拽右侧把手可调整顺序；可通过“添加字体到当前槽位”补入未加入的字体；对槽位内字体右滑可移除。越靠上优先级越高。", comment: ""))
            ) {
                Picker(NSLocalizedString("样式槽位", comment: ""), selection: $selectedRole) {
                    ForEach(FontSemanticRole.allCases) { role in
                        Text(role.title).tag(role)
                    }
                }
                if chainRecords.isEmpty {
                    Text(NSLocalizedString("当前槽位为空，使用系统字体。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(chainRecordsBinding, id: \.id, editActions: .move) { $asset in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(asset.displayName)
                                    .foregroundStyle(.primary)
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
                }

                if availableAssetsForSelectedRole.isEmpty {
                    Text(NSLocalizedString("当前槽位没有可添加字体。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        showAddAssetDialog = true
                    } label: {
                        Label(NSLocalizedString("添加字体到当前槽位", comment: ""), systemImage: "plus.circle")
                    }
                }
            }

            Section(NSLocalizedString("预览", comment: "")) {
                Text(NSLocalizedString("风来疏竹，风过而竹不留声。", comment: ""))
                    .font(FontRoutePreview.font(for: .body, sample: "风来疏竹，风过而竹不留声。", size: 14))
                Text("Emphasis")
                    .font(FontRoutePreview.font(for: .emphasis, sample: "Emphasis", size: 14))
                    .italic()
                Text("Strong")
                    .font(FontRoutePreview.font(for: .strong, sample: "Strong", size: 14))
                    .fontWeight(.bold)
                Text("let value = 42")
                    .font(FontRoutePreview.font(for: .code, sample: "let value = 42", size: 13))
            }
        }
        .navigationTitle(NSLocalizedString("字体设置", comment: ""))
        .onAppear {
            FontLibrary.registerAllFontsIfNeeded()
            reloadData()
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
        .confirmationDialog(NSLocalizedString("添加字体到当前槽位", comment: ""),
            isPresented: $showAddAssetDialog,
            titleVisibility: .visible
        ) {
            ForEach(availableAssetsForSelectedRole) { asset in
                Button(asset.displayName) {
                    addAssetToSelectedRole(asset.id)
                }
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
        }
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString(title, comment: "显示设置介绍卡片标题"))
                .etFont(.footnote.weight(.semibold))
            Text(NSLocalizedString(summary, comment: "显示设置介绍卡片摘要"))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: ""))
                    .etFont(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .sheet(isPresented: isExpanded) {
            ScrollView {
                Text(NSLocalizedString(details, comment: "显示设置介绍卡片详情"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

    private var chainRecords: [FontAssetRecord] {
        let map = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        return routes.chain(for: selectedRole).compactMap { map[$0] }
    }

    private var chainRecordsBinding: Binding<[FontAssetRecord]> {
        Binding(
            get: { chainRecords },
            set: { orderedRecords in
                updateSelectedRoleChain(orderedRecords.map(\.id))
            }
        )
    }

    private var availableAssetsForSelectedRole: [FontAssetRecord] {
        let selectedIDs = Set(routes.chain(for: selectedRole))
        return assets.filter { !selectedIDs.contains($0.id) }
    }

    private var customFontEnabledBinding: Binding<Bool> {
        Binding(
            get: { isCustomFontEnabled },
            set: { isCustomFontEnabled = $0 }
        )
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

    private var fontScaleSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
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
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func updateSelectedRoleChain(_ chain: [UUID]) {
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

    private func removeAssetFromSelectedRole(_ assetID: UUID) {
        var chain = routes.chain(for: selectedRole)
        guard chain.contains(assetID) else { return }
        chain.removeAll { $0 == assetID }
        routes.setChain(chain, for: selectedRole)
        FontLibrary.updateChain(chain, for: selectedRole)
        NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
    }

    private func importFontsFromURL() {
        let trimmed = importURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            importErrorMessage = NSLocalizedString("链接不能为空。", comment: "")
            return
        }
        guard let url = URL(string: trimmed) else {
            importErrorMessage = NSLocalizedString("链接格式无效，请输入完整 URL。", comment: "")
            return
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            importErrorMessage = NSLocalizedString("仅支持 http/https 链接。", comment: "")
            return
        }

        importErrorMessage = nil
        isImportingFromURL = true

        Task {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 45
                let (data, response) = try await NetworkSessionConfiguration.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    await MainActor.run {
                        importErrorMessage = String(format: NSLocalizedString("下载失败：HTTP %d", comment: ""), httpResponse.statusCode)
                        isImportingFromURL = false
                    }
                    return
                }

                let fileName = suggestedRemoteFontFileName(from: url, response: response, data: data)
                _ = try FontLibrary.importFont(data: data, fileName: fileName)

                await MainActor.run {
                    FontLibrary.registerAllFontsIfNeeded()
                    reloadData()
                    NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
                    importURLText = ""
                    importErrorMessage = nil
                    isImportingFromURL = false
                }
            } catch {
                await MainActor.run {
                    importErrorMessage = error.localizedDescription
                    isImportingFromURL = false
                }
            }
        }
    }

    private func suggestedRemoteFontFileName(from url: URL, response: URLResponse, data: Data) -> String {
        var fileName = response.suggestedFilename?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if fileName.isEmpty {
            fileName = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if fileName.isEmpty || fileName == "/" {
            fileName = "font-from-url"
        }

        let lowercased = fileName.lowercased()
        let allowedExtensions: Set<String> = ["ttf", "otf", "ttc", "woff", "woff2"]
        if allowedExtensions.contains((lowercased as NSString).pathExtension) {
            return fileName
        }

        let inferredExtension = inferredFontExtension(response: response, data: data) ?? "ttf"
        return "\(fileName).\(inferredExtension)"
    }

    private func inferredFontExtension(response: URLResponse, data: Data) -> String? {
        if let httpResponse = response as? HTTPURLResponse,
           let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() {
            if contentType.contains("woff2") { return "woff2" }
            if contentType.contains("woff") { return "woff" }
            if contentType.contains("ttc") || contentType.contains("collection") { return "ttc" }
            if contentType.contains("otf") || contentType.contains("opentype") { return "otf" }
            if contentType.contains("ttf") || contentType.contains("truetype") || contentType.contains("sfnt") { return "ttf" }
        }

        let header = [UInt8](data.prefix(4))
        if header == [0x77, 0x4F, 0x46, 0x32] { return "woff2" } // wOF2
        if header == [0x77, 0x4F, 0x46, 0x46] { return "woff" } // wOFF
        if header == [0x74, 0x74, 0x63, 0x66] { return "ttc" } // ttcf
        if header == [0x4F, 0x54, 0x54, 0x4F] { return "otf" } // OTTO
        if header == [0x00, 0x01, 0x00, 0x00] { return "ttf" }
        return nil
    }
}

private enum FontRoutePreview {
    static func font(for role: FontSemanticRole, sample: String, size: CGFloat) -> Font {
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
