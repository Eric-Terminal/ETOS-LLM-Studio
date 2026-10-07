import SwiftUI
import Testing
@testable import ETOSCore

struct RequestBodySliderPaletteTests {
    @Test("默认色谱保持结构化控制与温度的既有区别")
    func defaultsFollowPayload() {
        var control = ModelRequestBodyControl(title: "控制", kind: .optionGroup)
        #expect(RequestBodySliderPalette.defaultPalette(for: control) == .structured)
        control.options = [.init(title: "温度", payload: ["temperature": .double(0.5)])]
        #expect(RequestBodySliderPalette.resolved(for: control) == .temperature)
    }

    @Test("双色端点按 sRGB 插值并保留透明度")
    func customEndpointsAndAlpha() throws {
        let control = ModelRequestBodyControl(title: "控制", kind: .optionGroup,
            sliderStartColorHex: "#FF000080", sliderEndColorHex: "0000FFFF")
        let palette = RequestBodySliderPalette.resolved(for: control)
        #expect(ChatAppearanceColorCodec.hexRGBA(from: palette.color(at: 0)) == "FF000080")
        #expect(ChatAppearanceColorCodec.hexRGBA(from: palette.color(at: 1)) == "0000FFFF")
        let middle = try #require(RequestBodySliderColorComponents(color: palette.color(at: 0.5)))
        #expect(abs(middle.red - 0.5) < 0.000_01)
        #expect(abs(middle.blue - 0.5) < 0.000_01)
        #expect(abs(middle.alpha - (128.0 / 255 + 1) / 2) < 0.000_01)
    }

    @Test("单个端点缺省沿用原色谱，范围外的位置夹在端点")
    func partialOverridesKeepDefaults() {
        let control = ModelRequestBodyControl(title: "控制", kind: .optionGroup, sliderStartColorHex: "00FF00")
        let palette = RequestBodySliderPalette.resolved(for: control)
        #expect(ChatAppearanceColorCodec.hexRGBA(from: palette.color(at: -1)) == "00FF00FF")
        #expect(ChatAppearanceColorCodec.hexRGBA(from: palette.color(at: 2))
                == ChatAppearanceColorCodec.hexRGBA(from: RequestBodySliderPalette.structured.color(at: 1)))
        #expect(ChatAppearanceColorCodec.hexRGBA(from: palette.color(at: .nan)) == "00FF00FF")
    }
}
