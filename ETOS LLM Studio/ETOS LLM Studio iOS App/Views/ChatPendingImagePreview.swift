import ETOSCore
import SwiftUI
import UIKit

/// 输入预览与飞行接走同一份已解码图片；原比例内容始终保留在中心裁切之外。
struct ChatPendingImagePreview: View {
    let attachment: ImageAttachment

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private var target: DisplayImageTarget {
        // 单图气泡最大为 220×180；提前按落点准备，发送触摸中不再请求更大的位图。
        DisplayImageTarget(size: CGSize(width: 220, height: 180), scale: displayScale)
    }

    var body: some View {
        Group {
            if let image {
                ChatSendImageSource(id: .image(attachment.id), image: image)
            } else {
                ZStack {
                    Color(uiColor: .secondarySystemBackground)
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .frame(width: 72, height: 72)
        .task(id: "\(attachment.id)|\(target.width)x\(target.height)") {
            let prepared = await DisplayImageLoader.shared.pendingAttachment(attachment, target: target)
            guard !Task.isCancelled else { return }
            image = prepared?.image
        }
    }
}

struct ChatSendImageSource: UIViewRepresentable {
    @Environment(\.chatSendFlightSources) private var sources
    let id: ChatSendPresentationSource
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.isUserInteractionEnabled = false
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.layer.cornerRadius = 10
        view.layer.cornerCurve = .continuous
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        view.image = image
        context.coordinator.sources = sources
        context.coordinator.id = id
        sources?.register(view, id: id)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 72, height: proposal.height ?? 72)
    }

    static func dismantleUIView(_ view: UIImageView, coordinator: Coordinator) {
        guard let id = coordinator.id else { return }
        coordinator.sources?.unregister(view, id: id)
    }

    final class Coordinator {
        weak var sources: ChatSendFlightSources?
        var id: ChatSendPresentationSource?
    }
}
