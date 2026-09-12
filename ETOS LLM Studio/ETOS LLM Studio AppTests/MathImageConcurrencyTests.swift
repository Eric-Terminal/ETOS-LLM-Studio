import Foundation
import SwiftUI
import Testing
@testable import ETOS_LLM_Studio_App

struct MathImageConcurrencyTests {
    @Test("并发公式请求与顺序渲染的图片一致，不串用字号或内容")
    @MainActor
    func concurrentRenderingMatchesSequentialResults() async throws {
        guard ETNativeMathMarkdownCodec.isAvailable else { return }
        let color = ETIOSMathColorComponents(.black)
        let requests = (0..<16).map {
            ETNativeMathMarkdownCodec.Request(latex: "x^{\($0 + 1)} + \\frac{1}{2}", renderKind: .block)
        }
        let results = await withTaskGroup(of: (Int, Data?).self) { group in
            for (index, request) in requests.enumerated() {
                group.addTask {
                    (index, await ETIOSMathImageRenderer.imageData(
                        for: request, textColor: color, fontScale: index.isMultiple(of: 2) ? 1 : 1.5
                    ))
                }
            }
            var results: [Int: Data] = [:]
            for await (index, data) in group { results[index] = data }
            return results
        }
        #expect(results.count == requests.count)
        for (index, request) in requests.enumerated() {
            let repeated = await ETIOSMathImageRenderer.imageData(
                for: request, textColor: color, fontScale: index.isMultiple(of: 2) ? 1 : 1.5
            )
            #expect(repeated == results[index])
            #expect(repeated?.isEmpty == false)
        }
    }
}
