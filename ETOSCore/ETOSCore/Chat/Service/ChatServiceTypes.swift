// ============================================================================
// ChatServiceTypes.swift
// ============================================================================
// ETOS LLM Studio
//
// 存放 ChatService 相关的公共类型与轻量辅助函数，避免主服务文件继续膨胀。
// ============================================================================

import Foundation

/// 一个组合了 Provider 和 Model 的可运行实体，包含了发起 API 请求所需的所有信息。
public struct RunnableModel: Identifiable, Hashable {
    public var id: String { "\(provider.id.uuidString)-\(model.id.uuidString)" }
    public let provider: Provider
    public let model: Model

    public var requestBodyControlState: ModelRequestBodyControlState {
        ModelRequestBodyControlRuntimeStore.state(
            forModelKey: id,
            controls: model.requestBodyControls
        )
    }

    public var effectiveOverrideParameters: [String: JSONValue] {
        model.effectiveOverrideParameters(using: requestBodyControlState)
    }

    public func effectiveOverrideParameters(using state: ModelRequestBodyControlState) -> [String: JSONValue] {
        model.effectiveOverrideParameters(using: state)
    }

    public func saveRequestBodyControlState(_ state: ModelRequestBodyControlState) {
        ModelRequestBodyControlRuntimeStore.save(
            state,
            forModelKey: id,
            controls: model.requestBodyControls
        )
    }

    public init(provider: Provider, model: Model) {
        self.provider = provider
        self.model = model
    }

    // 只根据 ID 判断相等性，避免参数变化导致 Picker 匹配失败。
    public static func == (lhs: RunnableModel, rhs: RunnableModel) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// 根据最终请求覆盖参数决定响应模式，确保接收方式与实际发送的 `stream` 一致。
func resolvedRequestStreamingEnabled(
    preference: Bool,
    overrides: [String: JSONValue]
) -> Bool {
    guard case .bool(let overriddenValue)? = overrides["stream"] else {
        return preference
    }
    return overriddenValue
}

public enum SystemTimeInjectionPosition: String, CaseIterable, Identifiable, Sendable {
    case front
    case tail

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .front:
            return NSLocalizedString("前置发送", comment: "System time injection position before system prompt")
        case .tail:
            return NSLocalizedString("末尾发送", comment: "System time injection position tail system message")
        }
    }
}

public enum SystemTimeContextFormatter {
    public static func description(at date: Date = Date()) -> String {
        let localeFormatter = DateFormatter()
        localeFormatter.calendar = Calendar(identifier: .gregorian)
        localeFormatter.locale = Locale(identifier: "en_US_POSIX")
        localeFormatter.timeZone = TimeZone.current
        localeFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let localTime = localeFormatter.string(from: date)
        let timeZoneIdentifier = TimeZone.current.identifier

        return String(
            format: NSLocalizedString("当前系统时间%@，时区%@", comment: "System time line for model prompt."),
            localTime,
            timeZoneIdentifier
        )
    }
}

func moveElements<T>(in array: inout [T], fromOffsets offsets: IndexSet, toOffset destination: Int) {
    let sortedOffsets = offsets.sorted()
    guard !sortedOffsets.isEmpty else { return }
    guard sortedOffsets.allSatisfy({ $0 >= 0 && $0 < array.count }) else { return }
    guard destination >= 0 && destination <= array.count else { return }

    let movedItems = sortedOffsets.map { array[$0] }
    for index in sortedOffsets.reversed() {
        array.remove(at: index)
    }

    let removedBeforeDestination = sortedOffsets.filter { $0 < destination }.count
    let insertionIndex = max(0, min(destination - removedBeforeDestination, array.count))
    array.insert(contentsOf: movedItems, at: insertionIndex)
}
