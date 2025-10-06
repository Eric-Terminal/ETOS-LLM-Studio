// ============================================================================
// DisplaySettingsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 显示设置视图
//
// 功能特性:
// - 提供所有与UI显示相关的设置选项
// ============================================================================

import SwiftUI

struct DisplaySettingsView: View {
    
    // MARK: - 绑定
    
    @Binding var enableMarkdown: Bool
    @Binding var enableBackground: Bool
    @Binding var backgroundBlur: Double
    @Binding var backgroundOpacity: Double
    @Binding var enableAutoRotateBackground: Bool
    @Binding var currentBackgroundImage: String
    @Binding var enableLiquidGlass: Bool // 新增绑定
    
    // MARK: - 属性
    
    let allBackgrounds: [String]
    
    // MARK: - 视图主体
    
    var body: some View {
        Form {
            Section(header: Text("特效")) {
                Toggle("启用液态玻璃", isOn: $enableLiquidGlass)
            }
            
            Section(header: Text("内容显示")) {
                Toggle("渲染 Markdown", isOn: $enableMarkdown)
            }
            
            Section(header: Text("背景")) {
                Toggle("显示背景", isOn: $enableBackground)
                
                if enableBackground {
                    VStack(alignment: .leading) {
                        Text("背景模糊: \(String(format: "%.1f", backgroundBlur))")
                        Slider(value: $backgroundBlur, in: 0...25, step: 0.5)
                    }
                    
                    VStack(alignment: .leading) {
                        Text("背景不透明度: \(String(format: "%.2f", backgroundOpacity))")
                        Slider(value: $backgroundOpacity, in: 0.1...1.0, step: 0.05)
                    }
                    
                    Toggle("背景随机轮换", isOn: $enableAutoRotateBackground)
                    
                    if !enableAutoRotateBackground {
                        NavigationLink(destination: BackgroundPickerView(
                            allBackgrounds: allBackgrounds,
                            selectedBackground: $currentBackgroundImage
                        )) {
                            Text("选择背景")
                        }
                    }
                }
            }
        }
        .navigationTitle("显示设置")
    }
}