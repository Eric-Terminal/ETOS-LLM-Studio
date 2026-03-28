// ============================================================================
// DisplaySettingsView.swift
// ============================================================================
// DisplaySettingsView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Foundation

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
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Toggle("增强工具结果显示（实验性）", isOn: $enableExperimentalToolResultDisplay)
                Text("启用后会优先提取工具结果正文并折叠原始 JSON；关闭后恢复为原始结果文本展示。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("自动预览思考过程", isOn: $enableAutoReasoningPreview)
                Text("开启后，AI 回复仅有思考内容时会自动展开；一旦出现正文会自动收起。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
