import SwiftUI

/// 头像、名称和可选时间组成气泡外的标题；不随正文长度或操作栏位置变化。
public struct ChatAvatarHeader: View {
    @ObservedObject private var model = ChatAvatarModel.shared
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @State private var timestamp = ""
    private let role: MessageRole
    private let sessionID: UUID?
    private let date: Date?
    private let outgoing: Bool

    public init(role: MessageRole, sessionID: UUID?, date: Date?, outgoing: Bool) {
        self.role = role
        self.sessionID = sessionID
        self.date = date
        self.outgoing = outgoing
    }

    public var body: some View {
        HStack {
            if !outgoing { ChatMessageAvatar(role: role, sessionID: sessionID) }
            VStack(alignment: outgoing ? .trailing : .leading) {
                Text(model.displayName(role: role, sessionID: sessionID))
                    .font(.caption).fontWeight(.medium).lineLimit(1)
                if model.layout.showsTimestamp, !timestamp.isEmpty {
                    Text(timestamp).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if outgoing { ChatMessageAvatar(role: role, sessionID: sessionID) }
        }
        .task(id: "\(date?.timeIntervalSince1970 ?? 0)|\(locale.identifier)|\(timeZone.identifier)|\(model.layout.showsTimestamp)") {
            timestamp = ""
            guard model.layout.showsTimestamp, let date else { return }
            let locale = locale, timeZone = timeZone
            let formatted = await Task.detached {
                let formatter = DateFormatter()
                formatter.locale = locale
                formatter.timeZone = timeZone
                formatter.dateStyle = .short
                formatter.timeStyle = .medium
                return formatter.string(from: date)
            }.value
            guard !Task.isCancelled else { return }
            timestamp = formatted
        }
    }
}
