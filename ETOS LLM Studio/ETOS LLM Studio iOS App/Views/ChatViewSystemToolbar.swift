import SwiftUI
import ETOSCore

extension ChatView {
    /// 系统容器决定工具栏方向与溢出位置；聊天输入仍属于会话内容和键盘。
    @available(iOS 27.1, *)
    @ToolbarContentBuilder
    var adaptiveChatToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if isMessageSelectionMode {
                Button(action: exitMessageSelection) {
                    Label(NSLocalizedString("退出多选", comment: ""), systemImage: "xmark")
                }
            } else {
                Button(action: presentSessionPicker) {
                    Label(navBarSessionAccessibilityLabel, systemImage: navBarSessionIconName)
                }
            }
        }
        // 会话导航比用户优先项更早保留，避免大量快捷项挤走侧栏入口。
        .visibilityPriority(ToolbarItemVisibilityPriority(higherThan: .high))

        ForEach(chatToolbarActions) { action in
            // 同一 placement 保留用户顺序；空间不足时仍由系统安全地移入溢出菜单。
            ToolbarItem(id: action.rawValue, placement: .topBarTrailing) {
                systemQuickActionButton(action)
            }
            .visibilityPriority(.high)
        }

        ToolbarOverflowMenu {
            if isMessageSelectionMode {
                Section {
                    Button(action: invertMessageSelection) {
                        Label(NSLocalizedString("反选", comment: ""), systemImage: "arrow.left.arrow.right.circle")
                    }
                    Button {
                        isSelectedMessagesExportPresented = true
                    } label: {
                        Label(NSLocalizedString("导出所选", comment: ""), systemImage: "square.and.arrow.up")
                    }
                    .disabled(selectedMessageIDs.isEmpty)
                    Button(role: .destructive) {
                        showSelectedMessagesDeleteConfirm = true
                    } label: {
                        Label(NSLocalizedString("删除所选", comment: ""), systemImage: "trash")
                    }
                    .disabled(selectedMessageIDs.isEmpty)
                }
            }
            ForEach(chatOverflowActions) { action in
                systemQuickActionButton(action)
            }
        }
    }

    private func systemQuickActionButton(_ action: ChatQuickAction) -> some View {
        Button {
            performQuickAction(action)
        } label: {
            Label(action.title, systemImage: singleQuickActionSystemImage(for: action))
        }
        .disabled(!isQuickActionAvailable(action))
        .accessibilityValue(action == .modelPicker ? modelSubtitle : "")
        // 临时对话放进更多后仍支持连续点击切换记忆模式。
        .menuActionDismissBehavior(action == .temporaryChat ? .disabled : .automatic)
    }
}

struct ChatNavigationSubtitle: ViewModifier {
    let modelName: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.navigationSubtitle(modelName)
        } else {
            content
        }
    }
}
