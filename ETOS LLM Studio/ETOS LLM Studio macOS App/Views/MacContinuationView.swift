import ETOSCore
import SwiftUI

@MainActor
struct MacContinuationHeader: View {
    @ObservedObject var model: MacContextCompressionModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    var body: some View {
        if let state = model.presentation {
            if state.context != nil {
                Button { model.showsDetails = true } label: {
                    Label(NSLocalizedString("续聊上下文", comment: ""), systemImage: "rectangle.compress.vertical")
                }.buttonStyle(.borderless).disabled(!workspace.canManageLocalModels)
            }
            if let link = state.sourceLink { MacContinuationLinkView(model: model, link: link) }
            ForEach(state.unanchoredLinks) { MacContinuationLinkView(model: model, link: $0) }
        }
    }
}

@MainActor
struct MacContinuationMessageLinks: View {
    @ObservedObject var model: MacContextCompressionModel
    let messageID: UUID
    var body: some View {
        ForEach(model.presentation?.outgoingByMessageID[messageID] ?? []) {
            MacContinuationLinkView(model: model, link: $0)
        }
    }
}

@MainActor
private struct MacContinuationLinkView: View {
    @ObservedObject var model: MacContextCompressionModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    let link: MacContinuationPresentation.Link
    @State private var confirmsRemoval = false
    var body: some View {
        HStack {
            Button { model.open(link) } label: {
                Label(link.title, systemImage: link.isAvailable ? "arrow.triangle.branch" : "trash")
                    .font(.footnote).foregroundStyle(.secondary)
            }.disabled(!model.canEdit || !link.isAvailable)
            Menu {
                Button(NSLocalizedString("移除跳转入口", comment: ""), role: .destructive) { confirmsRemoval = true }
            } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel(NSLocalizedString("移除跳转入口", comment: ""))
                .disabled(!model.canEdit || model.isPreparing)
        }
        .buttonStyle(.borderless)
        .disabled(!workspace.canManageLocalModels)
        .confirmationDialog(NSLocalizedString("移除跳转入口", comment: ""), isPresented: $confirmsRemoval) {
            Button(NSLocalizedString("移除跳转入口", comment: ""), role: .destructive) { model.hide(link) }
        } message: {
            Text(NSLocalizedString("只隐藏此入口，不删除会话或续聊上下文。", comment: ""))
        }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-continuation-remove-\(link.id)-\(link.kind.rawValue)"),
            title: NSLocalizedString("移除跳转入口", comment: ""), documents: [GuideDocumentReference(id: "context-compression", title: "Context Compression")],
            isActive: confirmsRemoval && model.canEdit && !model.isPreparing,
            settings: [.readOnly("requires_native_confirmation", label: NSLocalizedString("移除跳转入口", comment: ""), value: { .bool(true) })])
    }
}

@MainActor
struct MacContinuationDetailView: View {
    @ObservedObject var model: MacContextCompressionModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var visible = false
    var body: some View {
        NavigationStack {
            Form {
                if let state = model.presentation, let context = state.context, let summary = state.summary {
                    Section {
                        MacSettingsIntroCard(id: "continuation-detail", title: NSLocalizedString("续聊上下文", comment: ""),
                            details: NSLocalizedString("Mac 续聊压缩说明正文", comment: ""), documentID: "context-compression", isActive: model.canEdit)
                        LabeledContent(NSLocalizedString("保留最近原文", comment: ""),
                            value: String(format: NSLocalizedString("%d 轮", comment: ""), context.retainedRoundCount))
                        if let link = state.sourceLink { MacContinuationLinkView(model: model, link: link) }
                    }
                    Section(NSLocalizedString("摘要", comment: "")) { MacMessageTextView(text: summary) }
                    Section(NSLocalizedString("保留最近原文", comment: "")) {
                        ForEach(state.retainedMessages) { message in
                            VStack(alignment: .leading) {
                                Text(message.role).font(.caption).foregroundStyle(.secondary)
                                MacMessageTextView(text: message.text)
                                ForEach(message.tools) { tool in
                                    DisclosureGroup(tool.name) {
                                        Text(tool.arguments).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                                        if let result = tool.result { Text(result).font(.footnote).textSelection(.enabled) }
                                    }
                                }
                            }.buttonStyle(.borderless)
                        }
                    }
                } else { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
            }
            .formStyle(.grouped)
            .disabled(!workspace.canManageLocalModels)
            .navigationTitle(NSLocalizedString("续聊上下文", comment: ""))
            .toolbar { Button(NSLocalizedString("完成", comment: "")) { dismiss() } }
            .modifier(MacGuideInspector())
            .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-continuation-detail-\(model.revision)"),
                title: NSLocalizedString("续聊上下文", comment: ""), documents: [GuideDocumentReference(id: "context-compression", title: "Context Compression")],
                isActive: visible && model.canEdit && !model.isPreparing,
                settings: [.readOnly("continuation", label: NSLocalizedString("续聊上下文", comment: ""), value: { model.presentation?.guideSummary ?? .null })])
        }
        .frame(minWidth: 620, minHeight: 480)
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }
}
