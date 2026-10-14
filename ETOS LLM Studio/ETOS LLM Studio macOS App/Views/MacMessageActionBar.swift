import AppKit
import ETOSCore
import SwiftUI

@MainActor
struct MacMessageActionBar: View {
    let row: MacMessagePresentation
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @State private var copied = false
    @State private var copyReset: Task<Void, Never>?
    private var presentation: MacMessageActionBarPresentation { row.actionBar }
    private var alignment: Alignment { presentation.alignment == .leading ? .leading : .trailing }
    private var font: Font {
        let typography = row.content.typography
        let size = CGFloat(typography.pointSize * presentation.fontScale * 0.9)
        if let name = typography.bodyName { return .custom(name, fixedSize: size) }
        return .system(size: size)
    }

    var body: some View {
        if !presentation.items.isEmpty {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(presentation.items) { item in
                        control(item).help(item.help)
                    }
                }
                .font(font).monospacedDigit()
                .buttonStyle(.borderless).controlSize(.small)
                .padding(presentation.showsOuterBorder ? .all : [])
                .overlay {
                    if presentation.showsOuterBorder {
                        RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3))
                    }
                }
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(presentation.alignment == .leading ? .leading : .trailing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: alignment)
            .disabled(!workspace.canManageLocalModels)
            .onChange(of: row.id) { _, _ in resetCopy() }
            .onDisappear { resetCopy() }
        }
    }

    @ViewBuilder
    private func control(_ item: MacMessageActionBarPresentation.Item) -> some View {
        switch item.id {
        case .quickRetry:
            Button { workspace.retryMessage(row.message) } label: { Image(systemName: item.id.macSymbol) }
                .accessibilityLabel(item.id.macTitle)
                .disabled(!workspace.canModifyCurrentHistory || workspace.effectiveModelName == nil)
        case .copyMessage:
            Button {
                NSPasteboard.general.clearContents()
                if NSPasteboard.general.setString(row.message.content, forType: .string) {
                    copied = true; copyReset?.cancel()
                    copyReset = Task {
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                        copied = false
                    }
                }
            } label: { Image(systemName: copied ? "checkmark" : item.id.macSymbol) }
                .accessibilityLabel(copied ? NSLocalizedString("已复制", comment: "") : item.id.macTitle)
        case .readAloud:
            MacReadAloudButton(model: workspace.tts, message: row.message,
                sessionID: workspace.currentSession?.id, isActive: workspace.canManageLocalModels, iconOnly: true)
        case .versionSwitcher:
            MacMessageVersionMenu(row: row)
        case .requestTime, .inputTokens, .outputTokens, .costEstimate:
            if let value = item.value {
                Label(value, systemImage: item.id.macSymbol).foregroundStyle(.secondary)
                    .accessibilityLabel(item.help)
            }
        }
    }

    private func resetCopy() { copyReset?.cancel(); copyReset = nil; copied = false }
}

@MainActor
struct MacMessageVersionMenu: View {
    let row: MacMessagePresentation
    @EnvironmentObject private var workspace: MacWorkspaceModel

    var body: some View {
        Menu {
            ForEach(row.versionOptions) { option in
                Button { workspace.selectVersion(option.id, of: row.message) } label: {
                    if option.id == row.versionIndex { Label(option.title, systemImage: "checkmark") }
                    else { Text(option.title) }
                }
                .disabled(option.id == row.versionIndex)
            }
        } label: { Text(row.versionLabel) }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!workspace.canModifyCurrentHistory)
    }
}
