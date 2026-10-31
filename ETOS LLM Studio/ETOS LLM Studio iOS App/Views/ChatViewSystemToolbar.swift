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
        .visibilityPriority(.high)

        ToolbarItem(placement: .primaryAction) {
            Button(action: presentModelPickerSheet) {
                Label(NSLocalizedString("选择模型", comment: ""), systemImage: "cpu")
            }
            .accessibilityValue(modelSubtitle)
        }
        .visibilityPriority(.high)

        if let action = selectedChatQuickActions.first,
           selectedChatQuickActions.count == 1 || action == .temporaryChat {
            // decode 已按目录顺序归一化，选中临时对话时它一定在首位；保留连续点击切换模式。
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    performQuickAction(action)
                } label: {
                    Label(action.title, systemImage: singleQuickActionSystemImage(for: action))
                }
                .disabled(!isQuickActionAvailable(action))
            }
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
            ForEach(selectedChatQuickActions) { action in
                if selectedChatQuickActions.count > 1 && action != .temporaryChat {
                    Button {
                        performQuickAction(action)
                    } label: {
                        Label(action.title, systemImage: singleQuickActionSystemImage(for: action))
                    }
                    .disabled(!isQuickActionAvailable(action))
                }
            }
        }
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
