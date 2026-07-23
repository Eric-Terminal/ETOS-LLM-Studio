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
import ETOSCore
import WatchKit
import AuthenticationServices

enum WatchOfficialCommunity: String, Identifiable, Equatable {
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

    var qrPayload: String {
        switch self {
        case .qq:
            return "mqqapi://card/show_pslcard?src_type=internal&version=1&uin=974605250&card_type=group&source=qrcode"
        case .telegram:
            return "https://t.me/ETOSLLMStudio"
        case .testFlight:
            return "https://testflight.apple.com/join/d4PgF4CK"
        }
    }

    var qrAssetName: String {
        switch self {
        case .qq:
            return "OfficialCommunityQQQRCode"
        case .telegram:
            return "OfficialCommunityTelegramQRCode"
        case .testFlight:
            return "OfficialCommunityTestFlightQRCode"
        }
    }

    var qrInstruction: String {
        switch self {
        case .qq:
            return NSLocalizedString("使用手机 QQ 扫描二维码，打开群资料并申请加入。", comment: "watchOS QQ 群二维码提示")
        case .telegram:
            return NSLocalizedString("使用手机扫描二维码，在 Telegram 中打开社群。", comment: "watchOS Telegram 社群二维码提示")
        case .testFlight:
            return NSLocalizedString("使用手机扫描二维码，在 TestFlight 中打开测试邀请。", comment: "watchOS TestFlight 二维码提示")
        }
    }

    static func visibleCommunities(for channel: UpdateTimelineChannel) -> [WatchOfficialCommunity] {
        switch channel {
        case .appStore:
            return [.qq, .telegram, .testFlight]
        case .testFlight:
            return [.qq, .telegram]
        }
    }
}

struct AboutView: View {
    private let githubURL = URL(string: "https://github.com/Eric-Terminal/ETOS-LLM-Studio")!
    private let documentationURL = URL(string: "https://docs.els.ericterminal.com/")!
    private let privacyURL = URL(string: "https://privacy.els.ericterminal.com/")!
    @State private var webAuthLauncher = WatchWebAuthLauncher()
    @State private var versionTapCount = 0
    @State private var lastVersionTapAt: Date = .distantPast
    @State private var showAppLogs = false
    @State private var isSynchronizingOfficialData = false
    @State private var officialDataAlertTitle = ""
    @State private var officialDataAlertMessage = ""
    @State private var showOfficialDataAlert = false
    private let officialCommunities: [WatchOfficialCommunity]

    init(distributionChannel: UpdateTimelineChannel = UpdateTimelineManager.currentDistributionChannel()) {
        officialCommunities = WatchOfficialCommunity.visibleCommunities(for: distributionChannel)
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
                        Text(NSLocalizedString("ETOS LLM Studio", comment: "App name"))
                            .etFont(.headline)
                        Text(NSLocalizedString("原生 AI 聊天客户端", comment: ""))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 4)

                Divider()

                // MARK: - App Info
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(NSLocalizedString("版本", comment: ""))
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
                    InfoRow(title: "开发者", value: NSLocalizedString("Eric-Terminal", comment: "Developer name"))
                    InfoRow(title: "平台支持", value: NSLocalizedString("iOS / watchOS", comment: "Supported platforms"))
                    NavigationLink {
                        WatchUpdateTimelineView()
                    } label: {
                        Label(NSLocalizedString("检查更新", comment: "About page update check entry"), systemImage: "arrow.clockwise")
                            .etFont(.caption)
                    }
                    .buttonStyle(.plain)
                }
                
                Divider()

                // MARK: - 官方社群
                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("官方社群", comment: "关于页官方社群分组"))
                        .etFont(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(officialCommunities) { community in
                        if community == .testFlight {
                            Divider()
                        }

                        NavigationLink {
                            WatchCommunityQRCodeView(community: community)
                        } label: {
                            HStack {
                                Label(community.title, systemImage: community.systemImage)
                                    .etFont(.caption)
                                Spacer()
                                if let account = community.account {
                                    Text(account)
                                        .etFont(.caption2)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Image(systemName: "qrcode")
                                        .etFont(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()

                // MARK: - 软件服务
                VStack(alignment: .leading) {
                    Text(NSLocalizedString("软件服务", comment: "关于页软件服务分组"))
                        .etFont(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        synchronizeOfficialData()
                    } label: {
                        if isSynchronizingOfficialData {
                            HStack {
                                ProgressView()
                                Text(NSLocalizedString("正在同步官方数据…", comment: "官方数据同步进度"))
                                    .etFont(.caption)
                            }
                        } else {
                            Label(
                                NSLocalizedString("同步官方数据", comment: "官方数据同步按钮"),
                                systemImage: "arrow.down.doc"
                            )
                            .etFont(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isSynchronizingOfficialData)

                    Text(
                        NSLocalizedString(
                            "从官方服务重新下载配置与资源。已有同名文件会安全更新。",
                            comment: "官方数据同步说明"
                        )
                    )
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                }

                Divider()
                
                // MARK: - Links
                Button {
                    webAuthLauncher.open(url: githubURL)
                } label: {
                    HStack {
                        Text(NSLocalizedString("GitHub 项目主页", comment: "GitHub project homepage"))
                            .etFont(.caption)
                        Spacer()
                        Text(githubDisplayString)
                            .etFont(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .buttonStyle(.plain)

                Button {
                    webAuthLauncher.open(url: documentationURL)
                    Task {
                        let hasUnlocked = AchievementCenter.shared.hasUnlocked(id: .documentationReader)
                        guard !hasUnlocked else { return }
                        await AchievementCenter.shared.unlock(id: .documentationReader)
                    }
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
                    InfoRow(title: "开源协议", value: NSLocalizedString("GPLv3", comment: "Open source license"))
                    
                    Button {
                        webAuthLauncher.open(url: privacyURL)
                        Task {
                            let hasUnlocked = AchievementCenter.shared.hasUnlocked(id: .privacyReader)
                            guard !hasUnlocked else { return }
                            await AchievementCenter.shared.unlock(id: .privacyReader)
                        }
                    } label: {
                        HStack {
                            Text(NSLocalizedString("隐私政策", comment: ""))
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
                    Text(NSLocalizedString("Made with ❤️ in SwiftUI", comment: "About page footer"))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("© 2025-2026 Eric-Terminal", comment: "Copyright footer"))
                        .etFont(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 8)
            }
            .padding(.horizontal)
        }
        .navigationTitle(NSLocalizedString("关于", comment: ""))
        .sheet(isPresented: $showAppLogs) {
            NavigationStack {
                WatchAppLogsView()
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
                WKInterfaceDevice.current().play(.failure)
            } else if !result.isComplete {
                officialDataAlertTitle = NSLocalizedString("同步未完成", comment: "官方数据同步失败标题")
                officialDataAlertMessage = NSLocalizedString(
                    "部分官方文件下载失败，请检查网络后重试。",
                    comment: "官方数据同步失败说明"
                )
                WKInterfaceDevice.current().play(.failure)
            } else if result.didWriteFiles {
                officialDataAlertTitle = NSLocalizedString("官方数据已更新", comment: "官方数据同步成功标题")
                officialDataAlertMessage = String(
                    format: NSLocalizedString("已同步 %d 个官方文件。", comment: "官方数据同步成功数量"),
                    result.downloadedCount
                )
                WKInterfaceDevice.current().play(.success)
            } else {
                officialDataAlertTitle = NSLocalizedString("官方数据已是最新", comment: "官方数据无需更新标题")
                officialDataAlertMessage = NSLocalizedString(
                    "没有需要更新的官方文件。",
                    comment: "官方数据无需更新说明"
                )
                WKInterfaceDevice.current().play(.success)
            }
            showOfficialDataAlert = true
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
        WKInterfaceDevice.current().play(.success)
    }
}

private struct WatchCommunityQRCodeView: View {
    let community: WatchOfficialCommunity

    var body: some View {
        ScrollView {
            VStack {
                Image(community.qrAssetName)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(maxWidth: 160)
                    .accessibilityHidden(true)

                Text(community.title)
                    .etFont(.headline)

                if let account = community.account {
                    Text(account)
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(community.qrInstruction)
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)
        }
        .navigationTitle(NSLocalizedString("扫码加入", comment: "watchOS 社群二维码页面标题"))
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
            Text(NSLocalizedString(title, comment: "关于页信息行标题"))
                .etFont(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .etFont(.caption)
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
