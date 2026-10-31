import Foundation
import SwiftUI
import Testing
import UIKit
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
        let results = await withTaskGroup(of: (Int, ETIOSRenderedMathImage?).self) { group in
            for (index, request) in requests.enumerated() {
                group.addTask {
                    (index, await ETIOSMathImageRenderer.image(
                        for: request, textColor: color, fontScale: index.isMultiple(of: 2) ? 1 : 1.5
                    ))
                }
            }
            var results: [Int: ETIOSRenderedMathImage] = [:]
            for await (index, image) in group { results[index] = image }
            return results
        }
        #expect(results.count == requests.count)
        for (index, request) in requests.enumerated() {
            let repeated = await ETIOSMathImageRenderer.image(
                for: request, textColor: color, fontScale: index.isMultiple(of: 2) ? 1 : 1.5
            )
            #expect(repeated?.image.pngData() == results[index]?.image.pngData())
            #expect(repeated?.image.size.width ?? 0 > 0)
        }
    }

    @Test("公式图片跨显示环境传递时保留源像素比例和逻辑尺寸")
    @MainActor
    func preservesRenderedImageScale() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let source = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 24), format: format).image { _ in }
        let prepared = ETIOSRenderedMathImage(image: source)

        #expect(prepared.image === source)
        #expect(prepared.image.scale == 2)
        #expect(prepared.image.size == CGSize(width: 80, height: 24))
        #expect(prepared.image.cgImage?.width == 160)
    }
}
