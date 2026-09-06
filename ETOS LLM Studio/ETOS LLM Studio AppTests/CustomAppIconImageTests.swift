import CoreGraphics
import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import ETOS_LLM_Studio_App

@MainActor
struct CustomAppIconImageTests {
    @Test("导出的 PNG 保留用户选择的裁切区域并可被系统解码")
    func croppedIconExportsAsPNG() throws {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 16, height: 8, bitsPerComponent: 8, bytesPerRow: 64,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 8, y: 0, width: 8, height: 8))
        let source = try #require(context.makeImage())
        let input = try #require(UIImage(cgImage: source).pngData())
        let prepared = try CustomAppIconImageProcessor.prepareImage(from: input)
        let halfWidth = prepared.image.size.width / 2
        let icon = try CustomAppIconImageProcessor.renderIcon(
            from: prepared,
            cropRect: CGRect(x: halfWidth, y: 0, width: halfWidth, height: prepared.image.size.height)
        )

        let exportedSource = try #require(CGImageSourceCreateWithData(icon.pngData as CFData, nil))
        #expect(CGImageSourceGetType(exportedSource) as String? == UTType.png.identifier)
        let exportedImage = try #require(CGImageSourceCreateImageAtIndex(exportedSource, 0, nil))
        #expect(exportedImage.width == 400)
        #expect(exportedImage.height == 400)

        // 取景选中了右半边的蓝色，导出不能退回整张图片或选成左半边。
        let pixelData = try #require(icon.image.cgImage?.dataProvider?.data)
        let pixels = pixelData as Data
        #expect(pixels[0] == 0)
        #expect(pixels[1] == 0)
        #expect(pixels[2] == 255)
        #expect(pixels[3] == 255)
    }

    @Test("不可解码的选图数据会被拒绝")
    func unreadableImageIsRejected() {
        #expect(throws: CustomAppIconImageError.self) {
            _ = try CustomAppIconImageProcessor.prepareImage(from: Data("不是图片".utf8))
        }
    }
}
