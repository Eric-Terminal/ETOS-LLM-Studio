import SwiftUI
import Foundation

struct AboutView: View {
    @Environment(\.openURL) private var openURL
    
    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "N/A"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "N/A"
        return "\(version) (Build \(build))"
    }
    
    private let githubURL = URL(string: "https://github.com/Eric-Terminal/ETOS-LLM-Studio")!
    private let privacyURL = URL(string: "http://privacy.els.ericterminal.com/")!
    
    var body: some View {
        List {
            // MARK: - App Icon & Name
            Section {
                VStack(alignment: .center, spacing: 16) {
                    Image("AppIconDisplay")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
                    
                    VStack(spacing: 4) {
                        Text("ETOS LLM Studio")
                            .font(.title2.weight(.bold))
                        Text("原生 AI 聊天客户端")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowBackground(Color.clear)
                .padding(.vertical, 8)
            }
            
            // MARK: - App Info
            Section(header: Text("应用信息")) {
                LabeledContent("版本", value: appVersion)
                LabeledContent("开发者", value: "Eric-Terminal")
                LabeledContent("平台支持", value: "iOS / watchOS")
            }
            
            // MARK: - Features
            Section(header: Text("核心功能")) {
                FeatureRow(icon: "gearshape.2", color: .blue, title: "完全可定制", description: "动态配置 API 提供商和模型")
                FeatureRow(icon: "brain", color: .purple, title: "智能记忆", description: "离线 RAG 系统，设备端向量化")
                FeatureRow(icon: "hammer", color: .orange, title: "工具调用", description: "AI 智能体自主使用内置工具")
                FeatureRow(icon: "arrow.triangle.branch", color: .green, title: "会话分支", description: "从任意节点创建对话分支")
                FeatureRow(icon: "applewatch", color: .cyan, title: "双端同步", description: "iPhone 与 Apple Watch 无缝协作")
            }
            
            // MARK: - Links
            Section(header: Text("链接")) {
                Button {
                    openURL(githubURL)
                } label: {
                    HStack {
                        Label("GitHub 项目主页", systemImage: "link")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Button {
                    openURL(URL(string: "https://github.com/Eric-Terminal/ETOS-LLM-Studio/issues")!)
                } label: {
                    HStack {
                        Label("报告问题 / 功能建议", systemImage: "exclamationmark.bubble")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            // MARK: - Legal
            Section(header: Text("法律信息")) {
                LabeledContent("开源协议", value: "GPLv3")
                Button {
                    openURL(privacyURL)
                } label: {
                    HStack {
                        Label("隐私政策", systemImage: "shield")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            // MARK: - Footer
            Section {
                VStack(spacing: 8) {
                    Text("Made with ❤️ in SwiftUI")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("© 2025-2026 Eric-Terminal")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("关于")
    }
}

// MARK: - Feature Row Component

private struct FeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let description: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Privacy Policy View

// Privacy policy is hosted externally.
