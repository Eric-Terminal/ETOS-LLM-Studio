import AppKit
import ETOSCore
import SwiftUI

struct MacRoleplayHTMLView: View {
    let document: RoleplayPreparedDocument
    @ObservedObject var runtime: MacRoleplayRuntime
    var body: some View { MacRoleplayHTMLCard(document: document, runtime: runtime).id(runtime.epoch) }
}

private struct MacRoleplayHTMLCard: View {
    let document: RoleplayPreparedDocument
    @ObservedObject var runtime: MacRoleplayRuntime
    @State private var content = InlineHTMLContent()
    @State private var height: CGFloat = 180
    @State private var error: String?
    @State private var showsActions = false

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(document.title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { showsActions = true } label: {
                    Label(NSLocalizedString("内联内容", comment: ""), systemImage: "ellipsis")
                }
            }
            MacRoleplayWebView(document: document, runtime: runtime, content: content, height: $height, error: $error)
                .frame(maxWidth: .infinity).frame(height: height)
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .sheet(isPresented: $showsActions) {
            NavigationStack {
                InlineHTMLActionsView(content: content, onCopy: { text in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }, onExport: { try await MacInlineHTMLExport.save($0, $1) }) { EmptyView() }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(NSLocalizedString("完成", comment: "")) { showsActions = false }
                    }
                }
            }
            .modifier(MacGuideInspector())
            .frame(minWidth: 520, minHeight: 420)
        }
        .onChange(of: runtime.epoch) { _, _ in showsActions = false }
    }
}

struct MacRoleplayScriptHost: View {
    @ObservedObject var runtime: MacRoleplayRuntime
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading) {
            if !runtime.buttons.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(runtime.buttons) { button in
                            Button(button.name) { runtime.press(button) }.buttonStyle(.bordered)
                        }
                    }
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .background {
            ZStack {
                ForEach(runtime.scripts) { document in
                    MacRoleplayWebView(document: document, runtime: runtime, content: nil, height: .constant(1), error: $error)
                        .frame(width: 1, height: 1).opacity(0.001)
                }
            }
            .id(runtime.epoch)
            .allowsHitTesting(false)
        }
        .onChange(of: runtime.epoch) { _, _ in error = nil }
    }
}
