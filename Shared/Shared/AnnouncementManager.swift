// ============================================================================
// AnnouncementManager.swift
// ============================================================================
// ETOS LLM Studio 公告通知管理器 (Shared)
//
// 功能特性:
// - 从远程服务器获取公告信息
// - 根据公告类型(info/warning/blocking)处理显示逻辑
// - 使用 AppStorage 持久化通知状态
// - 支持 iOS 和 watchOS
// ============================================================================

import Foundation
import SwiftUI
import Combine
import os.log

private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "AnnouncementManager")

// MARK: - 数据模型

/// 公告类型
public enum AnnouncementType: String, Codable {
    case info = "info"           // 静默显示在设置里
    case warning = "warning"     // 首次显式通知
    case blocking = "blocking"   // 每次启动都显式通知
}

/// 支持的语言选项
/// 用于 GitOps 远程配置的 language 字段
public enum AnnouncementLanguage: String, CaseIterable {
    // 主要语言
    case zh = "zh"           // 中文（匹配所有中文变体）
    case zhHans = "zh-Hans"  // 简体中文
    case zhHant = "zh-Hant"  // 繁体中文
    case en = "en"           // 英语
    case ja = "ja"           // 日语
    case ko = "ko"           // 韩语
    case fr = "fr"           // 法语
    case de = "de"           // 德语
    case es = "es"           // 西班牙语
    case pt = "pt"           // 葡萄牙语
    case it = "it"           // 意大利语
    case ru = "ru"           // 俄语
    case ar = "ar"           // 阿拉伯语
    case th = "th"           // 泰语
    case vi = "vi"           // 越南语
    case id = "id"           // 印尼语
    case ms = "ms"           // 马来语
    case tr = "tr"           // 土耳其语
    case pl = "pl"           // 波兰语
    case nl = "nl"           // 荷兰语
    case uk = "uk"           // 乌克兰语
    case he = "he"           // 希伯来语
    case hi = "hi"           // 印地语
    
    public var displayName: String {
        switch self {
        case .zh: return "中文 (Chinese)"
        case .zhHans: return "简体中文 (Simplified Chinese)"
        case .zhHant: return "繁體中文 (Traditional Chinese)"
        case .en: return "English"
        case .ja: return "日本語 (Japanese)"
        case .ko: return "한국어 (Korean)"
        case .fr: return "Français (French)"
        case .de: return "Deutsch (German)"
        case .es: return "Español (Spanish)"
        case .pt: return "Português (Portuguese)"
        case .it: return "Italiano (Italian)"
        case .ru: return "Русский (Russian)"
        case .ar: return "العربية (Arabic)"
        case .th: return "ไทย (Thai)"
        case .vi: return "Tiếng Việt (Vietnamese)"
        case .id: return "Bahasa Indonesia"
        case .ms: return "Bahasa Melayu (Malay)"
        case .tr: return "Türkçe (Turkish)"
        case .pl: return "Polski (Polish)"
        case .nl: return "Nederlands (Dutch)"
        case .uk: return "Українська (Ukrainian)"
        case .he: return "עברית (Hebrew)"
        case .hi: return "हिन्दी (Hindi)"
        }
    }
}

/// 公告数据模型
public struct Announcement: Codable, Identifiable {
    public let id: Int                  // 唯一标识，用日期+序号
    public let type: AnnouncementType   // 通知类型
    public let minBuild: String?        // 最低版本要求
    public let maxBuild: String?        // 最高版本要求
    public let language: String?        // 目标语言 (e.g., "zh-Hans", "en", nil = 所有)
    public let platform: String?        // 目标平台 (e.g., "iOS", "watchOS", nil = 所有)
    public let title: String            // 标题
    public let body: String             // 正文内容
    
    enum CodingKeys: String, CodingKey {
        case id
        case type
        case minBuild = "min_build"
        case maxBuild = "max_build"
        case language
        case platform
        case title
        case body
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decode(Int.self, forKey: .id)
        type = try container.decode(AnnouncementType.self, forKey: .type)
        minBuild = try container.decodeIfPresent(String.self, forKey: .minBuild)
        maxBuild = try container.decodeIfPresent(String.self, forKey: .maxBuild)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        platform = try container.decodeIfPresent(String.self, forKey: .platform)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
    }
}

// MARK: - 公告管理器

@MainActor
public class AnnouncementManager: ObservableObject {
    
    // MARK: - 单例
    
    public static let shared = AnnouncementManager()
    
    // MARK: - Published 属性
    
    /// 当前公告列表（用于UI显示，可能有多个）
    @Published public var currentAnnouncements: [Announcement] = []
    
    /// 是否应该显示弹窗通知
    @Published public var shouldShowAlert: Bool = false
    
    /// 是否正在加载
    @Published public var isLoading: Bool = false
    
    // MARK: - AppStorage 持久化
    
    /// 上次显示的通知ID
    @AppStorage("lastAnnouncementId") private var lastAnnouncementId: Int = 0
    
    /// 是否隐藏静默通知区域
    @AppStorage("hideAnnouncementSection") private var hideAnnouncementSection: Bool = false
    
    // MARK: - 私有属性
    
    private let announcementURL = URL(string: "https://notify.els.ericterminal.com/announcement.json")!
    private let timeoutInterval: TimeInterval = 10.0
    
    // MARK: - 计算属性
    
    /// 是否应该在设置中显示通知Section
    public var shouldShowInSettings: Bool {
        return !currentAnnouncements.isEmpty && !hideAnnouncementSection
    }
    
    /// 便捷属性：获取第一个公告（向后兼容）
    public var currentAnnouncement: Announcement? {
        return currentAnnouncements.first
    }
    
    // MARK: - 初始化
    
    private init() {
        logger.info("AnnouncementManager initialized")
    }
    
    // MARK: - 公开方法
    
    /// 检查并加载公告
    /// 在App启动时调用
    public func checkAnnouncement() async {
        logger.info("开始检查公告...")
        isLoading = true
        
        defer {
            isLoading = false
        }
        
        do {
            let announcements = try await fetchAnnouncements()
            if !announcements.isEmpty {
                await processAnnouncements(announcements)
            } else {
                logger.info("没有适用于当前设备的公告")
                currentAnnouncements = []
            }
        } catch {
            logger.error("获取公告失败: \(error.localizedDescription)")
            // 网络失败时不修改已有的AppStorage设置
            // 也不显示任何通知
            currentAnnouncements = []
        }
    }
    
    /// 用户点击"不再显示"后调用
    public func hideCurrentAnnouncement() {
        hideAnnouncementSection = true
        logger.info("用户选择隐藏当前公告")
    }
    
    /// 关闭弹窗
    public func dismissAlert() {
        shouldShowAlert = false
    }
    
    // MARK: - 私有方法
    
    /// 从服务器获取公告
    /// 支持多个公告，返回筛选后的公告数组
    private func fetchAnnouncements() async throws -> [Announcement] {
        logger.info("正在从服务器获取公告...")
        
        var request = URLRequest(url: announcementURL)
        request.timeoutInterval = timeoutInterval
        request.cachePolicy = .reloadIgnoringLocalCacheData
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AnnouncementError.invalidResponse
        }
        
        let decoder = JSONDecoder()
        
        // 尝试解析为数组
        if let announcements = try? decoder.decode([Announcement].self, from: data) {
            logger.info("获取到 \(announcements.count) 个公告条目")
            return selectAnnouncements(from: announcements)
        }
        
        // 后向兼容：尝试解析为单个对象
        if let announcement = try? decoder.decode(Announcement.self, from: data) {
            logger.info("成功获取单个公告: ID=\(announcement.id), Type=\(announcement.type.rawValue)")
            // 检查是否兼容
            if isVersionCompatible(announcement) && isPlatformCompatible(announcement) {
                return [announcement]
            }
            return []
        }
        
        throw AnnouncementError.decodingFailed
    }
    
    /// 从多个公告中选择要显示的公告
    /// 逻辑：
    /// 1. 按 ID 分组
    /// 2. 对于每个 ID：如果所有条目都没有语言和平台限制，则全部返回；否则选择最佳匹配的一个
    private func selectAnnouncements(from announcements: [Announcement]) -> [Announcement] {
        guard !announcements.isEmpty else { return [] }
        
        // 先过滤出版本和平台兼容的公告
        let compatible = announcements.filter { isVersionCompatible($0) && isPlatformCompatible($0) }
        guard !compatible.isEmpty else { return [] }
        
        // 按 ID 分组
        let grouped = Dictionary(grouping: compatible) { $0.id }
        
        var result: [Announcement] = []
        
        for (id, group) in grouped.sorted(by: { $0.key > $1.key }) { // ID 降序，新的在前
            // 检查这组公告是否都没有语言和平台限制
            let allUnrestricted = group.allSatisfy { announcement in
                let noLanguage = announcement.language == nil || announcement.language?.isEmpty == true
                let noPlatform = announcement.platform == nil || announcement.platform?.isEmpty == true
                return noLanguage && noPlatform
            }
            
            if allUnrestricted {
                // 如果都没有限制，全部添加
                logger.info("ID \(id) 的 \(group.count) 个公告都无限制，全部显示")
                result.append(contentsOf: group)
            } else {
                // 否则选择最佳匹配的一个
                if let best = selectBestFromGroup(group) {
                    logger.info("ID \(id) 选择最佳匹配公告")
                    result.append(best)
                }
            }
        }
        
        return result
    }
    
    /// 从一组同 ID 的公告中选择最佳匹配
    /// 优先级：精确语言匹配 > 语言前缀匹配 > 无语言限制 > 英文 > 第一个
    private func selectBestFromGroup(_ group: [Announcement]) -> Announcement? {
        guard !group.isEmpty else { return nil }
        
        let deviceLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        let deviceFullLanguage = Locale.current.identifier // e.g., "zh-Hans_CN"
        
        // 第一优先级：精确匹配语言代码 (e.g., "zh-Hans")
        for announcement in group {
            if let lang = announcement.language, !lang.isEmpty {
                if deviceFullLanguage.hasPrefix(lang.replacingOccurrences(of: "-", with: "_")) ||
                   deviceFullLanguage.hasPrefix(lang) {
                    logger.info("精确匹配语言: \(lang)")
                    return announcement
                }
            }
        }
        
        // 第二优先级：前缀匹配 (e.g., "zh" 匹配 "zh-Hans")
        for announcement in group {
            if let lang = announcement.language, !lang.isEmpty {
                if deviceLanguage.hasPrefix(lang) || lang.hasPrefix(deviceLanguage) {
                    logger.info("前缀匹配语言: \(lang)")
                    return announcement
                }
            }
        }
        
        // 第三优先级：无语言限制的公告
        for announcement in group {
            if announcement.language == nil || announcement.language?.isEmpty == true {
                logger.info("使用无语言限制的公告")
                return announcement
            }
        }
        
        // 第四优先级：英文版本
        for announcement in group {
            if announcement.language == "en" {
                logger.info("回退到英文版本")
                return announcement
            }
        }
        
        logger.info("使用第一个公告")
        return group.first
    }
    
    /// 检查平台兼容性（仅检查平台，不检查语言）
    private func isPlatformCompatible(_ announcement: Announcement) -> Bool {
        guard let targetPlatform = announcement.platform, !targetPlatform.isEmpty else {
            return true // 无平台限制
        }
        
        #if os(iOS)
        let currentPlatform = "iOS"
        #elseif os(watchOS)
        let currentPlatform = "watchOS"
        #else
        let currentPlatform = "unknown"
        #endif
        
        return targetPlatform.lowercased() == currentPlatform.lowercased()
    }
    
    /// 处理获取到的公告数组
    private func processAnnouncements(_ announcements: [Announcement]) async {
        guard !announcements.isEmpty else { return }
        
        // 获取最高优先级的公告（用于判断是否新公告和弹窗类型）
        // 按 ID 降序排列，取最大的
        let maxId = announcements.map { $0.id }.max() ?? 0
        let isNewAnnouncement = maxId != lastAnnouncementId
        
        // 如果是新公告，重置隐藏状态
        if isNewAnnouncement {
            hideAnnouncementSection = false
            logger.info("检测到新公告 (最高ID: \(maxId))，重置隐藏状态")
        }
        
        // 设置当前公告列表（用于静默显示）
        currentAnnouncements = announcements
        logger.info("设置 \(announcements.count) 个公告用于显示")
        
        // 根据公告中最高优先级的类型决定是否显示弹窗
        // 优先级：blocking > warning > info
        let hasBlocking = announcements.contains { $0.type == .blocking }
        let hasWarning = announcements.contains { $0.type == .warning }
        
        if hasBlocking {
            // blocking 类型每次都弹窗
            shouldShowAlert = true
            logger.info("包含 Blocking 类型公告，强制显示弹窗")
        } else if hasWarning && isNewAnnouncement {
            // warning 类型仅在新公告时弹窗
            shouldShowAlert = true
            logger.info("包含 Warning 类型新公告，显示弹窗")
        } else {
            // info 类型只在设置中静默显示，不弹窗
            logger.info("公告静默显示")
        }
        
        // 更新本地存储的ID（使用最大ID）
        lastAnnouncementId = maxId
        logger.info("已更新本地公告ID为: \(maxId)")
    }
    
    /// 检查版本兼容性
    private func isVersionCompatible(_ announcement: Announcement) -> Bool {
        // 获取当前App的Build版本号
        guard let buildString = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let currentBuild = Int(buildString) else {
            logger.warning("无法获取当前Build版本号")
            return true // 如果无法获取版本号，默认显示
        }
        
        // 检查最低版本要求
        if let minBuildString = announcement.minBuild,
           let minBuild = Int(minBuildString),
           currentBuild < minBuild {
            logger.info("当前版本 \(currentBuild) 低于最低要求 \(minBuild)")
            return false
        }
        
        // 检查最高版本要求
        if let maxBuildString = announcement.maxBuild,
           let maxBuild = Int(maxBuildString),
           currentBuild > maxBuild {
            logger.info("当前版本 \(currentBuild) 高于最高限制 \(maxBuild)")
            return false
        }
        
        return true
    }
}

// MARK: - 错误类型

public enum AnnouncementError: Error, LocalizedError {
    case invalidResponse
    case decodingFailed
    case timeout
    
    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器响应无效"
        case .decodingFailed:
            return "数据解析失败"
        case .timeout:
            return "请求超时"
        }
    }
}
