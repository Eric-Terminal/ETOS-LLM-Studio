import Combine
import Foundation

/// 草稿只通知输入组件，避免每次按键使聊天列表与全部配置观察者失效。
@MainActor
public final class ChatComposerDraftState: ObservableObject {
    @Published public private(set) var text: String
    public private(set) var hasSendableText: Bool

    init(text: String) {
        self.text = text
        hasSendableText = text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil
    }

    func update(text: String) {
        guard self.text != text else { return }
        // 同一草稿的发送可用性只准备一次，按钮重绘时不再扫描全部输入。
        hasSendableText = text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil
        self.text = text
    }
}
