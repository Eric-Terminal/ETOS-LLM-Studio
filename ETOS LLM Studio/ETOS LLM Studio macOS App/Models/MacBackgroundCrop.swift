import AppKit
import Foundation

enum MacBackgroundCropAspect: String, CaseIterable, Identifiable, Sendable {
    case original, desktop, phone, watch, square
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return NSLocalizedString("原始比例", comment: "")
        case .desktop: return NSLocalizedString("桌面比例", comment: "")
        case .phone: return NSLocalizedString("手机比例", comment: "")
        case .watch: return NSLocalizedString("手表比例", comment: "")
        case .square: return NSLocalizedString("正方形", comment: "")
        }
    }
    func ratio(original: CGSize) -> CGFloat {
        switch self {
        case .original: return original.width / original.height
        case .desktop: return 16.0 / 10.0
        case .phone: return 9.0 / 16.0
        case .watch: return 0.82
        case .square: return 1
        }
    }
}

/// 位置按可移动范围归一化；改变比例和缩放时仍能保持相同的靠边意图。
struct MacBackgroundCropParameters: Equatable, Sendable {
    var aspect = MacBackgroundCropAspect.original
    var zoom = 1.0
    var horizontal = 0.5
    var vertical = 0.5

    func unitRect(for size: CGSize) -> CGRect {
        let original = size.width / size.height, target = aspect.ratio(original: size)
        let scale = CGFloat(min(6, max(1, zoom)))
        let width = min(1, target / original) / scale
        let height = min(1, original / target) / scale
        return CGRect(x: (1 - width) * CGFloat(min(1, max(0, horizontal))),
                      y: (1 - height) * CGFloat(min(1, max(0, vertical))), width: width, height: height)
    }

    func pixelRect(for size: CGSize) -> CGRect {
        let unit = unitRect(for: size)
        return CGRect(x: unit.minX * size.width, y: unit.minY * size.height,
                      width: unit.width * size.width, height: unit.height * size.height)
            .integral.intersection(CGRect(origin: .zero, size: size))
    }

    func moved(by translation: CGSize, displayedImageSize: CGSize, sourceSize: CGSize) -> MacBackgroundCropParameters {
        var result = self
        let crop = unitRect(for: sourceSize)
        if crop.width < 1, displayedImageSize.width > 0 {
            let movement = Double(translation.width / displayedImageSize.width / (1 - crop.width))
            result.horizontal = min(1, max(0, horizontal - movement))
        }
        if crop.height < 1, displayedImageSize.height > 0 {
            let movement = Double(translation.height / displayedImageSize.height / (1 - crop.height))
            result.vertical = min(1, max(0, vertical - movement))
        }
        return result
    }
}

/// 只传递已定向、已解码的预览位图；保存时从原图重新取得完整像素。
struct MacPreparedBackgroundCrop: @unchecked Sendable {
    let file: MacBackgroundFile
    let pixelSize: CGSize
    let preview: NSImage
}
