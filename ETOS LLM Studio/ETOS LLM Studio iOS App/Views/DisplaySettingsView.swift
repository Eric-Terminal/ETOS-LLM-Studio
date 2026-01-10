import SwiftUI
import Foundation

struct DisplaySettingsView: View {
    @Binding var enableMarkdown: Bool
    @Binding var enableBackground: Bool
    @Binding var backgroundBlur: Double
    @Binding var backgroundOpacity: Double
    @Binding var enableAutoRotateBackground: Bool
    @Binding var currentBackgroundImage: String
    @Binding var enableLiquidGlass: Bool
    
    let allBackgrounds: [String]
    
    var body: some View {
        Form {
            Section("内容表现") {
                Toggle("渲染 Markdown", isOn: $enableMarkdown)
                if #available(iOS 26.0, *) {
                    Toggle("液态玻璃效果", isOn: $enableLiquidGlass)
                }
            }
            
            Section("背景") {
                Toggle("显示背景", isOn: $enableBackground)
                
                if enableBackground {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: NSLocalizedString("模糊 %.1f", comment: ""), backgroundBlur))
                        Slider(value: $backgroundBlur, in: 0...25, step: 0.5)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: NSLocalizedString("不透明度 %.2f", comment: ""), backgroundOpacity))
                        Slider(value: $backgroundOpacity, in: 0.1...1.0, step: 0.05)
                    }
                    
                    Toggle("自动轮换背景", isOn: $enableAutoRotateBackground)
                    
                    if !enableAutoRotateBackground {
                        NavigationLink {
                            BackgroundPickerView(allBackgrounds: allBackgrounds, selectedBackground: $currentBackgroundImage)
                        } label: {
                            Label("选择背景图", systemImage: "photo.on.rectangle")
                        }
                    }
                }
            }
        }
        .navigationTitle("显示设置")
    }
}
