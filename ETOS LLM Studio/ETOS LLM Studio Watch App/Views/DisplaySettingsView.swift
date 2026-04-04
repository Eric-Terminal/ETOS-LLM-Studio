// ============================================================================
// DisplaySettingsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 显示设置视图
//
// 功能特性:
// - 提供所有与UI显示相关的设置选项
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct DisplaySettingsView: View {
    
    // MARK: - 绑定
    
    @Binding var enableMarkdown: Bool
    @Binding var enableBackground: Bool
    @Binding var backgroundBlur: Double
    @Binding var backgroundOpacity: Double
    @Binding var enableAutoRotateBackground: Bool
    @Binding var currentBackgroundImage: String
    @Binding var backgroundContentMode: String // "fill" 或 "fit"
    @Binding var enableLiquidGlass: Bool // 新增绑定
    @Binding var enableAdvancedRenderer: Bool
    @Binding var enableExperimentalToolResultDisplay: Bool
    @Binding var enableAutoReasoningPreview: Bool
    @Binding var enableNoBubbleUI: Bool

    @AppStorage("enableCustomUserBubbleColor") private var enableCustomUserBubbleColor: Bool = false
    @AppStorage("customUserBubbleColorHex") private var customUserBubbleColorHex: String = "3D8FF2FF"
    @AppStorage("enableCustomAssistantBubbleColor") private var enableCustomAssistantBubbleColor: Bool = false
    @AppStorage("customAssistantBubbleColorHex") private var customAssistantBubbleColorHex: String = "F2F2F7FF"
    @AppStorage("enableCustomLightTextColor") private var enableCustomLightTextColor: Bool = false
    @AppStorage("customLightTextColorHex") private var customLightTextColorHex: String = "1C1C1EFF"
    @AppStorage("enableCustomDarkTextColor") private var enableCustomDarkTextColor: Bool = false
    @AppStorage("customDarkTextColorHex") private var customDarkTextColorHex: String = "FFFFFFFF"
    
    // MARK: - 属性
    
    let allBackgrounds: [String]
    
    // MARK: - 视图主体
    
    var body: some View {
        Form {
            if #available(watchOS 26.0, *) {
                Section(header: Text("特效")) {
                    Toggle("启用液态玻璃", isOn: $enableLiquidGlass)
                }
            }
            
            Section(header: Text("内容显示")) {
                Toggle("渲染 Markdown", isOn: $enableMarkdown)
            }

            if enableMarkdown {
                Section {
                    Toggle("使用高级渲染器", isOn: $enableAdvancedRenderer)
                } footer: {
                    Text("启用后可使用更强的 Markdown/LaTeX 渲染能力。")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("增强工具结果显示（实验性）", isOn: $enableExperimentalToolResultDisplay)
            } footer: {
                Text("启用后会优先提取工具结果正文并折叠原始 JSON；关闭后恢复为原始结果文本展示。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("自动预览思考过程", isOn: $enableAutoReasoningPreview)
            } footer: {
                Text("开启后，AI 回复仅有思考内容时会自动展开；一旦出现正文会自动收起。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    WatchFontSettingsView()
                } label: {
                    Label("字体设置", systemImage: "textformat.alt")
                }
            }

            Section {
                Toggle("无气泡UI", isOn: $enableNoBubbleUI)
            } footer: {
                Text("开启后聊天气泡背景会透明化，并自动放宽消息文本宽度。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("聊天颜色自定义") {
                Toggle("自定义用户气泡颜色", isOn: $enableCustomUserBubbleColor)
                if enableCustomUserBubbleColor {
                    ColorPicker("用户气泡颜色", selection: userBubbleColorBinding, supportsOpacity: false)
                }

                Toggle("自定义助手气泡颜色（含 Tool）", isOn: $enableCustomAssistantBubbleColor)
                if enableCustomAssistantBubbleColor {
                    ColorPicker("助手气泡颜色", selection: assistantBubbleColorBinding, supportsOpacity: false)
                }

                Toggle("自定义白天文字颜色", isOn: $enableCustomLightTextColor)
                if enableCustomLightTextColor {
                    ColorPicker("白天文字颜色", selection: lightTextColorBinding, supportsOpacity: false)
                }

                Toggle("自定义夜览文字颜色", isOn: $enableCustomDarkTextColor)
                if enableCustomDarkTextColor {
                    ColorPicker("夜览文字颜色", selection: darkTextColorBinding, supportsOpacity: false)
                }

                if hasAnyCustomColorOverride {
                    Button("恢复默认聊天颜色") {
                        resetCustomChatColors()
                    }
                }
            } footer: {
                Text("默认全部关闭时，聊天配色与当前版本完全一致。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            Section(header: Text("背景")) {
                Toggle("显示背景", isOn: $enableBackground)
                
                if enableBackground {
                    // 背景填充模式选择
                    Picker("填充模式", selection: $backgroundContentMode) {
                        Text("填充 (居中裁剪)").tag("fill")
                        Text("适应 (完整显示)").tag("fit")
                    }
                    
                    VStack(alignment: .leading) {
                        Text(String(format: NSLocalizedString("背景模糊: %.1f", comment: ""), backgroundBlur))
                        Slider(value: $backgroundBlur, in: 0...25, step: 0.5)
                    }
                    
                    VStack(alignment: .leading) {
                        Text(String(format: NSLocalizedString("背景不透明度: %.2f", comment: ""), backgroundOpacity))
                        Slider(value: $backgroundOpacity, in: 0.1...1.0, step: 0.05)
                    }
                    
                    Toggle("背景随机轮换", isOn: $enableAutoRotateBackground)
                    
                    NavigationLink(destination: BackgroundPickerView(
                        allBackgrounds: allBackgrounds,
                        selectedBackground: $currentBackgroundImage
                    )) {
                        Text("选择背景")
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

    private var hasAnyCustomColorOverride: Bool {
        enableCustomUserBubbleColor
            || enableCustomAssistantBubbleColor
            || enableCustomLightTextColor
            || enableCustomDarkTextColor
    }

    private var userBubbleColorBinding: Binding<Color> {
        colorBinding(hex: $customUserBubbleColorHex, fallback: .init(.sRGB, red: 0.24, green: 0.56, blue: 0.95, opacity: 1))
    }

    private var assistantBubbleColorBinding: Binding<Color> {
        colorBinding(hex: $customAssistantBubbleColorHex, fallback: .init(.sRGB, red: 0.949, green: 0.949, blue: 0.969, opacity: 1))
    }

    private var lightTextColorBinding: Binding<Color> {
        colorBinding(hex: $customLightTextColorHex, fallback: .init(.sRGB, red: 0.11, green: 0.11, blue: 0.12, opacity: 1))
    }

    private var darkTextColorBinding: Binding<Color> {
        colorBinding(hex: $customDarkTextColorHex, fallback: .white)
    }

    private func colorBinding(hex: Binding<String>, fallback: Color) -> Binding<Color> {
        Binding(
            get: { ChatAppearanceColorCodec.color(from: hex.wrappedValue, fallback: fallback) },
            set: { newColor in
                if let encoded = ChatAppearanceColorCodec.hexRGBA(from: newColor) {
                    hex.wrappedValue = encoded
                }
            }
        )
    }

    private func resetCustomChatColors() {
        enableCustomUserBubbleColor = false
        enableCustomAssistantBubbleColor = false
        enableCustomLightTextColor = false
        enableCustomDarkTextColor = false
        customUserBubbleColorHex = "3D8FF2FF"
        customAssistantBubbleColorHex = "F2F2F7FF"
        customLightTextColorHex = "1C1C1EFF"
        customDarkTextColorHex = "FFFFFFFF"
    }
}

private struct WatchFontSettingsView: View {
    @State private var assets: [FontAssetRecord] = []
    @State private var routes: FontRouteConfiguration = .init()
    @State private var selectedRole: FontSemanticRole = .body

    var body: some View {
        List {
            Section("字体来源") {
                if assets.isEmpty {
                    Text("暂无字体，请先在 iPhone 端导入并同步。")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(assets) { asset in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(asset.displayName)
                                        .etFont(.footnote)
                                    Text(asset.postScriptName)
                                        .etFont(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Toggle("启用", isOn: enabledBinding(for: asset))
                                    .labelsHidden()
                            }
                        }
                    }
                }
            }

            Section("样式优先级") {
                Picker("样式槽位", selection: $selectedRole) {
                    ForEach(FontSemanticRole.allCases) { role in
                        Text(role.title).tag(role)
                    }
                }
                if chainRecords.isEmpty {
                    Text("当前槽位为空，使用系统字体。")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(chainRecords.enumerated()), id: \.element.id) { index, asset in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(asset.displayName)
                                    .foregroundStyle(asset.isEnabled ? .primary : .secondary)
                                if !asset.isEnabled {
                                    Text("已停用")
                                        .etFont(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer(minLength: 8)
                            HStack(spacing: 4) {
                                Button {
                                    moveAsset(at: index, offset: -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == 0)

                                Button {
                                    moveAsset(at: index, offset: 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index >= chainRecords.count - 1)
                            }
                        }
                    }
                }
            }

            Section("预览") {
                Text("风来疏竹，风过而竹不留声。")
                    .etFont(FontRoutePreview.etFont(for: .body, sample: "风来疏竹，风过而竹不留声。", size: 14))
                Text("Emphasis")
                    .etFont(FontRoutePreview.etFont(for: .emphasis, sample: "Emphasis", size: 14))
                    .italic()
                Text("Strong")
                    .etFont(FontRoutePreview.etFont(for: .strong, sample: "Strong", size: 14))
                    .fontWeight(.bold)
                Text("let value = 42")
                    .etFont(FontRoutePreview.etFont(for: .code, sample: "let value = 42", size: 13))
            }
        }
        .navigationTitle("字体设置")
        .onAppear {
            FontLibrary.registerAllFontsIfNeeded()
            reloadData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncFontsUpdated)) { _ in
            reloadData()
        }
    }

    private var chainRecords: [FontAssetRecord] {
        let map = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        return routes.chain(for: selectedRole).compactMap { map[$0] }
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

    private func moveAsset(at index: Int, offset: Int) {
        var chain = routes.chain(for: selectedRole)
        let target = index + offset
        guard chain.indices.contains(index), chain.indices.contains(target) else { return }
        chain.swapAt(index, target)
        routes.setChain(chain, for: selectedRole)
        FontLibrary.updateChain(chain, for: selectedRole)
        NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
    }

    private func updateAssetEnabled(assetID: UUID, isEnabled: Bool) {
        guard FontLibrary.setAssetEnabled(id: assetID, isEnabled: isEnabled) else { return }
        reloadData()
        NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
    }
}

private enum FontRoutePreview {
    static func etFont(for role: FontSemanticRole, sample: String, size: CGFloat) -> Font {
        if let postScriptName = FontLibrary.resolvePostScriptName(for: role, sampleText: sample) {
            return .custom(postScriptName, size: size)
        }
        return .system(size: size)
    }
}
