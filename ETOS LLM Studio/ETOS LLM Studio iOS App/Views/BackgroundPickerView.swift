import SwiftUI
import Shared
import UIKit
import PhotosUI

struct BackgroundPickerView: View {
    let allBackgrounds: [String]
    @Binding var selectedBackground: String
    
    @State private var backgrounds: [String] = []
    @State private var selectedItem: PhotosPickerItem?
    @State private var isShowingPhotoPicker = false
    @State private var pendingCropImage: UIImage?
    @State private var isShowingCropEditor = false
    @State private var isSaving = false
    @State private var saveErrorMessage: String?
    @State private var deleteCandidate: String?
    @State private var isShowingDeleteConfirmation = false
    @State private var deleteErrorMessage: String?
    @AppStorage("backgroundCropTarget") private var backgroundCropTargetRawValue = BackgroundCropTarget.phone.rawValue
    
    private let gridSpacing: CGFloat = 16
    private let gridPadding: CGFloat = 16
    private var previewAspectRatio: CGFloat {
        let size = UIScreen.main.bounds.size
        guard size.height > 0 else { return 9.0 / 16.0 }
        return size.width / size.height
    }
    
    private var selectedCropTarget: BackgroundCropTarget {
        get { BackgroundCropTarget(rawValue: backgroundCropTargetRawValue) ?? .phone }
        nonmutating set { backgroundCropTargetRawValue = newValue.rawValue }
    }
    
    var body: some View {
        contentView
            .navigationTitle("选择背景")
            .toolbar { addBackgroundToolbar }
            .photosPicker(isPresented: $isShowingPhotoPicker, selection: $selectedItem, matching: .images)
            .onChange(of: selectedItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    await prepareCropImage(from: newItem)
                }
            }
            .sheet(isPresented: $isShowingCropEditor, onDismiss: {
                pendingCropImage = nil
                selectedItem = nil
            }) {
                cropEditorSheetContent
            }
            .alert("无法保存背景", isPresented: saveErrorAlertPresentedBinding) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(saveErrorMessage ?? "")
            }
            .alert("删除背景", isPresented: $isShowingDeleteConfirmation, presenting: deleteCandidate) { name in
                Button("删除", role: .destructive) {
                    deleteCandidate = nil
                    Task {
                        await deleteBackground(named: name)
                    }
                }
                Button("取消", role: .cancel) {
                    deleteCandidate = nil
                }
            } message: { _ in
                Text("确定删除这张背景吗？")
            }
            .alert("无法删除背景", isPresented: deleteErrorAlertPresentedBinding) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(deleteErrorMessage ?? "")
            }
            .task {
                let loaded = ConfigLoader.loadBackgroundImages()
                backgrounds = loaded.isEmpty ? allBackgrounds : loaded
            }
    }
    
    private var contentView: some View {
        GeometryReader { proxy in
            let availableWidth = proxy.size.width - gridPadding * 2
            let itemWidth = max((availableWidth - gridSpacing) / 2, 0)
            let itemHeight = itemWidth / previewAspectRatio
            let columns = [
                GridItem(.fixed(itemWidth), spacing: gridSpacing),
                GridItem(.fixed(itemWidth), spacing: gridSpacing)
            ]
            
            ScrollView {
                LazyVGrid(columns: columns, spacing: gridSpacing) {
                    ForEach(backgrounds, id: \.self) { name in
                        Button {
                            selectedBackground = name
                        } label: {
                            FileImage(filename: name)
                                .aspectRatio(previewAspectRatio, contentMode: .fill)
                                .frame(width: itemWidth, height: itemHeight)
                                .clipped()
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(selectedBackground == name ? Color.accentColor : .clear, lineWidth: 4)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                deleteCandidate = name
                                isShowingDeleteConfirmation = true
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, gridPadding)
                .padding(.vertical, gridPadding)
            }
        }
    }
    
    @ToolbarContentBuilder
    private var addBackgroundToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                isShowingPhotoPicker = true
            } label: {
                Image(systemName: "plus")
            }
            .disabled(isSaving)
        }
    }
    
    @ViewBuilder
    private var cropEditorSheetContent: some View {
        if let pendingCropImage {
            BackgroundCropEditorView(
                sourceImage: pendingCropImage,
                initialTarget: selectedCropTarget,
                onCancel: {
                    isShowingCropEditor = false
                    selectedItem = nil
                },
                onConfirm: { croppedImage, target in
                    selectedCropTarget = target
                    isShowingCropEditor = false
                    Task {
                        await saveBackground(image: croppedImage)
                    }
                }
            )
        } else {
            ProgressView()
                .presentationDetents([.medium])
        }
    }
    
    private var saveErrorAlertPresentedBinding: Binding<Bool> {
        Binding(
            get: { saveErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    saveErrorMessage = nil
                }
            }
        )
    }
    
    private var deleteErrorAlertPresentedBinding: Binding<Bool> {
        Binding(
            get: { deleteErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    deleteErrorMessage = nil
                }
            }
        )
    }
    
    private func prepareCropImage(from item: PhotosPickerItem) async {
        await MainActor.run {
            isSaving = true
        }
        defer {
            Task { @MainActor in
                isSaving = false
            }
        }
        
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            showSaveError("无法读取图片数据。")
            return
        }
        guard let image = UIImage(data: data) else {
            showSaveError("无法解析图片。")
            return
        }

        await MainActor.run {
            pendingCropImage = image.normalizedForBackgroundEditing()
            isShowingCropEditor = true
        }
    }
    
    private func saveBackground(image: UIImage) async {
        await MainActor.run {
            isSaving = true
        }
        defer {
            Task { @MainActor in
                isSaving = false
            }
        }
        
        let normalized = image.normalizedForBackgroundEditing()
        guard let jpegData = normalized.jpegData(compressionQuality: 0.9) else {
            showSaveError("无法处理图片格式。")
            return
        }
        
        ConfigLoader.setupBackgroundsDirectory()
        let filename = "background-\(UUID().uuidString).jpg"
        let url = ConfigLoader.getBackgroundsDirectory().appendingPathComponent(filename)
        
        do {
            try jpegData.write(to: url, options: [.atomic])
        } catch {
            showSaveError("保存失败：\(error.localizedDescription)")
            return
        }
        
        await MainActor.run {
            pendingCropImage = nil
            selectedBackground = filename
            backgrounds = ConfigLoader.loadBackgroundImages()
            NotificationCenter.default.post(name: .syncBackgroundsUpdated, object: nil)
            selectedItem = nil
        }
    }

    private func deleteBackground(named name: String) async {
        let url = ConfigLoader.getBackgroundsDirectory().appendingPathComponent(name)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            await MainActor.run {
                deleteErrorMessage = "删除失败：\(error.localizedDescription)"
            }
            return
        }

        await MainActor.run {
            let updated = ConfigLoader.loadBackgroundImages()
            backgrounds = updated
            if !updated.contains(selectedBackground) {
                selectedBackground = updated.first ?? ""
            }
            NotificationCenter.default.post(name: .syncBackgroundsUpdated, object: nil)
        }
    }
    
    @MainActor
    private func showSaveError(_ message: String) {
        saveErrorMessage = message
        pendingCropImage = nil
        isShowingCropEditor = false
        selectedItem = nil
    }
}

private enum BackgroundCropTarget: String, CaseIterable, Identifiable {
    case phone
    case watch
    
    var id: String { rawValue }
    
    var title: LocalizedStringKey {
        switch self {
        case .phone:
            return "手机比例"
        case .watch:
            return "手表比例"
        }
    }
    
    var aspectRatio: CGFloat {
        switch self {
        case .phone:
            let size = UIScreen.main.bounds.size
            guard size.height > 0 else { return 9.0 / 16.0 }
            return size.width / size.height
        case .watch:
            return 0.82
        }
    }
}

private struct BackgroundCropEditorView: View {
    let sourceImage: UIImage
    let initialTarget: BackgroundCropTarget
    let onCancel: () -> Void
    let onConfirm: (UIImage, BackgroundCropTarget) -> Void
    @Environment(\.colorScheme) private var colorScheme
    
    @State private var selectedTarget: BackgroundCropTarget
    @State private var zoomScale: CGFloat = 1
    @State private var imageOffset: CGSize = .zero
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var pinchScale: CGFloat = 1
    
    init(
        sourceImage: UIImage,
        initialTarget: BackgroundCropTarget,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (UIImage, BackgroundCropTarget) -> Void
    ) {
        self.sourceImage = sourceImage
        self.initialTarget = initialTarget
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _selectedTarget = State(initialValue: initialTarget)
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("裁切比例", selection: $selectedTarget) {
                    ForEach(BackgroundCropTarget.allCases) { target in
                        Text(target.title).tag(target)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                
                Text("拖动和缩放以调整取景范围")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                
                GeometryReader { proxy in
                    let canvasSize = proxy.size
                    let cropRect = cropRect(in: canvasSize, aspectRatio: selectedTarget.aspectRatio)
                    let currentScale = combinedScale
                    let renderedSize = renderedImageSize(for: cropRect, scale: currentScale)
                    let effectiveOffset = effectiveOffset(for: renderedSize, cropRect: cropRect)
                    
                    ZStack {
                        cropCanvasBackground
                            .ignoresSafeArea()
                        
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
                            .onChange(of: selectedTarget) { _, _ in
                                imageOffset = clampOffset(imageOffset, renderedSize: renderedSize, cropRect: cropRect)
                            }
                            .onChange(of: zoomScale) { _, _ in
                                imageOffset = clampOffset(imageOffset, renderedSize: renderedSize, cropRect: cropRect)
                            }
                        
                        cropOverlay(canvasSize: canvasSize, cropRect: cropRect)
                            .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .drawingGroup()
                    .compositingGroup()
                    .onAppear {
                        imageOffset = clampOffset(imageOffset, renderedSize: renderedSize, cropRect: cropRect)
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("取消", action: onCancel)
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("保存") {
                                guard let output = makeCroppedImage(cropRect: cropRect, renderedSize: renderedSize, offset: effectiveOffset) else {
                                    return
                                }
                                onConfirm(output, selectedTarget)
                            }
                        }
                    }
                }
            }
            .navigationTitle("裁切背景")
            .navigationBarTitleDisplayMode(.inline)
            .background(editorPageBackground.ignoresSafeArea())
        }
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
    }
    
    private var editorPageBackground: Color {
        Color(uiColor: .systemBackground)
    }
    
    private var cropCanvasBackground: Color {
        if colorScheme == .dark {
            return Color.black.opacity(0.9)
        }
        return Color(uiColor: .systemBackground)
    }
    
    private var cropMaskColor: Color {
        if colorScheme == .dark {
            return Color.black.opacity(0.5)
        }
        return Color.white.opacity(0.7)
    }
    
    private var cropBorderColor: Color {
        if colorScheme == .dark {
            return .white.opacity(0.95)
        }
        return Color(uiColor: .label).opacity(0.8)
    }
    
    private var combinedScale: CGFloat {
        min(max(zoomScale * pinchScale, 1), 6)
    }
    
    private func renderedImageSize(for cropRect: CGRect, scale: CGFloat) -> CGSize {
        let baseScale = max(cropRect.width / sourceImage.size.width, cropRect.height / sourceImage.size.height)
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
                let next = CGSize(
                    width: imageOffset.width + value.translation.width,
                    height: imageOffset.height + value.translation.height
                )
                let renderedSize = renderedImageSize(for: cropRect, scale: combinedScale)
                imageOffset = clampOffset(next, renderedSize: renderedSize, cropRect: cropRect)
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
        let merged = CGSize(
            width: imageOffset.width + dragTranslation.width,
            height: imageOffset.height + dragTranslation.height
        )
        return clampOffset(merged, renderedSize: renderedSize, cropRect: cropRect)
    }
    
    private func clampOffset(_ offset: CGSize, renderedSize: CGSize, cropRect: CGRect) -> CGSize {
        let maxX = max((renderedSize.width - cropRect.width) / 2, 0)
        let maxY = max((renderedSize.height - cropRect.height) / 2, 0)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }
    
    private func cropRect(in size: CGSize, aspectRatio: CGFloat) -> CGRect {
        // 给裁切框预留足够安全边距，避免边框贴边被裁掉。
        // 手表比例更接近正方形，优先加大水平边距，确保左右边框始终可见。
        let horizontalInset: CGFloat = aspectRatio > 0.7 ? 40 : 22
        let verticalInset: CGFloat = aspectRatio > 0.7 ? 24 : 20
        let maxWidth = max(size.width - horizontalInset * 2, 1)
        let maxHeight = max(size.height - verticalInset * 2, 1)
        
        let widthBasedHeight = maxWidth / aspectRatio
        let cropSize: CGSize
        if widthBasedHeight <= maxHeight {
            cropSize = CGSize(width: maxWidth, height: widthBasedHeight)
        } else {
            cropSize = CGSize(width: maxHeight * aspectRatio, height: maxHeight)
        }
        
        let origin = CGPoint(
            x: (size.width - cropSize.width) / 2,
            y: (size.height - cropSize.height) / 2
        )
        return CGRect(origin: origin, size: cropSize)
    }
    
    @ViewBuilder
    private func cropOverlay(canvasSize: CGSize, cropRect: CGRect) -> some View {
        ZStack {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: canvasSize))
                path.addRoundedRect(
                    in: cropRect,
                    cornerSize: CGSize(width: 20, height: 20),
                    style: .continuous
                )
            }
            .fill(cropMaskColor, style: FillStyle(eoFill: true))
            
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(cropBorderColor, lineWidth: 2)
                .frame(width: cropRect.width, height: cropRect.height)
                .position(x: cropRect.midX, y: cropRect.midY)
        }
    }
    
    private func makeCroppedImage(cropRect: CGRect, renderedSize: CGSize, offset: CGSize) -> UIImage? {
        guard let cgImage = sourceImage.cgImage else { return nil }
        
        let imageFrame = CGRect(
            x: cropRect.midX + offset.width - renderedSize.width / 2,
            y: cropRect.midY + offset.height - renderedSize.height / 2,
            width: renderedSize.width,
            height: renderedSize.height
        )
        
        let cropInPoints = CGRect(
            x: (cropRect.minX - imageFrame.minX) / renderedSize.width * sourceImage.size.width,
            y: (cropRect.minY - imageFrame.minY) / renderedSize.height * sourceImage.size.height,
            width: cropRect.width / renderedSize.width * sourceImage.size.width,
            height: cropRect.height / renderedSize.height * sourceImage.size.height
        )
        
        let boundedPoints = cropInPoints.intersection(CGRect(origin: .zero, size: sourceImage.size))
        guard !boundedPoints.isNull, boundedPoints.width > 1, boundedPoints.height > 1 else { return nil }
        
        let pxPerPointX = CGFloat(cgImage.width) / sourceImage.size.width
        let pxPerPointY = CGFloat(cgImage.height) / sourceImage.size.height
        var pixelRect = CGRect(
            x: boundedPoints.origin.x * pxPerPointX,
            y: boundedPoints.origin.y * pxPerPointY,
            width: boundedPoints.width * pxPerPointX,
            height: boundedPoints.height * pxPerPointY
        ).integral
        pixelRect = pixelRect.intersection(CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        
        guard pixelRect.width > 1, pixelRect.height > 1, let croppedCGImage = cgImage.cropping(to: pixelRect) else {
            return nil
        }
        
        return UIImage(cgImage: croppedCGImage, scale: sourceImage.scale, orientation: .up)
    }
}

private extension UIImage {
    func normalizedForBackgroundEditing() -> UIImage {
        guard size.width > 0, size.height > 0 else { return self }
        
        if imageOrientation == .up, cgImage != nil {
            return self
        }
        
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

private struct FileImage: View {
    let filename: String
    @State private var image: UIImage?
    
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(Color.secondary.opacity(0.1))
                    ProgressView()
                }
            }
        }
        .task {
            await loadImage()
        }
    }
    
    private func loadImage() async {
        let url = ConfigLoader.getBackgroundsDirectory().appendingPathComponent(filename)
        if let loaded = UIImage(contentsOfFile: url.path) {
            await MainActor.run {
                image = loaded
            }
        }
    }
}
