// ============================================================================
// TTSServiceAdvancedConfiguration.swift
// ============================================================================
// ETOS LLM Studio
//
// 承载各家 TTS 协议无法归入名称、地址、密钥、模型和音色的专属参数。
// ============================================================================

import Foundation

public struct TTSServiceAdvancedConfiguration: Codable, Hashable, Sendable {
    public var speed: Double
    public var volume: Double
    public var pitch: Int
    public var sampleRate: Int
    public var bitrate: Int
    public var channels: Int
    public var instruction: String
    public var workspaceID: String
    public var region: String
    public var languageBoost: String
    public var subtitleEnabled: Bool
    public var pronunciationDictionary: [String]
    public var temperature: Double
    public var topP: Double
    public var latency: String
    public var optimizeTextPreview: Bool

    public init(
        speed: Double = 1,
        volume: Double = 1,
        pitch: Int = 0,
        sampleRate: Int = 24_000,
        bitrate: Int = 128_000,
        channels: Int = 1,
        instruction: String = "",
        workspaceID: String = "",
        region: String = "cn-beijing",
        languageBoost: String = "",
        subtitleEnabled: Bool = false,
        pronunciationDictionary: [String] = [],
        temperature: Double = 0.7,
        topP: Double = 0.7,
        latency: String = "normal",
        optimizeTextPreview: Bool = false
    ) {
        self.speed = speed
        self.volume = volume
        self.pitch = pitch
        self.sampleRate = sampleRate
        self.bitrate = bitrate
        self.channels = channels
        self.instruction = instruction
        self.workspaceID = workspaceID
        self.region = region
        self.languageBoost = languageBoost
        self.subtitleEnabled = subtitleEnabled
        self.pronunciationDictionary = pronunciationDictionary
        self.temperature = temperature
        self.topP = topP
        self.latency = latency
        self.optimizeTextPreview = optimizeTextPreview
    }

    public var normalized: TTSServiceAdvancedConfiguration {
        var result = self
        result.speed = min(max(speed, 0.5), 2)
        result.volume = min(max(volume, 0), 10)
        result.pitch = min(max(pitch, -12), 12)
        result.sampleRate = max(sampleRate, 8_000)
        result.bitrate = max(bitrate, 32_000)
        result.channels = min(max(channels, 1), 2)
        result.instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        result.workspaceID = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        result.region = region.trimmingCharacters(in: .whitespacesAndNewlines)
        result.languageBoost = languageBoost.trimmingCharacters(in: .whitespacesAndNewlines)
        result.pronunciationDictionary = pronunciationDictionary.compactMap { item in
            let normalized = item.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }
        result.temperature = min(max(temperature, 0), 1)
        result.topP = min(max(topP, 0), 1)
        result.latency = latency.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
}
