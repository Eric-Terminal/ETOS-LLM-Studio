// ============================================================================
// AboutView.swift
// ============================================================================
// ETOS LLM Studio iOS App “关于”页面视图
//
// 定义内容:
// - 显示应用的版本号、开发者信息和项目链接
// ============================================================================

import SwiftUI

struct AboutView: View {
    
    // 获取 App 版本号和构建号的函数
    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "N/A"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "N/A"
        return "\(version) (Build \(build))"
    }
    
    var body: some View {
        // 使用 NavigationView 以在 iOS 上正确显示标题
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { // 针对 iOS 增大了间距
                    
                    HStack {
                        Spacer()
                        Image(systemName: "swift") // 使用一个通用但相关的 SF Symbol
                            .font(.system(size: 60))
                            .foregroundColor(.accentColor)
                        Spacer()
                    }
                    .padding(.vertical, 10)

                    Text("ETOS LLM Studio")
                        .font(.largeTitle.bold()) // 针对 iOS 使用更粗的标题
                        .frame(maxWidth: .infinity, alignment: .center)

                    Divider()

                    // 版本
                    VStack(alignment: .leading) {
                        Text("版本号")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text(appVersion)
                            .font(.body)
                    }

                    // 开发者
                    VStack(alignment: .leading) {
                        Text("开发者")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Eric-Terminal")
                            .font(.body)
                    }
                    
                    // GitHub 链接
                    VStack(alignment: .leading) {
                        Text("项目地址")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Link("在 GitHub 上查看", destination: URL(string: "https://github.com/Eric-Terminal/ETOS-LLM-Studio")!)
                            .font(.body)
                    }
                    
                    // 隐私政策
                    VStack(alignment: .leading) {
                        Text("隐私政策")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("暂未提供")
                            .font(.body)
                            .foregroundColor(.gray)
                    }
                }
                .padding()
            }
            .navigationTitle("关于 ETOS")
            .navigationBarTitleDisplayMode(.inline) // 在表单中使用更紧凑的标题样式
        }
    }
}

struct AboutView_Previews_iOS: PreviewProvider {
    static var previews: some View {
        AboutView()
    }
}