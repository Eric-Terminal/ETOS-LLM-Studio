import ETOSCore

/// 与移动端一样只初始化一次；用户消费或清空的建议不因下一次刷新而复活。
struct MacRequestControlSuggestions: Equatable, Sendable {
    private(set) var hasInitialized = false
    var payloads: [String: [String: JSONValue]] = [:]

    mutating func refresh(for control: ModelRequestBodyControl) {
        if !hasInitialized, control.options.contains(where: { !$0.payload.isEmpty }) {
            payloads.merge(control.initialOptionPayloadSuggestions) { current, _ in current }
            hasInitialized = true
        }
        let eligible = Set(control.options.filter { $0.payload.isEmpty }.map(\.id))
        payloads = payloads.filter { eligible.contains($0.key) }
    }
}
