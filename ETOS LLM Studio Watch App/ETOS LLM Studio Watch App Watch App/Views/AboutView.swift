// ============================================================================
// AboutView.swift
// ============================================================================
// ETOS LLM Studio Watch App “关于”页面视图
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
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                
                HStack {
                    Spacer()
                    Image(systemName: "swift")
                        .font(.system(size: 40)) // 针对 watchOS 稍微缩小
                        .foregroundColor(.accentColor)
                    Spacer()
                }
                .padding(.bottom, 5)

                Text("ETOS LLM Studio")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)

                Divider()

                // 版本
                VStack(alignment: .leading) {
                    Text("版本号")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text(appVersion)
                        .font(.body)
                }

                // 开发者
                VStack(alignment: .leading) {
                    Text("开发者")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text("Eric-Terminal")
                        .font(.body)
                }
                
                // GitHub 链接
                VStack(alignment: .leading) {
                    Text("项目地址")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Link("在 GitHub 上查看", destination: URL(string: "https://github.com/Eric-Terminal/ETOS-LLM-Studio")!)
                        .font(.body)
                }
                
                // 隐私政策
                VStack(alignment: .leading) {
                    Text("隐私政策")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    // 将来这里会链接到正式的隐私政策视图/URL
                    Text("暂未提供")
                        .font(.body)
                        .foregroundColor(.gray)
                }
            }
            .padding()
        }
        .navigationTitle("关于")
    }
}

struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            AboutView()
        }
    }
}