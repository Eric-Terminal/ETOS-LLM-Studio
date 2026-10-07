import Foundation

public enum LocalModelDraftWriteError: LocalizedError {
    case changedExternally

    public var errorDescription: String? {
        switch self {
        case .changedExternally:
            return NSLocalizedString("本地模型已被修改或删除，请重新打开后再试。", comment: "本地模型草稿版本冲突")
        }
    }
}
