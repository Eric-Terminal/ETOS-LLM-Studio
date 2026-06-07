// ============================================================================
// TopK.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件源自 SimilaritySearchKit，为 Collection 类型提供了一个 topK 方法。
// 这个高效的排序方法用于从集合中获取前 K 个元素，是修复编译错误的关键。
// 我已根据项目规范，将注释和文件头修改为中文格式。
// ============================================================================

import Foundation

public extension Collection {
    /// 辅助函数，用于对元素进行排序并返回前 K 个元素。
    ///
    /// `by` 参数接受一个形如以下的函数：
    /// ```swift
    /// (Element, Element) throws -> Bool
    /// ```
    ///
    /// 改编自 [Stackoverflow](https://stackoverflow.com/questions/65746299/how-do-you-find-the-top-3-maximum-values-in-a-swift-dictionary)
    ///
    /// - Parameters:
    ///   - count:  要返回的顶部元素的数量。
    ///   - by: 比较函数
    ///
    /// - Returns: 包含前 K 个元素的有序数组
    ///
    /// - Note: TopK 和 Swift 标准库的排序实现在处理相等值的元素时可能顺序不同
    func topK(_ count: Int, by areInIncreasingOrder: (Element, Element) throws -> Bool) rethrows -> [Self.Element] {
        assert(count >= 0,
               """
               无法使用负数数量的元素作为前缀！
               """)

        guard count > 0 else {
            return []
        }

        let prefixCount = Swift.min(count, self.count)

        guard prefixCount < self.count / 10 else {
            return try Array(sorted(by: areInIncreasingOrder).prefix(prefixCount))
        }

        var result = try self.prefix(prefixCount).sorted(by: areInIncreasingOrder)

        for e in self.dropFirst(prefixCount) {
            if let last = result.last, try areInIncreasingOrder(last, e) {
                continue
            }
            let insertionIndex = try result.partition { try areInIncreasingOrder(e, $0) }
            let isLastElement = insertionIndex == result.endIndex
            result.removeLast()
            if isLastElement {
                result.append(e)
            } else {
                result.insert(e, at: insertionIndex)
            }
        }
        return result
    }
}
