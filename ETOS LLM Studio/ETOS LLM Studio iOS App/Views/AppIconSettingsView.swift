// ============================================================================
// AppIconSettingsView.swift
// ============================================================================
// 自定义主屏幕图标的选择、裁切、预览与安装引导
// ============================================================================

import PhotosUI
import SwiftUI
import UIKit

struct AppIconSettingsView: View {
    @ObservedObject private var installer = CustomAppIconInstaller.shared
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var pendingImage: PreparedCustomAppIconImage?
    @State private var renderedIcon: RenderedCustomAppIcon?
    @State private var iconName: String
    @State private var isShowingCropEditor = false
    @State private var isShowingIntroDetails = false
    @State private var isProcessingImage = false
    @State private var isGeneratingProfile = false
    @State private var localErrorMessage: String?

    init() {
        let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        _iconName = State(
            initialValue: displayName ?? NSLocalizedString("ETOS LLM Studio", comment: "App 名称")
        )
    }

    var body: some View {
        Form {
            Section {
                settingsIntroCard
            }

            Section {
                iconPreview

                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label(
                        renderedIcon == nil
                            ? NSLocalizedString("选择图标图片", comment: "自定义主屏幕图标选择图片按钮")
                            : NSLocalizedString("重新选择图片", comment: "自定义主屏幕图标重新选择图片按钮"),
                        systemImage: "photo.on.rectangle"
                    )
                }
                .disabled(isWorking)
            } header: {
                Text(NSLocalizedString("图标图片", comment: "自定义主屏幕图标图片分组"))
            } footer: {
                Text(NSLocalizedString("图片会在设备上裁切为正方形并缩放，不会上传到服务器。", comment: "自定义主屏幕图标图片处理说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField(
                    NSLocalizedString("主屏幕名称", comment: "自定义主屏幕图标名称输入框"),
                    text: $iconName
                )
                .textInputAutocapitalization(.words)
                .onChange(of: iconName) { _, newValue in
                    if newValue.count > 30 {
                        iconName = String(newValue.prefix(30))
                    }
                }
            } header: {
                Text(NSLocalizedString("名称", comment: "自定义主屏幕图标名称分组"))
            } footer: {
                Text(NSLocalizedString("名称会显示在图标下方，最多 30 个字符。", comment: "自定义主屏幕图标名称说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    generateAndDownloadProfile()
                } label: {
                    HStack {
                        Label(
                            NSLocalizedString("生成并下载描述文件", comment: "自定义主屏幕图标下载按钮"),
                            systemImage: "square.and.arrow.down"
                        )
                        Spacer()
                        if isGeneratingProfile || installer.isBusy {
                            ProgressView()
                        }
                    }
                }
                .disabled(renderedIcon == nil || normalizedIconName.isEmpty || isWorking)
            } footer: {
                Text(NSLocalizedString("浏览器收到描述文件后，本地下载服务会立即关闭。再次安装会更新此前由 ETOS 创建的主屏幕图标。", comment: "自定义主屏幕图标下载说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let statusPresentation {
                Section {
                    Label(statusPresentation.text, systemImage: statusPresentation.systemImage)
                        .foregroundStyle(statusPresentation.color)
                } header: {
                    Text(NSLocalizedString("当前状态", comment: "自定义主屏幕图标当前状态分组"))
                }
            }

            Section(NSLocalizedString("安装步骤", comment: "自定义主屏幕图标安装步骤分组")) {
                Label(
                    NSLocalizedString("在浏览器中允许下载描述文件。", comment: "自定义主屏幕图标安装步骤一"),
                    systemImage: "1.circle.fill"
                )
                Label(
                    NSLocalizedString("打开系统“设置”，轻点“已下载描述文件”。", comment: "自定义主屏幕图标安装步骤二"),
                    systemImage: "2.circle.fill"
                )
                Label(
                    NSLocalizedString("检查内容后轻点“安装”，主屏幕随后会出现新图标。", comment: "自定义主屏幕图标安装步骤三"),
                    systemImage: "3.circle.fill"
                )
            }

            Section {
                Text(NSLocalizedString("如需移除，请前往“设置”→“通用”→“VPN 与设备管理”，删除 ETOS LLM Studio 图标描述文件。", comment: "自定义主屏幕图标移除说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("主屏幕图标", comment: "自定义主屏幕图标页面标题"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                await prepareSelectedPhoto(item)
            }
        }
        .sheet(isPresented: $isShowingCropEditor, onDismiss: {
            pendingImage = nil
            selectedPhoto = nil
        }) {
            if let pendingImage {
                CustomAppIconCropEditorView(
                    sourceImage: pendingImage.image,
                    onCancel: {
                        isShowingCropEditor = false
                    },
                    onConfirm: { cropRect in
                        renderSelectedIcon(from: pendingImage, cropRect: cropRect)
                    }
                )
            } else {
                ProgressView()
                    .presentationDetents([.medium])
            }
        }
        .sheet(isPresented: $isShowingIntroDetails) {
            NavigationStack {
                ScrollView {
                    Text(NSLocalizedString("自定义主屏幕图标说明正文", comment: "自定义主屏幕图标介绍详情"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(NSLocalizedString("主屏幕图标", comment: "自定义主屏幕图标介绍标题"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .alert(NSLocalizedString("无法创建主屏幕图标", comment: "自定义主屏幕图标错误标题"), isPresented: errorPresented) {
            Button(NSLocalizedString("确定", comment: "确认自定义主屏幕图标错误"), role: .cancel) {}
        } message: {
            Text(presentedErrorMessage ?? "")
        }
    }

    private var settingsIntroCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("使用自己的图片", comment: "自定义主屏幕图标介绍卡片标题"))
                .etFont(.headline.weight(.semibold))
            Text(NSLocalizedString("选择图片并生成只在本机传输的主屏幕图标。", comment: "自定义主屏幕图标介绍卡片摘要"))
                .etFont(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                isShowingIntroDetails = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: "打开自定义主屏幕图标详细说明"))
                    .etFont(.footnote.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private var iconPreview: some View {
        HStack {
            Spacer()
            Group {
                if let renderedIcon {
                    Image(uiImage: renderedIcon.image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image("AppIconDisplay")
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: 112, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 25, style: .continuous)
                    .strokeBorder(Color(uiColor: .separator).opacity(0.5), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .accessibilityLabel(NSLocalizedString("图标预览", comment: "自定义主屏幕图标预览辅助功能标签"))
            Spacer()
        }
        .padding(.vertical)
    }

    private var normalizedIconName: String {
        iconName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isWorking: Bool {
        isProcessingImage || isGeneratingProfile || installer.isBusy
    }

    private var statusPresentation: (text: String, systemImage: String, color: Color)? {
        if isProcessingImage {
            return (
                NSLocalizedString("正在处理图片…", comment: "自定义主屏幕图标处理图片状态"),
                "photo",
                .secondary
            )
        }
        if isGeneratingProfile || installer.phase == .startingServer {
            return (
                NSLocalizedString("正在准备描述文件…", comment: "自定义主屏幕图标准备状态"),
                "doc.text",
                .secondary
            )
        }
        if installer.phase == .waitingForDownload {
            return (
                NSLocalizedString("正在等待浏览器下载…", comment: "自定义主屏幕图标等待下载状态"),
                "safari",
                .secondary
            )
        }
        if installer.phase == .profileDelivered {
            return (
                NSLocalizedString("描述文件已发送到浏览器，请继续前往系统设置安装。", comment: "自定义主屏幕图标描述文件已发送状态"),
                "checkmark.circle.fill",
                .green
            )
        }
        return nil
    }

    private var presentedErrorMessage: String? {
        localErrorMessage ?? installer.errorMessage
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { presentedErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    localErrorMessage = nil
                    installer.clearError()
                }
            }
        )
    }

    private func prepareSelectedPhoto(_ item: PhotosPickerItem) async {
        installer.resetStatus()
        isProcessingImage = true
        defer {
            isProcessingImage = false
        }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw CustomAppIconImageError.unreadableImage
            }
            let preparedImage = try await Task.detached(priority: .userInitiated) {
                try CustomAppIconImageProcessor.prepareImage(from: data)
            }.value
            pendingImage = preparedImage
            isShowingCropEditor = true
        } catch {
            selectedPhoto = nil
            localErrorMessage = NSLocalizedString("无法读取所选图片，请重新选择。", comment: "自定义主屏幕图标读取图片失败")
        }
    }

    private func renderSelectedIcon(
        from preparedImage: PreparedCustomAppIconImage,
        cropRect: CGRect
    ) {
        isShowingCropEditor = false
        isProcessingImage = true
        Task {
            defer {
                isProcessingImage = false
            }
            do {
                let icon = try await Task.detached(priority: .userInitiated) {
                    try CustomAppIconImageProcessor.renderIcon(
                        from: preparedImage,
                        cropRect: cropRect
                    )
                }.value
                renderedIcon = icon
            } catch {
                localErrorMessage = NSLocalizedString("无法处理所选图片，请重新选择。", comment: "自定义主屏幕图标处理图片失败")
            }
        }
    }

    private func generateAndDownloadProfile() {
        guard let renderedIcon else { return }
        let label = normalizedIconName
        guard !label.isEmpty else {
            localErrorMessage = NSLocalizedString("请输入主屏幕名称。", comment: "自定义主屏幕图标名称为空")
            return
        }

        let profileDescription = NSLocalizedString(
            "为 ETOS LLM Studio 添加一个可移除的自定义主屏幕图标。",
            comment: "自定义主屏幕图标描述文件说明"
        )
        isGeneratingProfile = true
        Task {
            defer {
                isGeneratingProfile = false
            }
            do {
                let profileData = try await Task.detached(priority: .userInitiated) {
                    try CustomAppIconProfileBuilder.makeProfile(
                        iconPNGData: renderedIcon.pngData,
                        label: label,
                        profileDescription: profileDescription
                    )
                }.value
                installer.install(profileData: profileData)
            } catch {
                localErrorMessage = error.localizedDescription
            }
        }
    }
}

private struct CustomAppIconCropEditorView: View {
    let sourceImage: UIImage
    let onCancel: () -> Void
    let onConfirm: (CGRect) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var zoomScale: CGFloat = 1
    @State private var imageOffset: CGSize = .zero
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var pinchScale: CGFloat = 1

    var body: some View {
        NavigationStack {
            VStack {
                Text(NSLocalizedString("拖动和缩放以调整图标取景范围", comment: "自定义主屏幕图标裁切操作说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)

                GeometryReader { proxy in
                    let canvasSize = proxy.size
                    let cropRect = cropRect(in: canvasSize)
                    let currentScale = combinedScale
                    let renderedSize = renderedImageSize(for: cropRect, scale: currentScale)
                    let effectiveOffset = effectiveOffset(for: renderedSize, cropRect: cropRect)

                    ZStack {
                        cropCanvasBackground

                        Image(uiImage: sourceImage)
                            .resizable()
                            .frame(width: renderedSize.width, height: renderedSize.height)
                            .position(
                                x: cropRect.midX + effectiveOffset.width,
                                y: cropRect.midY + effectiveOffset.height
                            )
                            .gesture(editingGesture(cropRect: cropRect))
                            .simultaneousGesture(
                                TapGesture(count: 2)
                                    .onEnded {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            zoomScale = 1
                                            imageOffset = .zero
                                        }
                                    }
                            )

                        cropOverlay(canvasSize: canvasSize, cropRect: cropRect)
                            .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal)
                    .padding(.bottom)
                    .onAppear {
                        imageOffset = clampOffset(
                            imageOffset,
                            renderedSize: renderedSize,
                            cropRect: cropRect
                        )
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(NSLocalizedString("取消", comment: "取消自定义主屏幕图标裁切"), action: onCancel)
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(NSLocalizedString("使用", comment: "确认自定义主屏幕图标裁切")) {
                                onConfirm(
                                    sourceCropRect(
                                        cropRect: cropRect,
                                        renderedSize: renderedSize,
                                        offset: effectiveOffset
                                    )
                                )
                            }
                        }
                    }
                }
            }
            .padding(.top)
            .navigationTitle(NSLocalizedString("裁切图标", comment: "自定义主屏幕图标裁切页面标题"))
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        }
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
    }

    private var cropCanvasBackground: Color {
        colorScheme == .dark ? Color.black.opacity(0.9) : Color(uiColor: .secondarySystemBackground)
    }

    private var combinedScale: CGFloat {
        min(max(zoomScale * pinchScale, 1), 6)
    }

    private func renderedImageSize(for cropRect: CGRect, scale: CGFloat) -> CGSize {
        let baseScale = max(
            cropRect.width / sourceImage.size.width,
            cropRect.height / sourceImage.size.height
        )
        return CGSize(
            width: sourceImage.size.width * baseScale * scale,
            height: sourceImage.size.height * baseScale * scale
        )
    }

    private func editingGesture(cropRect: CGRect) -> some Gesture {
        let drag = DragGesture()
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let nextOffset = CGSize(
                    width: imageOffset.width + value.translation.width,
                    height: imageOffset.height + value.translation.height
                )
                let renderedSize = renderedImageSize(for: cropRect, scale: combinedScale)
                imageOffset = clampOffset(nextOffset, renderedSize: renderedSize, cropRect: cropRect)
            }

        let pinch = MagnificationGesture()
            .updating($pinchScale) { value, state, _ in
                state = value
            }
            .onEnded { value in
                zoomScale = min(max(zoomScale * value, 1), 6)
                let renderedSize = renderedImageSize(for: cropRect, scale: zoomScale)
                imageOffset = clampOffset(imageOffset, renderedSize: renderedSize, cropRect: cropRect)
            }

        return drag.simultaneously(with: pinch)
    }

    private func effectiveOffset(for renderedSize: CGSize, cropRect: CGRect) -> CGSize {
        let mergedOffset = CGSize(
            width: imageOffset.width + dragTranslation.width,
            height: imageOffset.height + dragTranslation.height
        )
        return clampOffset(mergedOffset, renderedSize: renderedSize, cropRect: cropRect)
    }

    private func clampOffset(_ offset: CGSize, renderedSize: CGSize, cropRect: CGRect) -> CGSize {
        let maximumX = max((renderedSize.width - cropRect.width) / 2, 0)
        let maximumY = max((renderedSize.height - cropRect.height) / 2, 0)
        return CGSize(
            width: min(max(offset.width, -maximumX), maximumX),
            height: min(max(offset.height, -maximumY), maximumY)
        )
    }

    private func cropRect(in canvasSize: CGSize) -> CGRect {
        let sideLength = max(min(canvasSize.width - 64, canvasSize.height - 48), 1)
        return CGRect(
            x: (canvasSize.width - sideLength) / 2,
            y: (canvasSize.height - sideLength) / 2,
            width: sideLength,
            height: sideLength
        )
    }

    private func cropOverlay(canvasSize: CGSize, cropRect: CGRect) -> some View {
        ZStack {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: canvasSize))
                path.addRoundedRect(
                    in: cropRect,
                    cornerSize: CGSize(width: 24, height: 24),
                    style: .continuous
                )
            }
            .fill(
                colorScheme == .dark ? Color.black.opacity(0.5) : Color.white.opacity(0.72),
                style: FillStyle(eoFill: true)
            )

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(colorScheme == .dark ? Color.white : Color.primary, lineWidth: 2)
                .frame(width: cropRect.width, height: cropRect.height)
                .position(x: cropRect.midX, y: cropRect.midY)
        }
    }

    private func sourceCropRect(
        cropRect: CGRect,
        renderedSize: CGSize,
        offset: CGSize
    ) -> CGRect {
        let imageFrame = CGRect(
            x: cropRect.midX + offset.width - renderedSize.width / 2,
            y: cropRect.midY + offset.height - renderedSize.height / 2,
            width: renderedSize.width,
            height: renderedSize.height
        )
        let sourceRect = CGRect(
            x: (cropRect.minX - imageFrame.minX) / renderedSize.width * sourceImage.size.width,
            y: (cropRect.minY - imageFrame.minY) / renderedSize.height * sourceImage.size.height,
            width: cropRect.width / renderedSize.width * sourceImage.size.width,
            height: cropRect.height / renderedSize.height * sourceImage.size.height
        )
        return sourceRect.intersection(CGRect(origin: .zero, size: sourceImage.size))
    }
}
