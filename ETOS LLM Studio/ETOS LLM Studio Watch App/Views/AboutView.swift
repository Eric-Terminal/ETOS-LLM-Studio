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
import Shared
import WatchKit
import AuthenticationServices

struct AboutView: View {
    private let documentationURL = URL(string: "https://docs.els.ericterminal.com/")!
    private let privacyURL = URL(string: "https://privacy.els.ericterminal.com/")!
    @State private var webAuthLauncher = WatchWebAuthLauncher()
    @State private var versionTapCount = 0
    @State private var lastVersionTapAt: Date = .distantPast
    @State private var showAppLogs = false
    
    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "N/A"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "N/A"
        return "\(version) (Build \(build))"
    }

    private var appCommitHash: String {
        let rawValue = Bundle.main.object(forInfoDictionaryKey: "ETCommitHash") as? String
        let normalized = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else { return "Unknown" }
        return normalized
    }

    private var appCommitHashShort: String {
        String(appCommitHash.prefix(7))
    }

    private var documentationHost: String {
        documentationURL.host() ?? documentationURL.absoluteString
    }

    private var privacyHost: String {
        privacyURL.host() ?? privacyURL.absoluteString
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
                            .etFont(.headline)
                        Text("原生 AI 聊天客户端")
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 4)

                Divider()

                // MARK: - App Info
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("版本")
                            .etFont(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(appVersion)
                            .etFont(.caption)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleVersionTap()
                    }
                    InfoRow(title: "Git 提交", value: appCommitHashShort)
                    InfoRow(title: "开发者", value: "Eric-Terminal")
                    InfoRow(title: "平台支持", value: "iOS / watchOS")
                }
                
                Divider()
                
                // MARK: - Features
                VStack(alignment: .leading, spacing: 6) {
                    Text("核心功能")
                        .etFont(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    
                    FeatureRow(icon: "gearshape.2", color: .blue, title: "完全可定制", description: "动态配置 API 提供商和模型")
                    FeatureRow(icon: "brain", color: .purple, title: "智能记忆", description: "离线 RAG 系统，设备端向量化")
                    FeatureRow(icon: "hammer", color: .orange, title: "工具调用", description: "AI 智能体自主使用内置工具")
                    FeatureRow(icon: "arrow.triangle.branch", color: .green, title: "会话分支", description: "从任意节点创建对话分支")
                    FeatureRow(icon: "applewatch", color: .cyan, title: "双端同步", description: "iPhone 与 Apple Watch 无缝协作")
                }
                
                Divider()
                
                // MARK: - Links
                Button {
                    webAuthLauncher.open(url: documentationURL)
                } label: {
                    HStack {
                        Text(NSLocalizedString("文档", comment: "Documentation"))
                            .etFont(.caption)
                        Spacer()
                        Text(documentationHost)
                            .etFont(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .buttonStyle(.plain)
                
                Divider()
                
                // MARK: - Legal
                VStack(alignment: .leading, spacing: 6) {
                    InfoRow(title: "开源协议", value: "GPLv3")
                    
                    Button {
                        webAuthLauncher.open(url: privacyURL)
                    } label: {
                        HStack {
                            Text("隐私政策")
                                .etFont(.caption)
                            Spacer()
                            Text(privacyHost)
                                .etFont(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .buttonStyle(.plain)
                }
                
                // MARK: - Footer
                VStack(spacing: 4) {
                    Text("Made with ❤️ in SwiftUI")
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    Text("© 2025-2026 Eric-Terminal")
                        .etFont(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 8)
            }
            .padding(.horizontal)
        }
        .navigationTitle("关于")
        .sheet(isPresented: $showAppLogs) {
            NavigationStack {
                WatchAppLogsView()
            }
        }
    }

    private func handleVersionTap() {
        let now = Date()
        if now.timeIntervalSince(lastVersionTapAt) > 1.5 {
            versionTapCount = 0
        }
        lastVersionTapAt = now
        versionTapCount += 1

        guard versionTapCount >= 7 else { return }
        versionTapCount = 0
        showAppLogs = true
        AppLog.userOperation(category: "调试入口", action: "打开应用日志页")
        WKInterfaceDevice.current().play(.success)
    }
}

@MainActor
private final class WatchWebAuthLauncher: NSObject {
    private var session: ASWebAuthenticationSession?

    func open(url: URL) {
        session?.cancel()
        session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, _ in
            Task { @MainActor in
                self?.session = nil
            }
        }
        session?.prefersEphemeralWebBrowserSession = true
        _ = session?.start()
    }
}

// MARK: - Info Row Component

private struct InfoRow: View {
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Text(title)
                .etFont(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .etFont(.caption)
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
                .etFont(.system(size: 12))
                .foregroundStyle(color)
                .frame(width: 20, height: 20)
                .background(color.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .etFont(.caption2.weight(.medium))
                Text(description)
                    .etFont(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Privacy Policy View

// Privacy policy is hosted externally.

struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            AboutView()
        }
    }
}
