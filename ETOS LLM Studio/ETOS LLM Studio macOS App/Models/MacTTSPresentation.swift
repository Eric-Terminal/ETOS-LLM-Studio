import AVFoundation
import ETOSCore
import Foundation

struct MacTTSServiceRow: Identifiable, Sendable {
    let id: UUID
    let title: String
    let kind: String
    let ready: Bool
}

struct MacTTSVoiceRow: Identifiable, Sendable {
    let id: String
    let title: String
}

struct MacTTSPresentation: Sendable {
    let snapshot: TTSConfigurationSnapshot
    let rows: [MacTTSServiceRow]
    let servicesByID: [UUID: TTSServiceConfiguration]
    let selected: TTSServiceConfiguration?
    let guideValue: JSONValue
    let identifiers: [String]

    static func prepare(_ snapshot: TTSConfigurationSnapshot) -> Self {
        let rows = snapshot.services.map { MacTTSServiceRow(id: $0.id, title: $0.name, kind: $0.providerKind.localizedName, ready: $0.isReady) }
        return .init(snapshot: snapshot, rows: rows,
            servicesByID: Dictionary(uniqueKeysWithValues: snapshot.services.map { ($0.id, $0) }),
            selected: snapshot.selectedService, guideValue: .array(rows.map {
                .object(["id": .string($0.id.uuidString), "name": .string($0.title), "provider": .string($0.kind), "ready": .bool($0.ready)])
            }), identifiers: rows.map { $0.id.uuidString })
    }

    static func voices() -> [MacTTSVoiceRow] {
        AVSpeechSynthesisVoice.speechVoices().map { .init(id: $0.identifier, title: "\($0.name) (\($0.language))") }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

/// 只处理本次请求的开始/完成事件；历史加载、失败和取消均不能触发自动出声。
actor MacTTSAutoPlayTracker {
    private var baseline: [UUID: ChatMessage?] = [:]
    private var context: UUID?
    func reset() { baseline = [:]; context = nil }

    func process(_ event: ChatService.SessionRequestStatusEvent, context: UUID, sessionID: UUID?) -> ChatMessage? {
        if self.context != context { self.context = context; baseline = [:] }
        guard event.sessionID == sessionID else { return nil }
        switch event.status {
        case .started:
            baseline[event.sessionID] = .some(Self.latest(event.messages))
            return nil
        case .finished:
            guard let previous = baseline.removeValue(forKey: event.sessionID), let latest = Self.latest(event.messages) else { return nil }
            guard latest.id != previous?.id || latest.content != previous?.content else { return nil }
            return latest
        case .error, .cancelled:
            baseline.removeValue(forKey: event.sessionID)
            return nil
        @unknown default:
            baseline.removeValue(forKey: event.sessionID)
            return nil
        }
    }

    private static func latest(_ messages: [ChatMessage]) -> ChatMessage? {
        ChatResponseAttemptSupport.visibleMessages(from: messages).last {
            $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
