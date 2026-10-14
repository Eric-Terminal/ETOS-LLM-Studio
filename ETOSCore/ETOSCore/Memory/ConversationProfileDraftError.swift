import Foundation

public enum ConversationProfileDraftError: LocalizedError, Equatable {
    case emptyContent
    case changedExternally

    public var errorDescription: String? {
        switch self {
        case .emptyContent: NSLocalizedString("用户画像内容不能为空。", comment: "")
        case .changedExternally: NSLocalizedString("用户画像已在其他位置修改，请重新打开后再编辑。", comment: "")
        }
    }
}
