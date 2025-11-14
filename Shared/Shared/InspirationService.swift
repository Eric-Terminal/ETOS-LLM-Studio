// ============================================================================
// InspirationService.swift
// ============================================================================
// 用于从在线一言服务获取名言，供 iOS 与 watchOS 共享使用
// ============================================================================

import Foundation

public final class InspirationService {
    public static let shared = InspirationService()
    
    private let session: URLSession
    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config)
    }
    
    public struct Quote: Equatable, Hashable {
        public let text: String
        public let source: String?
        
        public var displayText: String {
            guard let source, !source.isEmpty else { return text }
            return "\(text)\n—— \(source)"
        }
    }
    
    public let localQuotes: [String] = [
        "正在翻阅星际备忘录…",
        "Never gonna give you up.",
        "耐心一点，智慧正在碰撞火花。",
        "等待是另一种输入。",
        "准备好，一句名言可能改变答案。",
        "量子猫正在排列提示词。",
        "思绪 loading 中，别眨眼。"
    ]
    
    private struct HitokotoResponse: Decodable {
        let hitokoto: String
        let from: String?
        let fromWho: String?
        
        enum CodingKeys: String, CodingKey {
            case hitokoto
            case from
            case fromWho = "from_who"
        }
    }
    
    // MARK: - Public API
    
    public func fetchRandomQuote() async -> Quote? {
        guard let url = URL(string: "https://v1.hitokoto.cn/?c=a&c=b&c=c&c=d&encode=json") else {
            return nil
        }
        
        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }
            
            let decoder = JSONDecoder()
            let payload = try decoder.decode(HitokotoResponse.self, from: data)
            let cleaned = payload.hitokoto.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            
            let attribution = Self.buildAttribution(from: payload.from, author: payload.fromWho)
            return Quote(text: cleaned, source: attribution)
        } catch {
            return nil
        }
    }
    
    private static func buildAttribution(from origin: String?, author: String?) -> String? {
        let trimmedOrigin = origin?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedAuthor = author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        switch (trimmedOrigin.isEmpty, trimmedAuthor.isEmpty) {
        case (true, true):
            return nil
        case (false, true):
            return trimmedOrigin
        case (true, false):
            return trimmedAuthor
        default:
            return "\(trimmedAuthor) · \(trimmedOrigin)"
        }
    }
}
