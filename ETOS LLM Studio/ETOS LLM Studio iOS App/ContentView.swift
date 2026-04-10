// ============================================================================
// ContentView.swift (iOS)
// ============================================================================
// 应用根视图:
// - 构建底部 TabView，包含聊天、会话、设置三个主要模块
// - 通过环境注入的 ChatViewModel 在各子视图间共享状态
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var viewModel: ChatViewModel
    @StateObject private var announcementManager = AnnouncementManager.shared
    @ObservedObject private var notificationCenter = AppLocalNotificationCenter.shared
    @State private var selection: Tab = .chat
    @State private var settingsDestination: SettingsNavigationDestination?
    @State private var dailyPulsePreparationTask: Task<Void, Never>?
    @State private var launchRecoveryNoticeMessage: String?
    @State private var rootBodyFont: Font = .body
    @AppStorage(FontLibrary.customFontEnabledStorageKey) private var isCustomFontEnabled: Bool = true
    
    enum Tab: Hashable {
        case chat
        case sessions
        case settings
    }
    
    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                ChatView()
            }
            .tabItem {
                Label("聊天", systemImage: "bubble.left.and.bubble.right.fill")
            }
            .tag(Tab.chat)
            
            NavigationStack {
                SessionListView()
            }
            .tabItem {
                Label("会话", systemImage: "list.bullet")
            }
            .tag(Tab.sessions)
            
            NavigationStack {
                SettingsView(requestedDestination: $settingsDestination)
            }
            .tabItem {
                Label("设置", systemImage: "gearshape.fill")
            }
            .tag(Tab.settings)
        }
        .environment(\.font, rootBodyFont)
        .onAppear {
            refreshRootBodyFont()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestSwitchToChatTab)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                selection = .chat
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncFontsUpdated)) { _ in
            refreshRootBodyFont()
        }
        .onChange(of: isCustomFontEnabled) { _, isEnabled in
            if isEnabled {
                FontLibrary.registerAllFontsIfNeeded()
            }
            refreshRootBodyFont()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestOpenDailyPulse)) { _ in
            openDailyPulse()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestOpenFeedback)) { _ in
            openFeedbackFromNotification()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestContinueDailyPulseChat)) { _ in
            Task { @MainActor in
                openDailyPulseContinuationIfNeeded()
            }
        }
        .alert("记忆系统需要更新", isPresented: $viewModel.showDimensionMismatchAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(viewModel.dimensionMismatchMessage)
        }
        .alert("数据库已自动恢复", isPresented: Binding(
            get: { launchRecoveryNoticeMessage != nil },
            set: { if !$0 { launchRecoveryNoticeMessage = nil } }
        )) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(launchRecoveryNoticeMessage ?? "")
        }
        // MARK: - 公告弹窗
        .sheet(isPresented: $announcementManager.shouldShowAlert) {
            if let announcement = announcementManager.currentAnnouncement {
                AnnouncementAlertView(
                    announcement: announcement,
                    onDismiss: {
                        announcementManager.dismissAlert()
                    }
                )
            }
        }
        // 启动时检查公告
        .task {
            launchRecoveryNoticeMessage = Persistence.consumeLaunchRecoveryNotice()
            await announcementManager.checkAnnouncement()
            scheduleDailyPulsePreparation(after: 1_500_000_000)
            if openDailyPulseContinuationIfNeeded() {
                return
            }
            if let pendingRoute = notificationCenter.consumePendingRoute() {
                switch pendingRoute {
                case .dailyPulse:
                    openDailyPulse()
                case .feedback:
                    openFeedback(issueNumber: notificationCenter.consumePendingFeedbackIssueNumber())
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                scheduleDailyPulsePreparation(after: 1_500_000_000)
            default:
                cancelDailyPulsePreparation()
            }
        }
    }

    private func openDailyPulse() {
        withAnimation(.easeInOut(duration: 0.2)) {
            selection = .settings
        }
        settingsDestination = nil
        DispatchQueue.main.async {
            settingsDestination = .dailyPulse
        }
    }

    private func openFeedbackFromNotification() {
        _ = notificationCenter.consumePendingRoute()
        openFeedback(issueNumber: notificationCenter.consumePendingFeedbackIssueNumber())
    }

    private func openFeedback(issueNumber: Int?) {
        withAnimation(.easeInOut(duration: 0.2)) {
            selection = .settings
        }
        settingsDestination = nil
        DispatchQueue.main.async {
            if let issueNumber,
               FeedbackService.shared.tickets.contains(where: { $0.issueNumber == issueNumber }) {
                settingsDestination = .feedbackIssue(issueNumber: issueNumber)
            } else {
                settingsDestination = .feedbackCenter
            }
        }
    }

    @discardableResult
    private func openDailyPulseContinuationIfNeeded() -> Bool {
        guard let continuation = notificationCenter.consumePendingDailyPulseContinuation() else {
            return false
        }
        viewModel.applyDailyPulseContinuation(
            sessionID: continuation.sessionID,
            prompt: continuation.prompt
        )
        withAnimation(.easeInOut(duration: 0.2)) {
            selection = .chat
        }
        return true
    }

    private func scheduleDailyPulsePreparation(after delayNanoseconds: UInt64) {
        dailyPulsePreparationTask?.cancel()
        dailyPulsePreparationTask = Task(priority: .utility) {
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            let isSceneActive = await MainActor.run { scenePhase == .active }
            guard isSceneActive else { return }
            await viewModel.prepareDailyPulseIfNeeded()
            guard !Task.isCancelled else { return }
            await viewModel.prepareMorningDailyPulseDeliveryIfNeeded()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                dailyPulsePreparationTask = nil
            }
        }
    }

    private func cancelDailyPulsePreparation() {
        dailyPulsePreparationTask?.cancel()
        dailyPulsePreparationTask = nil
    }

    private func refreshRootBodyFont() {
        let sample = "The quick brown fox 你好こんにちは"
        if let postScriptName = FontLibrary.resolvePostScriptName(for: .body, sampleText: sample) {
            rootBodyFont = .custom(postScriptName, size: 17, relativeTo: .body)
        } else {
            rootBodyFont = .body
        }
    }
}

enum ChatNavigationDestination: Hashable {
    case sessions
    case settings
}

extension Notification.Name {
    static let requestSwitchToChatTab = Notification.Name("ios.requestSwitchToChatTab")
}

extension View {
    @ViewBuilder
    func etFont(_ font: Font?) -> some View {
        if let font {
            self.font(AppFontAdapter.adaptedFont(from: font))
        } else {
            self.font(nil)
        }
    }

    @ViewBuilder
    func etFont(_ font: Font) -> some View {
        self.font(AppFontAdapter.adaptedFont(from: font))
    }
}

private enum AppFontAdapter {
    static func adaptedFont(from original: Font) -> Font {
        let descriptor = FontDescriptorInfo(font: original)
        let role = inferredRole(from: descriptor)
        let sample = sampleText(for: role)
        guard let postScriptName = FontLibrary.resolvePostScriptName(for: role, sampleText: sample) else {
            return original
        }

        var mapped = mappedFont(postScriptName: postScriptName, descriptor: descriptor)
        if descriptor.isItalic {
            mapped = mapped.italic()
        }
        if let weight = descriptor.weight {
            mapped = mapped.weight(weight)
        }
        return mapped
    }

    private static func inferredRole(from descriptor: FontDescriptorInfo) -> FontSemanticRole {
        if descriptor.isMonospaced {
            return .code
        }
        if descriptor.isItalic {
            return .emphasis
        }
        if let weight = descriptor.weight, weightStrength(weight) >= weightStrength(.semibold) {
            return .strong
        }
        return .body
    }

    private static func mappedFont(postScriptName: String, descriptor: FontDescriptorInfo) -> Font {
        if let explicitSize = descriptor.explicitSize {
            return .custom(postScriptName, size: explicitSize)
        }
        if let textStyle = descriptor.textStyle {
            return .custom(
                postScriptName,
                size: defaultPointSize(for: textStyle),
                relativeTo: textStyle
            )
        }
        return .custom(postScriptName, size: 17, relativeTo: .body)
    }

    private static func sampleText(for role: FontSemanticRole) -> String {
        switch role {
        case .body:
            return "The quick brown fox 你好こんにちは"
        case .emphasis:
            return "Emphasis 斜体预览 こんにちは"
        case .strong:
            return "Strong 粗体预览 こんにちは"
        case .code:
            return "let value = 42 // 代码"
        }
    }

    private static func defaultPointSize(for textStyle: Font.TextStyle) -> CGFloat {
        switch textStyle {
        case .largeTitle:
            return 34
        case .title:
            return 28
        case .title2:
            return 22
        case .title3:
            return 20
        case .headline:
            return 17
        case .subheadline:
            return 15
        case .body:
            return 17
        case .callout:
            return 16
        case .footnote:
            return 13
        case .caption:
            return 12
        case .caption2:
            return 11
        @unknown default:
            return 17
        }
    }

    private static func weightStrength(_ weight: Font.Weight) -> Int {
        switch weight {
        case .ultraLight:
            return 1
        case .thin:
            return 2
        case .light:
            return 3
        case .regular:
            return 4
        case .medium:
            return 5
        case .semibold:
            return 6
        case .bold:
            return 7
        case .heavy:
            return 8
        case .black:
            return 9
        default:
            return 4
        }
    }
}

private struct FontDescriptorInfo {
    let raw: String
    let lowercasedRaw: String

    init(font: Font) {
        let description = String(describing: font)
        self.raw = description
        self.lowercasedRaw = description.lowercased()
    }

    var explicitSize: CGFloat? {
        firstMatchedNumber(pattern: "size:\\s*([0-9]+(?:\\.[0-9]+)?)")
            ?? firstMatchedNumber(pattern: "size\\s*([0-9]+(?:\\.[0-9]+)?)")
    }

    var textStyle: Font.TextStyle? {
        if lowercasedRaw.contains("caption2") { return .caption2 }
        if lowercasedRaw.contains("caption") { return .caption }
        if lowercasedRaw.contains("footnote") { return .footnote }
        if lowercasedRaw.contains("callout") { return .callout }
        if lowercasedRaw.contains("subheadline") { return .subheadline }
        if lowercasedRaw.contains("headline") { return .headline }
        if lowercasedRaw.contains("title3") { return .title3 }
        if lowercasedRaw.contains("title2") { return .title2 }
        if lowercasedRaw.contains("largetitle") || lowercasedRaw.contains("large title") { return .largeTitle }
        if lowercasedRaw.contains("title") { return .title }
        if lowercasedRaw.contains("body") { return .body }
        return nil
    }

    var isItalic: Bool {
        lowercasedRaw.contains("italic")
    }

    var isMonospaced: Bool {
        lowercasedRaw.contains("monospaced") || lowercasedRaw.contains("mono")
    }

    var weight: Font.Weight? {
        if lowercasedRaw.contains("black") { return .black }
        if lowercasedRaw.contains("heavy") { return .heavy }
        if lowercasedRaw.contains("bold") { return .bold }
        if lowercasedRaw.contains("semibold") { return .semibold }
        if lowercasedRaw.contains("medium") { return .medium }
        if lowercasedRaw.contains("light") { return .light }
        if lowercasedRaw.contains("thin") { return .thin }
        if lowercasedRaw.contains("ultralight") || lowercasedRaw.contains("ultra light") { return .ultraLight }
        return nil
    }

    private func firstMatchedNumber(pattern: String) -> CGFloat? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, options: [], range: nsRange),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: raw) else {
            return nil
        }
        guard let value = Double(raw[range]) else {
            return nil
        }
        return CGFloat(value)
    }
}
