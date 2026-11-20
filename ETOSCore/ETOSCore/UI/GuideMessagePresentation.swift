import Combine
import SwiftUI

public struct GuideMessageTools: Equatable, Sendable {
    public var destinations: [GuideNavigationDestination] = []
    public var pendingIDs: Set<String> = []
    public var hasPendingRead = false

    public init() {}

    public func awaits(_ id: String?) -> Bool {
        id.map(pendingIDs.contains) ?? false
    }

    public func isVisible(active: Bool, awaiting id: String?) -> Bool {
        !destinations.isEmpty || awaits(id) || (active && hasPendingRead)
    }
}

@MainActor
public final class GuideMessagePresentation: ObservableObject {
    @Published public private(set) var tools: [UUID: GuideMessageTools] = [:]

    public func isWaitingForReply(_ controller: GuideConversationController) -> Bool {
        guard controller.isResponding, controller.streamingContent.isEmpty else { return false }
        guard let last = controller.messages.last else { return true }
        return tools[last.id]?.hasPendingRead != true
    }

    public init(controller: GuideConversationController) {
        let queue = DispatchQueue(label: "studio.etos.guide.message-buttons", qos: .userInitiated)
        // 流式正文有独立的 publisher。只处理消息终态、工具增量和来源页切换。
        typealias Entry = (calls: [InternalToolCall], tools: GuideMessageTools)
        controller.$messages.combineLatest(GuideContextCoordinator.shared.$activePage)
            .receive(on: queue)
            .scan([UUID: Entry]()) { @Sendable previous, update in
                var next: [UUID: Entry] = [:]
                let pageReads = update.1?.tools.filter { $0.access == .read }.map { $0.definition.name } ?? []
                let reads = Set(GuideToolCatalog.knowledgeDefinitions.map(\.name) + pageReads)
                for message in update.0 where message.role == .assistant && !message.toolCalls.isEmpty {
                    if let entry = previous[message.id], entry.calls == message.toolCalls, entry.tools.pendingIDs.isEmpty {
                        next[message.id] = entry
                        continue
                    }
                    var tools = GuideMessageTools()
                    tools.destinations = GuideNavigationSupport.suggestedDestinations(in: message)
                    for call in message.toolCalls where call.resultDisposition == nil {
                        tools.pendingIDs.insert(call.id)
                        if reads.contains(call.toolName) { tools.hasPendingRead = true }
                    }
                    next[message.id] = (message.toolCalls, tools)
                }
                return next
            }
            .map { @Sendable in $0.mapValues { $0.tools } }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$tools)
    }
}

public struct GuideToolStatusLine: View {
    private let tools: GuideMessageTools
    private let active: Bool
    private let awaiting: String?

    public init(_ tools: GuideMessageTools, active: Bool, awaiting: String?) {
        self.tools = tools
        self.active = active
        self.awaiting = awaiting
    }

    public var body: some View {
        if tools.awaits(awaiting) {
            Text(NSLocalizedString("等待你在下方确认修改", value: "Review the changes below to confirm.", comment: "等待用户确认"))
                .font(.caption).foregroundStyle(.orange)
        } else if active && tools.hasPendingRead {
            HStack {
                ProgressView().controlSize(.mini)
                Text(NSLocalizedString("正在查阅功能说明…", value: "Looking up how this works…", comment: "助手查阅状态"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

public struct GuideDestinationButtons: View {
    private let destinations: [GuideNavigationDestination]
    public init(_ destinations: [GuideNavigationDestination]) { self.destinations = destinations }

    public var body: some View {
        ForEach(destinations) { destination in
            Button {
                GuideNavigationCoordinator.shared.request(destination)
            } label: {
                HStack {
                    Image(systemName: destination.systemImage)
                    Text(String(format: NSLocalizedString("前往：%@", value: "Open %@", comment: "向导设置跳转按钮"), destination.localizedTitle))
                        .multilineTextAlignment(.leading)
                    Image(systemName: "chevron.right").imageScale(.small)
                }
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small).tint(.accentColor)
        }
    }
}
