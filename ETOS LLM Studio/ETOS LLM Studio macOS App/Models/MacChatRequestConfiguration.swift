import ETOSCore
import Foundation

struct MacChatRequestConfiguration {
    let temperature: Double
    let topP: Double
    let systemPrompt: String
    let historyLimit: Int
    let streaming: Bool
    let memory: Bool
    let memoryWrite: Bool
    let memoryRetrieval: Bool
    let systemTime: Bool
    let timePosition: SystemTimeInjectionPosition
    let timeLandmark: Bool
    let timeLandmarkMinutes: Int
    let speedMetrics: Bool
    let enhancedPrompt: String?

    @MainActor
    init(_ configuration: AppConfigStore, session: ChatSession) {
        temperature = configuration.aiTemperature
        topP = configuration.aiTopP
        // Core 会单独拼入会话提示词；此处只传全局提示词，避免覆盖或重复注入。
        systemPrompt = configuration.systemPrompt
        historyLimit = configuration.maxChatHistory
        streaming = configuration.enableStreaming
        memory = configuration.enableMemory
        memoryWrite = configuration.enableMemoryWrite
        memoryRetrieval = configuration.enableMemoryActiveRetrieval
        systemTime = configuration.includeSystemTimeInPrompt
        timePosition = SystemTimeInjectionPosition(rawValue: configuration.systemTimeInjectionPosition) ?? .front
        timeLandmark = configuration.enablePeriodicTimeLandmark
        timeLandmarkMinutes = configuration.periodicTimeLandmarkIntervalMinutes
        speedMetrics = configuration.enableResponseSpeedMetrics
        enhancedPrompt = session.enhancedPrompt
    }

    func send(_ content: String, attachments: [MacComposerAttachment] = [], audioAttachment: AudioAttachment? = nil, through service: ChatService, sessionID: UUID) async {
        await service.sendAndProcessMessage(
            content: content, aiTemperature: temperature, aiTopP: topP,
            systemPrompt: systemPrompt, maxChatHistory: historyLimit,
            enableStreaming: streaming, enhancedPrompt: enhancedPrompt,
            enableMemory: memory, enableMemoryWrite: memoryWrite, enableMemoryActiveRetrieval: memoryRetrieval,
            includeSystemTime: systemTime, systemTimeInjectionPosition: timePosition,
            enablePeriodicTimeLandmark: timeLandmark, periodicTimeLandmarkIntervalMinutes: timeLandmarkMinutes,
            enableResponseSpeedMetrics: speedMetrics, audioAttachment: audioAttachment, imageAttachments: attachments.compactMap(\.image),
            fileAttachments: attachments.compactMap(\.file), targetSessionID: sessionID
        )
    }

    func retry(_ message: ChatMessage, through service: ChatService, sessionID: UUID, prefill: Bool) async {
        await service.retryMessage(
            message, aiTemperature: temperature, aiTopP: topP, systemPrompt: systemPrompt,
            maxChatHistory: historyLimit, enableStreaming: streaming, enhancedPrompt: enhancedPrompt,
            enableMemory: memory, enableMemoryWrite: memoryWrite, enableMemoryActiveRetrieval: memoryRetrieval,
            includeSystemTime: systemTime, systemTimeInjectionPosition: timePosition,
            enablePeriodicTimeLandmark: timeLandmark, periodicTimeLandmarkIntervalMinutes: timeLandmarkMinutes,
            enableResponseSpeedMetrics: speedMetrics, prefill: prefill, targetSessionID: sessionID
        )
    }
}
