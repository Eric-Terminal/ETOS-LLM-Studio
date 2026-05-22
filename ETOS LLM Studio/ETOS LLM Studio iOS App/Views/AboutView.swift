// ============================================================================
// AboutView.swift
// ============================================================================
// AboutView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Foundation
import Shared
#if canImport(UIKit)
import UIKit
#endif

struct AboutView: View {
    @Environment(\.openURL) private var openURL
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
    
    private let githubURL = URL(string: "https://github.com/Eric-Terminal/ETOS-LLM-Studio")!
    private let documentationURL = URL(string: "https://docs.els.ericterminal.com/")!
    private let privacyURL = URL(string: "https://privacy.els.ericterminal.com/")!

    private var githubDisplayString: String {
        githubURL.absoluteString.replacingOccurrences(of: "https://", with: "")
    }

    private var documentationHost: String {
        documentationURL.host() ?? documentationURL.absoluteString
    }

    private var privacyHost: String {
        privacyURL.host() ?? privacyURL.absoluteString
    }
    
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
                            .etFont(.title2.weight(.bold))
                        Text(NSLocalizedString("原生 AI 聊天客户端", comment: ""))
                            .etFont(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowBackground(Color.clear)
                .padding(.vertical, 8)
            }
            
            // MARK: - App Info
            Section(header: Text(NSLocalizedString("应用信息", comment: ""))) {
                HStack {
                    Text(NSLocalizedString("版本", comment: ""))
                    Spacer()
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    handleVersionTap()
                }
                NavigationLink {
                    UpdateTimelineView()
                } label: {
                    LabeledContent(NSLocalizedString("Git 提交", comment: "")) {
                        Text(appCommitHashShort)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent(NSLocalizedString("开发者", comment: ""), value: "Eric-Terminal")
                LabeledContent(NSLocalizedString("平台支持", comment: ""), value: "iOS / watchOS")
            }
            
            // MARK: - Links
            Section(header: Text(NSLocalizedString("链接", comment: ""))) {
                Button {
                    openURL(githubURL)
                } label: {
                    LabeledContent(NSLocalizedString("GitHub 项目主页", comment: "GitHub project homepage")) {
                        Text(githubDisplayString)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .buttonStyle(.plain)

                Button {
                    openURL(documentationURL)
                    Task {
                        let hasUnlocked = AchievementCenter.shared.hasUnlocked(id: .documentationReader)
                        guard !hasUnlocked else { return }
                        await AchievementCenter.shared.unlock(id: .documentationReader)
                    }
                } label: {
                    LabeledContent(NSLocalizedString("文档", comment: "Documentation")) {
                        Text(documentationHost)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .buttonStyle(.plain)
            }
            
            // MARK: - Legal
            Section(header: Text(NSLocalizedString("法律信息", comment: ""))) {
                LabeledContent(NSLocalizedString("开源协议", comment: ""), value: "GPLv3")
                Button {
                    openURL(privacyURL)
                    Task {
                        let hasUnlocked = AchievementCenter.shared.hasUnlocked(id: .privacyReader)
                        guard !hasUnlocked else { return }
                        await AchievementCenter.shared.unlock(id: .privacyReader)
                    }
                } label: {
                    LabeledContent(NSLocalizedString("隐私政策", comment: "")) {
                        Text(privacyHost)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .buttonStyle(.plain)
            }
            
            // MARK: - Footer
            Section {
                VStack(spacing: 8) {
                    Text("Made with ❤️ in SwiftUI")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                    Text("© 2025-2026 Eric-Terminal")
                        .etFont(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(NSLocalizedString("关于", comment: ""))
        .sheet(isPresented: $showAppLogs) {
            NavigationStack {
                AppLogsView()
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
        AppLog.userOperation(
            category: NSLocalizedString("调试入口", comment: "App log category"),
            action: NSLocalizedString("打开应用日志页", comment: "App log action")
        )
        Task {
            let hasUnlocked = AchievementCenter.shared.hasUnlocked(id: .forbiddenPlace)
            guard !hasUnlocked else { return }
            await AchievementCenter.shared.unlock(id: .forbiddenPlace)
        }

        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
}

// MARK: - Privacy Policy View

// Privacy policy is hosted externally.
