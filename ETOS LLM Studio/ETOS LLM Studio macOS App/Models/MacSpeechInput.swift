import ETOSCore
import Foundation

// Core 的 RunnableModel 尚未声明 Sendable；这里只传递不可变的配置值，不跨线程访问其运行态存储。
struct MacSpeechModelRow: Identifiable, @unchecked Sendable {
    let model: RunnableModel
    let title: String
    let subtitle: String
    var id: String { model.id }
}

struct MacSpeechModelCatalog: @unchecked Sendable {
    let rows: [MacSpeechModelRow]
    let byID: [String: RunnableModel]
    let identifiers: [String]
    let guideValue: JSONValue

    static let empty = Self(rows: [], byID: [:], identifiers: [""], guideValue: .array([]))

    static func prepare(_ models: [RunnableModel]) -> Self {
        let rows = models.map { model in
            MacSpeechModelRow(model: model, title: model.model.displayName, subtitle: model.provider.name)
        }
        return Self(rows: rows, byID: Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) }),
            identifiers: [""] + models.map(\.id), guideValue: .array(rows.map {
                .dictionary(["id": .string($0.id), "name": .string($0.title), "provider": .string($0.subtitle)])
            }))
    }

    func resolve(_ identifier: String) -> RunnableModel? { byID[identifier] ?? rows.first?.model }
}

/// 录音固定来源会话、输入框代次与模式；结果只能由原来的草稿接收。
struct MacSpeechInputSource: Identifiable, @unchecked Sendable {
    let id = UUID()
    let sessionID: UUID
    let composerContextID: UUID
    let format: AudioRecordingFormat
    let model: RunnableModel?
    var sendsAudio: Bool { model == nil }
}

enum MacSpeechInputResult: Sendable {
    case audio(AudioAttachment)
    case text(String)
}
