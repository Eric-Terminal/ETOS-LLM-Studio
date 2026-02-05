// ============================================================================
// AboutView.swift
// ============================================================================
// ETOS LLM Studio Watch App "关于"页面视图
//
// 定义内容:
// - 显示应用的版本号、开发者信息和项目链接
// ============================================================================

import SwiftUI
import Foundation

struct AboutView: View {
    private let privacyURL = URL(string: "http://privacy.els.ericterminal.com/")!
    
    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "N/A"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "N/A"
        return "\(version) (Build \(build))"
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                
                // MARK: - App Icon & Name
                VStack(spacing: 6) {
                    Image("AppIconDisplay")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    
                    VStack(spacing: 2) {
                        Text("ETOS LLM Studio")
                            .font(.headline)
                        Text("原生 AI 聊天客户端")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 4)

                Divider()

                // MARK: - App Info
                VStack(alignment: .leading, spacing: 6) {
                    InfoRow(title: "版本", value: appVersion)
                    InfoRow(title: "开发者", value: "Eric-Terminal")
                    InfoRow(title: "平台支持", value: "iOS / watchOS")
                }
                
                Divider()
                
                // MARK: - Features
                VStack(alignment: .leading, spacing: 6) {
                    Text("核心功能")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    
                    FeatureRow(icon: "gearshape.2", color: .blue, title: "完全可定制", description: "动态配置 API 提供商和模型")
                    FeatureRow(icon: "brain", color: .purple, title: "智能记忆", description: "离线 RAG 系统，设备端向量化")
                    FeatureRow(icon: "hammer", color: .orange, title: "工具调用", description: "AI 智能体自主使用内置工具")
                    FeatureRow(icon: "arrow.triangle.branch", color: .green, title: "会话分支", description: "从任意节点创建对话分支")
                    FeatureRow(icon: "applewatch", color: .cyan, title: "双端同步", description: "iPhone 与 Apple Watch 无缝协作")
                }
                
                Divider()
                
                // MARK: - Links
                NavigationLink {
                    ProjectLinksView()
                } label: {
                    HStack {
                        Text("项目链接")
                            .font(.caption)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                
                Divider()
                
                // MARK: - Legal
                VStack(alignment: .leading, spacing: 6) {
                    InfoRow(title: "开源协议", value: "GPLv3")
                    
                    Link(destination: privacyURL) {
                        HStack {
                            Text("隐私政策")
                                .font(.caption)
                            Spacer()
                            Image(systemName: "safari")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                
                // MARK: - Footer
                VStack(spacing: 4) {
                    Text("Made with ❤️ in SwiftUI")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("© 2025-2026 Eric-Terminal")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 8)
            }
            .padding(.horizontal)
        }
        .navigationTitle("关于")
    }
}

// MARK: - Info Row Component

private struct InfoRow: View {
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
        }
    }
}

// MARK: - Feature Row Component

private struct FeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let description: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(color)
                .frame(width: 20, height: 20)
                .background(color.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.medium))
                Text(description)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Privacy Policy View

// Privacy policy is hosted externally.

// MARK: - Project Links View

private struct ProjectLinksView: View {
    
    private let githubURL = URL(string: "https://github.com/Eric-Terminal/ETOS-LLM-Studio")!
    private let issuesURL = URL(string: "https://github.com/Eric-Terminal/ETOS-LLM-Studio/issues")!
    
    var body: some View {
        List {
            // 项目主页链接
            Link(destination: githubURL) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("项目主页", systemImage: "house")
                        Spacer()
                        Image(systemName: "safari")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(githubURL.absoluteString)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            
            // 问题反馈链接
            Link(destination: issuesURL) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("问题反馈", systemImage: "exclamationmark.bubble")
                        Spacer()
                        Image(systemName: "safari")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(issuesURL.absoluteString)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            
        }
        .listStyle(.plain)
        .navigationTitle("项目链接")
    }
}

struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            AboutView()
        }
    }
}
