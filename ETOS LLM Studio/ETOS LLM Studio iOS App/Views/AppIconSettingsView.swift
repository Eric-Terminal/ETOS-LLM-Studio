// ============================================================================
// AppIconSettingsView.swift
// ============================================================================
// 自定义主屏幕图标的选图、导出与快捷指令设置引导
// ============================================================================

import ETOSCore
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AppIconSettingsView: View {
    @Environment(\.openURL) private var openURL
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var pendingImage: PreparedCustomAppIconImage?
    @State private var renderedIcon: RenderedCustomAppIcon?
    @State private var isShowingCropEditor = false
    @State private var isShowingIntroDetails = false
    @State private var isProcessingImage = false
    @State private var isExporting = false
    @State private var hasExportedIcon = false
    @State private var localErrorMessage: String?

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
                            ? NSLocalizedString("选择图标图片", comment: "主屏幕图标选图按钮")
                            : NSLocalizedString("重新选择图片", comment: "主屏幕图标重新选图按钮"),
                        systemImage: "photo.on.rectangle"
                    )
                }
                .disabled(isProcessingImage || isExporting)

                Button {
                    isExporting = true
                } label: {
                    Label(NSLocalizedString("导出图标图片", comment: "保存裁切后的 PNG"), systemImage: "square.and.arrow.up")
                }
                .disabled(renderedIcon == nil || isProcessingImage || isExporting)
            } header: {
                Text(NSLocalizedString("图标图片", comment: "主屏幕图标图片分组"))
            } footer: {
                Text(NSLocalizedString("将裁好的 PNG 存到“文件”，稍后在快捷指令中选取。图片仅在设备上处理。", comment: "图标导出说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            if isProcessingImage {
                Section {
                    ProgressView(NSLocalizedString("正在处理图片…", comment: "图标图片处理进度"))
                }
            } else if hasExportedIcon {
                Section {
                    Label(NSLocalizedString("图片已导出，请继续设置快捷指令。", comment: "导出成功提示"), systemImage: "checkmark.circle")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    openURL(URL(string: "shortcuts://create-shortcut")!) { accepted in
                        if !accepted {
                            localErrorMessage = NSLocalizedString("无法打开快捷指令，请确认已安装“快捷指令”App。", comment: "快捷指令启动失败")
                        }
                    }
                } label: {
                    Label(NSLocalizedString("前往快捷指令创建", comment: "打开系统快捷指令编辑器"), systemImage: "arrow.up.forward.app")
                }
                .disabled(isProcessingImage)
            } footer: {
                Text(NSLocalizedString("打开后需手动添加“打开 App”动作，并选择 ETOS LLM Studio。", comment: "新建快捷指令说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Label(
                    NSLocalizedString("添加“打开 App”动作，将目标设为 ETOS LLM Studio。", comment: "设置快捷指令动作"),
                    systemImage: "1.circle"
                )
                Label(
                    NSLocalizedString("打开快捷指令的详情或名称菜单，选择“添加到主屏幕”。", comment: "添加主屏幕图标"),
                    systemImage: "2.circle"
                )
                Label(
                    NSLocalizedString("轻点图标，选择“选取文件”，再选择导出的 PNG。", comment: "选取主屏幕图标图片"),
                    systemImage: "3.circle"
                )
                Label(
                    NSLocalizedString("填写主屏幕名称并轻点“添加”。", comment: "完成主屏幕图标设置"),
                    systemImage: "4.circle"
                )
            } header: {
                Text(NSLocalizedString("设置步骤", comment: "主屏幕图标快捷指令步骤"))
            } footer: {
                Text(NSLocalizedString("请使用“打开 App”，不要使用“打开 URL”。", comment: "避免浏览器中转"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("主屏幕图标", comment: "主屏幕图标页面标题"))
        .navigationBarTitleDisplayMode(.inline)
        .guideSettingsPageContext(
            id: "settings-app-icon",
            title: NSLocalizedString("主屏幕图标", comment: "主屏幕图标向导标题"),
            documents: [GuideDocumentReference(id: "settings-app-icon", title: NSLocalizedString("主屏幕图标", comment: ""))],
            isActive: !isShowingCropEditor && !isShowingIntroDetails && !isExporting,
            settings: [
                .readOnly("image_ready", label: NSLocalizedString("图标图片", comment: ""), value: { .bool(renderedIcon != nil) }),
                .readOnly("processing_image", label: NSLocalizedString("正在处理图片…", comment: ""), value: { .bool(isProcessingImage) }),
                .readOnly("image_exported", label: NSLocalizedString("导出图标图片", comment: ""), value: { .bool(hasExportedIcon) })
            ]
        )
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
                    onCancel: { isShowingCropEditor = false },
                    onConfirm: { cropRect in
                        renderSelectedIcon(from: pendingImage, cropRect: cropRect)
                    }
                )
            }
        }
        .sheet(isPresented: $isShowingIntroDetails) {
            NavigationStack {
                ScrollView {
                    Text(NSLocalizedString("自定义主屏幕图标说明正文", comment: "主屏幕图标完整教程"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(NSLocalizedString("主屏幕图标", comment: "主屏幕图标教程标题"))
                .navigationBarTitleDisplayMode(.inline)
                .guideSettingsPageContext(
                    id: "settings-app-icon-intro",
                    title: NSLocalizedString("主屏幕图标", comment: ""),
                    documents: [GuideDocumentReference(id: "settings-app-icon", title: NSLocalizedString("主屏幕图标", comment: ""))],
                    settings: [
                        .readOnly("instructions", label: NSLocalizedString("设置步骤", comment: ""), value: {
                            .string(NSLocalizedString("自定义主屏幕图标说明正文", comment: ""))
                        })
                    ]
                )
            }
        }
        // 导出器由系统管理文件位置与写入；页面只交付后台编码完成的 PNG 数据。
        .fileExporter(
            isPresented: $isExporting,
            document: renderedIcon.map { CustomAppIconExportDocument(data: $0.pngData) },
            contentType: .png,
            defaultFilename: "ETOS-Icon.png"
        ) { result in
            switch result {
            case .success:
                hasExportedIcon = true
            case .failure(let error):
                guard (error as? CocoaError)?.code != .userCancelled else { return }
                localErrorMessage = String(
                    format: NSLocalizedString("图标导出失败：%@", comment: "图标导出错误"),
                    error.localizedDescription
                )
            }
        }
        .alert(NSLocalizedString("无法创建主屏幕图标", comment: "主屏幕图标错误标题"), isPresented: errorPresented) {
            Button(NSLocalizedString("确定", comment: "关闭错误提示"), role: .cancel) {}
        } message: {
            Text(localErrorMessage ?? "")
        }
    }

    private var settingsIntroCard: some View {
        VStack(alignment: .leading) {
            Text(NSLocalizedString("使用自己的图片", comment: "主屏幕图标介绍标题"))
                .etFont(.headline.weight(.semibold))
            Text(NSLocalizedString("裁切并导出图片，再通过快捷指令设置主屏幕图标。", comment: "主屏幕图标介绍摘要"))
                .etFont(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                isShowingIntroDetails = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: "打开主屏幕图标教程"))
                    .etFont(.footnote)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            .accessibilityLabel(NSLocalizedString("图标预览", comment: "主屏幕图标预览辅助功能标签"))
            Spacer()
        }
        .padding(.vertical)
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { localErrorMessage != nil },
            set: { if !$0 { localErrorMessage = nil } }
        )
    }

    private func prepareSelectedPhoto(_ item: PhotosPickerItem) async {
        isProcessingImage = true
        defer { isProcessingImage = false }

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
            localErrorMessage = NSLocalizedString("无法读取所选图片，请重新选择。", comment: "主屏幕图标读取图片失败")
        }
    }

    private func renderSelectedIcon(from preparedImage: PreparedCustomAppIconImage, cropRect: CGRect) {
        isShowingCropEditor = false
        isProcessingImage = true
        Task {
            defer { isProcessingImage = false }
            do {
                let icon = try await Task.detached(priority: .userInitiated) {
                    try CustomAppIconImageProcessor.renderIcon(from: preparedImage, cropRect: cropRect)
                }.value
                renderedIcon = icon
                hasExportedIcon = false
            } catch {
                localErrorMessage = NSLocalizedString("无法处理所选图片，请重新选择。", comment: "主屏幕图标处理图片失败")
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
        .guideSettingsPageContext(
            id: "settings-app-icon-crop",
            title: NSLocalizedString("裁切图标", comment: "图标裁切向导标题"),
            documents: [GuideDocumentReference(id: "settings-app-icon", title: NSLocalizedString("主屏幕图标", comment: ""))],
            // 构图依赖用户查看图片；向导只读取取景状态，不接收图片，也不替用户确认裁切。
            settings: [
                .readOnly("zoom_scale", label: NSLocalizedString("缩放", comment: "图标裁切缩放状态"), value: { .double(Double(zoomScale)) }),
                .readOnly("offset_x", label: NSLocalizedString("水平偏移", comment: "图标裁切偏移状态"), value: { .double(Double(imageOffset.width)) }),
                .readOnly("offset_y", label: NSLocalizedString("垂直偏移", comment: "图标裁切偏移状态"), value: { .double(Double(imageOffset.height)) })
            ]
        )
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
