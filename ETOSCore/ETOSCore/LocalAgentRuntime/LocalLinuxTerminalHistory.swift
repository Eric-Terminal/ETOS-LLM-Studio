import Foundation

/// 逻辑索引始终按时间递增；满容量时只替换最旧槽位，不搬移其余历史行。
struct LocalLinuxTerminalHistory: RandomAccessCollection {
    typealias Index = Int
    private let capacity: Int
    private var lines: [LocalLinuxTerminalLinePresentation] = []
    private var head = 0

    init(capacity: Int) {
        self.capacity = Swift.max(0, capacity)
    }

    var startIndex: Int { 0 }
    var endIndex: Int { lines.count }

    func index(after index: Int) -> Int { index + 1 }
    func index(before index: Int) -> Int { index - 1 }

    subscript(index: Int) -> LocalLinuxTerminalLinePresentation {
        precondition(index >= startIndex && index < endIndex)
        return lines[(head + index) % lines.count]
    }

    mutating func append(_ line: LocalLinuxTerminalLinePresentation) {
        guard capacity > 0 else { return }
        if lines.count < capacity {
            lines.append(line)
        } else {
            lines[head] = line
            head = (head + 1) % capacity
        }
    }

    mutating func removeAll(keepingCapacity: Bool) {
        lines.removeAll(keepingCapacity: keepingCapacity)
        head = 0
    }
}
