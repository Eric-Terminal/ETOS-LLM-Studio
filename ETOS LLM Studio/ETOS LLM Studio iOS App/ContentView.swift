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
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CoreText)
import CoreText
#endif

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var viewModel: ChatViewModel
    @StateObject private var announcementManager = AnnouncementManager.shared
    @StateObject private var legacyJSONMigrationManager = LegacyJSONMigrationManager.shared
    @ObservedObject private var notificationCenter = AppLocalNotificationCenter.shared
    @State private var selection: Tab = .chat
    @State private var settingsDestination: SettingsNavigationDestination?
    @State private var dailyPulsePreparationTask: Task<Void, Never>?
    @State private var launchRecoveryNoticeMessage: String?
    @State private var rootBodyFont: Font = .body
    @State private var legacyMigrationErrorMessage: String?
    @State private var isLegacyMigrationErrorPresented: Bool = false
    @AppStorage(FontLibrary.customFontEnabledStorageKey) private var isCustomFontEnabled: Bool = true
    
    enum Tab: Hashable {
        case chat
        case sessions
        case settings
    }
    
    var body: some View {
        contentWithMigrationOverlays
            // 启动时检查公告
            .task {
                await handleLaunchTasks()
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

    private var baseContent: some View {
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
            _ = isEnabled
            FontLibrary.preloadRuntimeCacheAsync(forceReload: true)
            refreshRootBodyFont()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestOpenDailyPulse)) { _ in
            openDailyPulse()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestOpenFeedback)) { _ in
            openFeedbackFromNotification()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestOpenChatSession)) { _ in
            openChatSessionFromNotification()
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
        .alert("数据库已自动恢复", isPresented: launchRecoveryNoticePresented) {
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
    }

    private var contentWithMigrationOverlays: some View {
        baseContent
            .sheet(isPresented: $legacyJSONMigrationManager.isMigrationPromptPresented) {
                NavigationStack {
                    legacyJSONMigrationPromptSheet
                }
                .interactiveDismissDisabled(true)
            }
            .sheet(isPresented: migrationInProgressPresented) {
                NavigationStack {
                    legacyJSONMigrationProgressSheet
                }
                .interactiveDismissDisabled(true)
            }
            .alert(
                "是否清理旧版 JSON 文件？",
                isPresented: $legacyJSONMigrationManager.isCleanupPromptPresented
            ) {
                Button("保留 JSON（稍后再说）", role: .cancel) {
                    legacyJSONMigrationManager.keepLegacyJSONForNow()
                }
                Button("删除 JSON") {
                    legacyJSONMigrationManager.cleanupLegacyJSONArtifacts()
                }
            } message: {
                Text("SQLite 迁移已完成。建议删除旧 JSON 文件释放空间，后续版本可能不再支持旧格式。")
            }
            .alert("迁移失败", isPresented: $isLegacyMigrationErrorPresented) {
                Button("好的", role: .cancel) {
                    legacyMigrationErrorMessage = nil
                }
            } message: {
                Text(legacyMigrationErrorMessage ?? "")
            }
            .onReceive(legacyJSONMigrationManager.$errorMessage) { message in
                guard let message, !message.isEmpty else { return }
                legacyMigrationErrorMessage = message
                isLegacyMigrationErrorPresented = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .legacyJSONMigrationDidFinish)) { _ in
                viewModel.reloadPersistedDataAfterLegacyJSONMigration()
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

    private var launchRecoveryNoticePresented: Binding<Bool> {
        Binding(
            get: { launchRecoveryNoticeMessage != nil },
            set: { newValue in
                if !newValue {
                    launchRecoveryNoticeMessage = nil
                }
            }
        )
    }

    private var migrationInProgressPresented: Binding<Bool> {
        Binding(
            get: { legacyJSONMigrationManager.isMigrating },
            set: { _ in }
        )
    }

    private func openFeedbackFromNotification() {
        _ = notificationCenter.consumePendingRoute()
        openFeedback(issueNumber: notificationCenter.consumePendingFeedbackIssueNumber())
    }

    private func openChatSessionFromNotification() {
        _ = notificationCenter.consumePendingRoute()
        guard let sessionID = notificationCenter.consumePendingChatSessionID() else { return }
        openChatSession(sessionID: sessionID)
    }

    private func openChatSession(sessionID: UUID) {
        guard viewModel.setCurrentSessionIfExists(sessionID: sessionID) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            selection = .chat
        }
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

    private func handleLaunchTasks() async {
        launchRecoveryNoticeMessage = Persistence.consumeLaunchRecoveryNotice()
        legacyJSONMigrationManager.refreshStatus()
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
            case .chatSession:
                if let sessionID = notificationCenter.consumePendingChatSessionID() {
                    openChatSession(sessionID: sessionID)
                }
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
        rootBodyFont = AppFontAdapter.adaptedFont(
            from: .body,
            sampleText: "The quick brown fox 你好こんにちは"
        )
    }

    private var legacyJSONMigrationPromptSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("检测到旧版 JSON 聊天数据")
                .etFont(.title3.bold())
            Text("为避免后续兼容风险，强烈建议现在迁移到 SQLite。迁移会在后台分批进行，不会阻塞当前界面。")
                .foregroundStyle(.secondary)

            if let status = legacyJSONMigrationManager.status {
                VStack(alignment: .leading, spacing: 6) {
                    Text("预计会话数：\(status.estimatedSessionCount)")
                    Text(String(format: "预计数据量：%.1f MB", status.estimatedLegacyMegabytes))
                }
                .etFont(.footnote)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 10) {
                Button("立即迁移（推荐）") {
                    legacyJSONMigrationManager.startMigration()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

                Button("稍后再说") {
                    legacyJSONMigrationManager.postponeMigrationPrompt()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .navigationTitle("数据迁移")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var legacyJSONMigrationProgressSheet: some View {
        VStack(spacing: 16) {
            Text("正在迁移聊天数据")
                .etFont(.title3.bold())
            if let progress = legacyJSONMigrationManager.progress {
                ProgressView(value: progress.fractionCompleted)
                    .progressViewStyle(.linear)
                Text("已处理会话 \(progress.processedSessions)/\(max(progress.totalSessions, progress.processedSessions))")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                Text("已导入消息 \(progress.importedMessages)")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                if let currentSessionName = progress.currentSessionName, !currentSessionName.isEmpty {
                    Text("当前：\(currentSessionName)")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                ProgressView()
            }
            Text("迁移完成后会再次询问是否删除旧 JSON 文件。")
                .etFont(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .navigationTitle("迁移中")
        .navigationBarTitleDisplayMode(.inline)
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

    @ViewBuilder
    func etFont(_ font: Font?, sampleText: String?) -> some View {
        if let font {
            self.font(AppFontAdapter.adaptedFont(from: font, sampleText: sampleText))
        } else {
            self.font(nil)
        }
    }

    @ViewBuilder
    func etFont(_ font: Font, sampleText: String?) -> some View {
        self.font(AppFontAdapter.adaptedFont(from: font, sampleText: sampleText))
    }
}

extension Text {
    @ViewBuilder
    func etFont(_ font: Font?) -> some View {
        if let font {
            self.font(AppFontAdapter.adaptedFont(from: font, sampleText: TextSampleExtractor.extract(from: self)))
        } else {
            self.font(nil)
        }
    }

    @ViewBuilder
    func etFont(_ font: Font) -> some View {
        self.font(AppFontAdapter.adaptedFont(from: font, sampleText: TextSampleExtractor.extract(from: self)))
    }
}

private enum TextSampleExtractor {
    private static let maxDepth = 10

    static func extract(from text: Text) -> String? {
        let strings = collectStrings(from: text, depth: 0)
        guard !strings.isEmpty else { return nil }

        var ordered: [String] = []
        var seen = Set<String>()
        for item in strings {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                ordered.append(trimmed)
            }
        }

        guard !ordered.isEmpty else { return nil }
        return ordered.joined(separator: " ")
    }

    private static func collectStrings(from value: Any, depth: Int) -> [String] {
        guard depth <= maxDepth else { return [] }

        if let string = value as? String {
            return [string]
        }

        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let childValue = mirror.children.first?.value else { return [] }
            return collectStrings(from: childValue, depth: depth + 1)
        }

        var results: [String] = []
        for child in mirror.children {
            if shouldSkip(label: child.label) {
                continue
            }
            results.append(contentsOf: collectStrings(from: child.value, depth: depth + 1))
        }
        return results
    }

    private static func shouldSkip(label: String?) -> Bool {
        switch label {
        case "modifiers", "table", "bundle", "arguments", "hasFormatting":
            return true
        default:
            return false
        }
    }
}

private enum AppFontAdapter {
    private static let cacheLock = NSLock()
    private static var adaptedFontCache: [String: Font] = [:]
    private static var adaptedFontCacheToken: String = ""

    static func adaptedFont(from original: Font, sampleText: String? = nil) -> Font {
        let rawDescriptor = String(describing: original)
        let descriptor = FontDescriptorInfo(rawDescription: rawDescriptor)
        let role = inferredRole(from: descriptor)
        let resolvedSample = resolvedSampleText(for: role, override: sampleText)
        let cacheKey = "\(rawDescriptor)|\(role.rawValue)|\(resolvedSample)"
        let cacheToken = FontLibrary.adapterCacheToken()

        if let cached = cachedFont(for: cacheKey, cacheToken: cacheToken) {
            return cached
        }

        guard let postScriptName = FontLibrary.resolvePostScriptName(for: role, sampleText: resolvedSample) else {
            storeAdaptedFont(original, for: cacheKey, cacheToken: cacheToken)
            return original
        }

        let fallbackPostScriptNames = FontLibrary.fallbackPostScriptNames(for: role)
        let mapped = mappedFont(
            postScriptName: postScriptName,
            descriptor: descriptor,
            fallbackPostScriptNames: fallbackPostScriptNames
        )
        storeAdaptedFont(mapped, for: cacheKey, cacheToken: cacheToken)
        return mapped
    }

    private static func resolvedSampleText(for role: FontSemanticRole, override sampleText: String?) -> String {
        if let sampleText {
            let trimmed = sampleText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let scalars = trimmed.unicodeScalars.filter {
                    !$0.properties.isWhitespace && $0.properties.generalCategory != .control
                }
                let prefix = String(String.UnicodeScalarView(scalars.prefix(96)))
                if !prefix.isEmpty {
                    return prefix
                }
            }
        }
        return self.sampleText(for: role)
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

    private static func mappedFont(
        postScriptName: String,
        descriptor: FontDescriptorInfo,
        fallbackPostScriptNames: [String]
    ) -> Font {
        if FontLibrary.fallbackScope == .character {
            let fallbackChain = fallbackPostScriptNames.filter {
                !$0.isEmpty && $0.caseInsensitiveCompare(postScriptName) != .orderedSame
            }
            if let cascaded = mappedFontWithCascade(
                primaryPostScriptName: postScriptName,
                fallbackPostScriptNames: fallbackChain,
                descriptor: descriptor
            ) {
                return cascaded
            }
        }

        var mapped: Font
        if let explicitSize = descriptor.explicitSize {
            mapped = .custom(postScriptName, size: explicitSize)
        } else if let textStyle = descriptor.textStyle {
            mapped = .custom(
                postScriptName,
                size: defaultPointSize(for: textStyle),
                relativeTo: textStyle
            )
        } else {
            mapped = .custom(postScriptName, size: 17, relativeTo: .body)
        }

        if descriptor.isItalic {
            mapped = mapped.italic()
        }
        if let weight = descriptor.weight {
            mapped = mapped.weight(weight)
        }
        return mapped
    }

    private static func resolvedPointSize(for descriptor: FontDescriptorInfo) -> CGFloat {
        if let explicitSize = descriptor.explicitSize {
            return explicitSize
        }
        if let textStyle = descriptor.textStyle {
            return defaultPointSize(for: textStyle)
        }
        return 17
    }

    private static func mappedFontWithCascade(
        primaryPostScriptName: String,
        fallbackPostScriptNames: [String],
        descriptor: FontDescriptorInfo
    ) -> Font? {
#if canImport(UIKit) && canImport(CoreText)
        guard !fallbackPostScriptNames.isEmpty else { return nil }
        let pointSize = resolvedPointSize(for: descriptor)
        guard UIFont(name: primaryPostScriptName, size: pointSize) != nil else { return nil }

        let cascadeDescriptors = fallbackPostScriptNames.compactMap { candidate -> CTFontDescriptor? in
            guard UIFont(name: candidate, size: pointSize) != nil else { return nil }
            return CTFontDescriptorCreateWithNameAndSize(candidate as CFString, pointSize)
        }
        guard !cascadeDescriptors.isEmpty else { return nil }

        let cascadeKey = UIFontDescriptor.AttributeName(rawValue: kCTFontCascadeListAttribute as String)
        var descriptorAttributes: [UIFontDescriptor.AttributeName: Any] = [
            .name: primaryPostScriptName,
            .size: pointSize,
            cascadeKey: cascadeDescriptors
        ]

        if let weight = descriptor.weight {
            descriptorAttributes[.traits] = [
                UIFontDescriptor.TraitKey.weight: uiFontWeightValue(weight)
            ]
        }

        var uiFontDescriptor = UIFontDescriptor(fontAttributes: descriptorAttributes)
        if descriptor.isItalic,
           let italicDescriptor = uiFontDescriptor.withSymbolicTraits(.traitItalic) {
            uiFontDescriptor = italicDescriptor
        }

        let uiFont = UIFont(descriptor: uiFontDescriptor, size: pointSize)
        return Font(uiFont)
#else
        _ = primaryPostScriptName
        _ = fallbackPostScriptNames
        _ = descriptor
        return nil
#endif
    }

    private static func uiFontWeightValue(_ weight: Font.Weight) -> CGFloat {
        switch weight {
        case .ultraLight:
            return UIFont.Weight.ultraLight.rawValue
        case .thin:
            return UIFont.Weight.thin.rawValue
        case .light:
            return UIFont.Weight.light.rawValue
        case .regular:
            return UIFont.Weight.regular.rawValue
        case .medium:
            return UIFont.Weight.medium.rawValue
        case .semibold:
            return UIFont.Weight.semibold.rawValue
        case .bold:
            return UIFont.Weight.bold.rawValue
        case .heavy:
            return UIFont.Weight.heavy.rawValue
        case .black:
            return UIFont.Weight.black.rawValue
        default:
            return UIFont.Weight.regular.rawValue
        }
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

    private static func cachedFont(for key: String, cacheToken: String) -> Font? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if adaptedFontCacheToken != cacheToken {
            adaptedFontCacheToken = cacheToken
            adaptedFontCache.removeAll(keepingCapacity: true)
        }
        return adaptedFontCache[key]
    }

    private static func storeAdaptedFont(_ font: Font, for key: String, cacheToken: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if adaptedFontCacheToken != cacheToken {
            adaptedFontCacheToken = cacheToken
            adaptedFontCache.removeAll(keepingCapacity: true)
        }
        adaptedFontCache[key] = font
    }
}

private struct FontDescriptorInfo {
    let raw: String
    let lowercasedRaw: String

    init(rawDescription: String) {
        self.raw = rawDescription
        self.lowercasedRaw = rawDescription.lowercased()
    }

    var explicitSize: CGFloat? {
        firstMatchedNumber(after: "size:")
            ?? firstMatchedNumber(after: "size ")
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
        if lowercasedRaw.contains("semibold") { return .semibold }
        if lowercasedRaw.contains("bold") { return .bold }
        if lowercasedRaw.contains("medium") { return .medium }
        if lowercasedRaw.contains("light") { return .light }
        if lowercasedRaw.contains("thin") { return .thin }
        if lowercasedRaw.contains("ultralight") || lowercasedRaw.contains("ultra light") { return .ultraLight }
        return nil
    }

    private func firstMatchedNumber(after marker: String) -> CGFloat? {
        guard let markerRange = lowercasedRaw.range(of: marker) else { return nil }
        var cursor = markerRange.upperBound
        var digits = ""
        var hasStarted = false

        while cursor < lowercasedRaw.endIndex {
            let character = lowercasedRaw[cursor]
            if character.isNumber || character == "." {
                digits.append(character)
                hasStarted = true
            } else if hasStarted {
                break
            }
            cursor = lowercasedRaw.index(after: cursor)
        }

        guard !digits.isEmpty, let value = Double(digits) else { return nil }
        return CGFloat(value)
    }
}
