import SwiftUI
import Testing
@testable import ETOSCore

struct ETFontTests {
    @Test("字体描述保留样式、字号、字重及独立的等宽数字语义")
    func explicitFontSemantics() {
        let caption = ETFont.caption.monospacedDigit().weight(.semibold)
        #expect(caption.textStyle == .caption)
        #expect(caption.basePointSize == 12)
        #expect(caption.role == .strong)
        #expect(caption.hasMonospacedDigits)
        #expect(caption.design == .default)
        #expect(ETFont.body.monospaced().italic().role == .code)
        #expect(ETFont.body.italic().role == .emphasis)
        #expect(ETFont.system(size: 14, weight: .light, design: .rounded).explicitSize == 14)
        #expect(ETFont.system(.headline, design: .serif).textStyle == .headline)
    }

    @Test("字体修饰顺序保持最终字重与等宽设置")
    func modifierComposition() {
        #expect(ETFont.body.bold().weight(.light).fontWeight == .light)
        #expect(ETFont.body.monospaced().weight(.bold) == ETFont.body.weight(.bold).monospaced())
        #expect(ETFont.title2.monospacedDigit() != ETFont.title2)
    }
}
