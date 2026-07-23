// ============================================================================
// AboutView.swift
// ============================================================================
// AboutView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore
#if canImport(UIKit)
import UIKit
#endif

enum OfficialCommunity: String, Identifiable, Equatable {
    case qq
    case telegram
    case testFlight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .qq:
            return NSLocalizedString("QQ 群", comment: "官方 QQ 社群")
        case .telegram:
            return NSLocalizedString("Telegram 社群", comment: "官方 Telegram 社群")
        case .testFlight:
            return NSLocalizedString("加入 TestFlight", comment: "关于页 TestFlight 邀请入口")
        }
    }

    var account: String? {
        switch self {
        case .qq:
            return "974605250"
        case .telegram:
            return "@ETOSLLMStudio"
        case .testFlight:
            return nil
        }
    }

    var systemImage: String {
        switch self {
        case .qq:
            return "person.3.fill"
        case .telegram:
            return "paperplane.fill"
        case .testFlight:
            return "airplane"
        }
    }

    var appURL: URL {
        switch self {
        case .qq:
            return URL(string: "mqqapi://card/show_pslcard?src_type=internal&version=1&uin=974605250&card_type=group&source=qrcode")!
        case .telegram:
            return URL(string: "tg://resolve?domain=ETOSLLMStudio")!
        case .testFlight:
            return URL(string: "https://testflight.apple.com/join/d4PgF4CK")!
        }
    }

    var fallbackURL: URL? {
        switch self {
        case .qq:
            return nil
        case .telegram:
            return URL(string: "https://t.me/ETOSLLMStudio")!
        case .testFlight:
            return nil
        }
    }

    static func visibleCommunities(for channel: UpdateTimelineChannel) -> [OfficialCommunity] {
        switch channel {
        case .appStore:
            return [.qq, .telegram, .testFlight]
        case .testFlight:
            return [.qq, .telegram]
        }
    }
}

struct AboutView: View {
    @Environment(\.openURL) private var openURL
    @State private var versionTapCount = 0
    @State private var lastVersionTapAt: Date = .distantPast
    @State private var showAppLogs = false
    @State private var isSynchronizingOfficialData = false
    @State private var officialDataAlertTitle = ""
    @State private var officialDataAlertMessage = ""
    @State private var showOfficialDataAlert = false
    private let officialCommunities: [OfficialCommunity]

    init(distributionChannel: UpdateTimelineChannel = UpdateTimelineManager.currentDistributionChannel()) {
        officialCommunities = OfficialCommunity.visibleCommunities(for: distributionChannel)
    }
    
    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? NSLocalizedString("N/A", comment: "Unavailable app info")
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? NSLocalizedString("N/A", comment: "Unavailable app info")
        return String(format: NSLocalizedString("%@ (Build %@)", comment: "App version and build"), version, build)
    }

    private var appCommitHash: String {
        let rawValue = Bundle.main.object(forInfoDictionaryKey: "ETCommitHash") as? String
        let normalized = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else { return NSLocalizedString("Unknown", comment: "Unknown app info") }
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
                        Text(NSLocalizedString("ETOS LLM Studio", comment: "App name"))
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
                LabeledContent(NSLocalizedString("Git 提交", comment: "")) {
                    Text(appCommitHashShort)
                        .foregroundStyle(.secondary)
                }
                LabeledContent(NSLocalizedString("开发者", comment: ""), value: NSLocalizedString("Eric-Terminal", comment: "Developer name"))
                LabeledContent(NSLocalizedString("平台支持", comment: ""), value: NSLocalizedString("iOS / watchOS", comment: "Supported platforms"))
                NavigationLink {
                    UpdateTimelineView()
                } label: {
                    Label(NSLocalizedString("检查更新", comment: "About page update check entry"), systemImage: "arrow.clockwise")
                }
            }

            // MARK: - 官方社群
            Section(
                header: Text(NSLocalizedString("官方社群", comment: "关于页官方社群分组")),
                footer: Text(NSLocalizedString("轻点即可在对应 App 中打开。", comment: "iOS 官方社群操作提示"))
            ) {
                ForEach(officialCommunities) { community in
                    Button {
                        openCommunity(community)
                    } label: {
                        VStack {
                            if community == .testFlight {
                                Divider()
                            }

                            LabeledContent {
                                if let account = community.account {
                                    Text(account)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } label: {
                                Label(community.title, systemImage: community.systemImage)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            // MARK: - 软件服务
            Section(
                header: Text(NSLocalizedString("软件服务", comment: "关于页软件服务分组")),
                footer: Text(
                    NSLocalizedString(
                        "从官方服务重新下载配置与资源。已有同名文件会安全更新。",
                        comment: "官方数据同步说明"
                    )
                )
            ) {
                Button {
                    synchronizeOfficialData()
                } label: {
                    if isSynchronizingOfficialData {
                        HStack {
                            ProgressView()
                            Text(NSLocalizedString("正在同步官方数据…", comment: "官方数据同步进度"))
                        }
                    } else {
                        Label(
                            NSLocalizedString("同步官方数据", comment: "官方数据同步按钮"),
                            systemImage: "arrow.down.doc"
                        )
                    }
                }
                .disabled(isSynchronizingOfficialData)
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
                LabeledContent(NSLocalizedString("开源协议", comment: ""), value: NSLocalizedString("GPLv3", comment: "Open source license"))
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
                    Text(NSLocalizedString("Made with ❤️ in SwiftUI", comment: "About page footer"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("© 2025-2026 Eric-Terminal", comment: "Copyright footer"))
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
        .alert(officialDataAlertTitle, isPresented: $showOfficialDataAlert) {
            Button(NSLocalizedString("好", comment: "关闭提示按钮"), role: .cancel) {}
        } message: {
            Text(officialDataAlertMessage)
        }
    }

    private func synchronizeOfficialData() {
        guard !isSynchronizingOfficialData else { return }
        isSynchronizingOfficialData = true

        Task {
            let result = await ConfigLoader.synchronizeOfficialData(overwriteExisting: true)
            isSynchronizingOfficialData = false

            if result.isAlreadyRunning {
                officialDataAlertTitle = NSLocalizedString("同步未完成", comment: "官方数据同步失败标题")
                officialDataAlertMessage = NSLocalizedString(
                    "官方数据正在同步，请稍后再试。",
                    comment: "官方数据同步任务冲突提示"
                )
            } else if !result.isComplete {
                officialDataAlertTitle = NSLocalizedString("同步未完成", comment: "官方数据同步失败标题")
                officialDataAlertMessage = NSLocalizedString(
                    "部分官方文件下载失败，请检查网络后重试。",
                    comment: "官方数据同步失败说明"
                )
            } else if result.didWriteFiles {
                officialDataAlertTitle = NSLocalizedString("官方数据已更新", comment: "官方数据同步成功标题")
                officialDataAlertMessage = String(
                    format: NSLocalizedString("已同步 %d 个官方文件。", comment: "官方数据同步成功数量"),
                    result.downloadedCount
                )
            } else {
                officialDataAlertTitle = NSLocalizedString("官方数据已是最新", comment: "官方数据无需更新标题")
                officialDataAlertMessage = NSLocalizedString(
                    "没有需要更新的官方文件。",
                    comment: "官方数据无需更新说明"
                )
            }
            showOfficialDataAlert = true
        }
    }

    private func openCommunity(_ community: OfficialCommunity) {
        openURL(community.appURL) { accepted in
            guard !accepted, let fallbackURL = community.fallbackURL else { return }
            openURL(fallbackURL)
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
