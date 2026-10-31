import CoreGraphics
import Testing
@testable import ETOS_LLM_Studio_App

struct BackgroundCropGeometryTests {
    @Test("手机背景比例随折叠和分屏的可用空间变化")
    func phoneRatioUsesCurrentViewport() {
        let outer = CGSize(width: 390, height: 700)
        let inner = CGSize(width: 744, height: 570)
        let split = CGSize(width: 340, height: 570)

        #expect(BackgroundCropTarget.phone.aspectRatio(in: outer) == outer.width / outer.height)
        #expect(BackgroundCropTarget.phone.aspectRatio(in: inner) == inner.width / inner.height)
        #expect(BackgroundCropTarget.phone.aspectRatio(in: split) == split.width / split.height)
        #expect(BackgroundCropTarget.phone.aspectRatio(in: outer) < 1)
        #expect(BackgroundCropTarget.phone.aspectRatio(in: inner) > 1)
    }

    @Test("为手表裁切时不随手机折叠改变目标比例")
    func watchRatioIsIndependentOfHostViewport() {
        #expect(BackgroundCropTarget.watch.aspectRatio(in: CGSize(width: 390, height: 700)) == 0.82)
        #expect(BackgroundCropTarget.watch.aspectRatio(in: CGSize(width: 744, height: 570)) == 0.82)
    }
}
