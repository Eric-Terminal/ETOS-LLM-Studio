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

/// 按提供商预分组的模型集合，供选择器和排序界面直接渲染。
public struct RunnableModelProviderGroup: Identifiable, Hashable {
    public var id: UUID { provider.id }
    public let provider: Provider
    public let providerInitial: String
    public let models: [RunnableModel]

    public init(provider: Provider, models: [RunnableModel]) {
        self.provider = provider
        self.providerInitial = ProviderMonogram.abbreviation(for: provider.name)
        self.models = models
    }
}

public enum ProviderMonogram {
    /// 优先提取分词或驼峰单词的首字母；单个单词取前两个字符，中文先转换为拼音。
    public static func abbreviation(for providerName: String) -> String {
        let trimmedName = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return "?" }

        let source = containsHanCharacters(trimmedName)
            ? transliteratedChinese(trimmedName)
            : trimmedName
        let words = wordComponents(in: source)
        guard let firstWord = words.first else { return "?" }

        if words.count > 1 {
            let initials = words.prefix(2).compactMap { $0.first }
            return String(initials).uppercased()
        }
        return String(firstWord.prefix(2)).uppercased()
    }

    private static func containsHanCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0xF900...0xFAFF,
                 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }

    private static func transliteratedChinese(_ text: String) -> String {
        text.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripCombiningMarks, reverse: false)
            ?? text
    }

    private static func wordComponents(in text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }
            .flatMap(camelCaseComponents)
    }

    private static func camelCaseComponents(_ component: Substring) -> [String] {
        let characters = Array(component)
        guard characters.count > 1 else { return characters.isEmpty ? [] : [String(component)] }

        var result: [String] = []
        var wordStart = 0
        for index in 1..<characters.count {
            let previous = characters[index - 1]
            let current = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let startsAfterLowercase = previous.isLowercase && current.isUppercase
            let startsAfterAcronym = previous.isUppercase
                && current.isUppercase
                && next?.isLowercase == true
            guard startsAfterLowercase || startsAfterAcronym else { continue }

            result.append(String(characters[wordStart..<index]))
            wordStart = index
        }
        result.append(String(characters[wordStart...]))
        return result
    }
}

public enum RunnableModelGrouping {
    /// 保留模型在输入数组中的相对顺序，并按用户设置的提供商顺序生成分组。
    public static func groups(
        models: [RunnableModel],
        providerOrder: [Provider]
    ) -> [RunnableModelProviderGroup] {
        guard !models.isEmpty else { return [] }

        var modelsByProviderID: [UUID: [RunnableModel]] = [:]
        var providerByID = Dictionary(uniqueKeysWithValues: providerOrder.map { ($0.id, $0) })
        var orderedProviderIDs = providerOrder.map(\.id)
        var seenProviderIDs = Set(orderedProviderIDs)

        for model in models {
            modelsByProviderID[model.provider.id, default: []].append(model)
            providerByID[model.provider.id] = model.provider
            if seenProviderIDs.insert(model.provider.id).inserted {
                orderedProviderIDs.append(model.provider.id)
            }
        }

        return orderedProviderIDs.compactMap { providerID in
            guard let provider = providerByID[providerID],
                  let providerModels = modelsByProviderID[providerID],
                  !providerModels.isEmpty else {
                return nil
            }
            return RunnableModelProviderGroup(provider: provider, models: providerModels)
        }
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
