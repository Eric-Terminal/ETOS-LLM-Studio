// ============================================================================
// BackgroundPickerView.swift
// ============================================================================
// ETOS LLM Studio Watch App 背景图片选择器视图
//
// 功能特性:
// - 以网格形式展示所有可选的背景图片
// - 允许用户点击选择背景
// ============================================================================

import SwiftUI
import ETOSCore
import WatchKit
import Foundation
import AVFoundation

/// 背景图片选择器视图
struct BackgroundPickerView: View {
    
    // MARK: - 属性与绑定
    
    let allBackgrounds: [String]
    @Binding var selectedBackground: String
    
    // MARK: - 私有状态
    
    @State private var backgrounds: [String] = []
    @State private var deleteCandidate: String?
    @State private var isShowingDeleteConfirmation = false
    @State private var deleteErrorMessage: String?
    @State private var isShowingImportSheet = false
    @State private var importSourceText = ""
    @State private var isImportingBackground = false
    @State private var importDownloadProgress: SyncPackageDownloadProgress?
    @State private var importErrorMessage: String?
    @State private var backgroundSourceHistory: [String] = []
    @ObservedObject private var appConfig = AppConfigStore.shared
    
    // MARK: - 私有属性
    
    private let gridSpacing: CGFloat = 10
    private let gridPadding: CGFloat = 10
    private var previewAspectRatio: CGFloat {
        let size = WKInterfaceDevice.current().screenBounds.size
        guard size.height > 0 else { return 1 }
        return size.width / size.height
    }
    
    // MARK: - 视图主体
    
    var body: some View {
        GeometryReader { proxy in
            let availableWidth = proxy.size.width - gridPadding * 2
            let itemWidth = max((availableWidth - gridSpacing) / 2, 0)
            let itemHeight = itemWidth / previewAspectRatio
            let columns = [
                GridItem(.fixed(itemWidth), spacing: gridSpacing),
                GridItem(.fixed(itemWidth), spacing: gridSpacing)
            ]
            
            VStack(spacing: 8) {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: gridSpacing) {
                        ForEach(backgrounds, id: \.self) { bgName in
                            Button(action: {
                                selectedBackground = bgName
                            }) {
                                FileImage(filename: bgName)
                                    .aspectRatio(previewAspectRatio, contentMode: .fill)
                                    .frame(width: itemWidth, height: itemHeight)
                                    .clipped()
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(selectedBackground == bgName ? Color.accentColor : .clear, lineWidth: 3)
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, gridPadding)
                    .padding(.top, gridPadding)
                    .padding(.bottom, gridPadding)
                }

                if isImportingBackground || importDownloadProgress != nil {
                    WatchBackgroundDownloadProgressView(progress: importDownloadProgress)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }
            }
        }
        .navigationTitle(NSLocalizedString("选择背景", comment: ""))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    deleteCandidate = selectedBackground
                    isShowingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selectedBackground.isEmpty)
            }

            ToolbarItem(placement: .bottomBar) {
                HStack {
                    Button {
                        showImportSheet()
                    } label: {
                        if isImportingBackground {
                            ProgressView()
                        } else {
                            Image(systemName: "plus")
                        }
                    }
                    .disabled(isImportingBackground)
                    .accessibilityLabel(NSLocalizedString("添加背景", comment: ""))

                    Spacer()
                }
            }
        }
        .alert(NSLocalizedString("删除背景", comment: ""), isPresented: $isShowingDeleteConfirmation, presenting: deleteCandidate) { name in
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                deleteCandidate = nil
                Task {
                    await deleteBackground(named: name)
                }
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                deleteCandidate = nil
            }
        } message: { _ in
            Text(NSLocalizedString("确定删除这张背景吗？", comment: ""))
        }
        .alert(NSLocalizedString("无法删除背景", comment: ""), isPresented: Binding(get: {
            deleteErrorMessage != nil
        }, set: { newValue in
            if !newValue {
                deleteErrorMessage = nil
            }
        })) {
            Button(NSLocalizedString("确定", comment: ""), role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "")
        }
        .sheet(isPresented: $isShowingImportSheet) {
            NavigationStack {
                WatchImportSourceView(
                    source: $importSourceText,
                    history: backgroundSourceHistory,
                    isImporting: isImportingBackground,
                    title: NSLocalizedString("添加背景", comment: ""),
                    placeholder: NSLocalizedString("背景图片或视频链接", comment: ""),
                    progressTitle: NSLocalizedString("正在下载并导入...", comment: ""),
                    confirmTitle: NSLocalizedString("导入", comment: ""),
                    onImport: {
                        let trimmedSource = importSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
                        rememberBackgroundSource(trimmedSource)
                        importBackground(from: trimmedSource)
                        isShowingImportSheet = false
                    },
                    onCancel: {
                        isShowingImportSheet = false
                    }
                )
            }
        }
        .alert(NSLocalizedString("无法添加背景", comment: ""), isPresented: Binding(get: {
            importErrorMessage != nil
        }, set: { newValue in
            if !newValue {
                importErrorMessage = nil
            }
        })) {
            Button(NSLocalizedString("确定", comment: ""), role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "")
        }
        .onChange(of: appConfig.watchAttachmentSourceHistory) { _, _ in
            refreshBackgroundSourceHistory()
        }
        .onChange(of: appConfig.watchAttachmentLastSource) { _, _ in
            refreshBackgroundSourceHistory()
        }
        .task {
            refreshBackgroundSourceHistory()
            let loaded = await Task.detached(priority: .utility) {
                ConfigLoader.loadBackgroundImages()
            }.value
            backgrounds = loaded.isEmpty ? allBackgrounds : loaded
        }
    }
    
    // MARK: - 私有方法

    private func showImportSheet() {
        importSourceText = backgroundSourceHistory.first ?? appConfig.watchAttachmentLastSource
        if importSourceText.isEmpty {
            importSourceText = appConfig.watchBackgroundLastSource
        }
        isShowingImportSheet = true
    }

    private func rememberBackgroundSource(_ source: String) {
        let updatedHistory = WatchImportSourceHistory.appending(
            source,
            to: backgroundSourceHistory
        )
        appConfig.watchAttachmentSourceHistory = WatchImportSourceHistory.rawValue(for: updatedHistory)
        appConfig.watchAttachmentLastSource = updatedHistory.first ?? ""
        backgroundSourceHistory = updatedHistory
    }

    private func refreshBackgroundSourceHistory() {
        let attachmentRawValue = appConfig.watchAttachmentSourceHistory
        let attachmentFallback = appConfig.watchAttachmentLastSource
        let backgroundRawValue = appConfig.watchBackgroundSourceHistory
        let backgroundFallback = appConfig.watchBackgroundLastSource
        Task {
            let history = await Task.detached(priority: .utility) {
                let attachmentHistory = WatchImportSourceHistory.values(
                    from: attachmentRawValue,
                    fallback: attachmentFallback
                )
                let backgroundHistory = WatchImportSourceHistory.values(
                    from: backgroundRawValue,
                    fallback: backgroundFallback
                )
                return WatchImportSourceHistory.normalized(attachmentHistory + backgroundHistory)
            }.value
            await MainActor.run {
                backgroundSourceHistory = history
                let rawHistory = WatchImportSourceHistory.rawValue(for: history)
                if rawHistory != appConfig.watchAttachmentSourceHistory {
                    appConfig.watchAttachmentSourceHistory = rawHistory
                    appConfig.watchAttachmentLastSource = history.first ?? ""
                }
            }
        }
    }

    private func importBackground(from source: String) {
        guard !isImportingBackground else { return }
        isImportingBackground = true
        importDownloadProgress = nil
        importErrorMessage = nil

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                try await WatchBackgroundImporter.loadRemoteBackground(
                    from: source,
                    progress: { progress in
                        Task { @MainActor in
                            importDownloadProgress = progress
                        }
                    }
                )
            }.result

            switch result {
            case .success(let fileName):
                let updated = await Task.detached(priority: .utility) {
                    ConfigLoader.loadBackgroundImages()
                }.value
                await MainActor.run {
                    isImportingBackground = false
                    importDownloadProgress = nil
                    selectedBackground = fileName
                    backgrounds = updated
                    NotificationCenter.default.post(name: .syncBackgroundsUpdated, object: nil)
                    importSourceText = ""
                }
            case .failure(let error):
                await MainActor.run {
                    isImportingBackground = false
                    importDownloadProgress = nil
                    importErrorMessage = error.localizedDescription
                }
            }
        }
    }
    
    private func deleteBackground(named name: String) async {
        let url = ConfigLoader.getBackgroundsDirectory().appendingPathComponent(name)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            await MainActor.run {
                deleteErrorMessage = String(format: NSLocalizedString("删除失败：%@", comment: ""), error.localizedDescription)
            }
            return
        }

        await MainActor.run {
            backgrounds.removeAll { $0 == name }
            if selectedBackground == name {
                selectedBackground = backgrounds.first ?? ""
            }
            NotificationCenter.default.post(name: .syncBackgroundsUpdated, object: nil)
        }
    }
}

private struct WatchBackgroundDownloadProgressView: View {
    let progress: SyncPackageDownloadProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(NSLocalizedString("正在下载并导入...", comment: ""))
                Spacer()
                if let progress, progress.totalBytes > 0 {
                    Text(String(format: "%.0f%%", progress.fractionCompleted * 100))
                        .monospacedDigit()
                } else {
                    ProgressView()
                }
            }
            .etFont(.caption2)

            if let progress, progress.totalBytes > 0 {
                ProgressView(value: progress.fractionCompleted)
                    .progressViewStyle(.linear)
                Text(
                    String(
                        format: NSLocalizedString("已下载 %@ / %@", comment: ""),
                        StorageUtility.formatTransferSize(progress.bytesReceived),
                        StorageUtility.formatTransferSize(progress.totalBytes)
                    )
                )
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private enum WatchBackgroundImporter {
    static func loadRemoteBackground(
        from rawSource: String,
        progress: SyncPackageUploadService.DownloadProgressHandler? = nil
    ) async throws -> String {
        let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { throw WatchBackgroundImportError.emptySource }
        guard let url = URL(string: source), let scheme = url.scheme?.lowercased(), url.host?.isEmpty == false else {
            throw WatchBackgroundImportError.invalidURL
        }
        guard scheme == "http" || scheme == "https" else {
            throw WatchBackgroundImportError.unsupportedScheme
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = NetworkSessionConfiguration.minimumRequestTimeout
        let (downloadedURL, response) = try await SyncPackageUploadService.downloadTemporaryFile(
            request: request,
            progress: progress
        )
        defer { try? FileManager.default.removeItem(at: downloadedURL) }
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw WatchBackgroundImportError.invalidHTTPStatus(httpResponse.statusCode)
        }
        let fileSize = Self.fileSize(at: downloadedURL)
        if fileSize > 0 {
            progress?(SyncPackageDownloadProgress(bytesReceived: fileSize, totalBytes: fileSize))
        }
        if let videoExtension = Self.backgroundVideoExtension(for: url, response: response) {
            return try Self.storeVideoBackground(from: downloadedURL, fileExtension: videoExtension)
        }

        let data = try await Task.detached(priority: .utility) {
            try Data(contentsOf: downloadedURL)
        }.value
        guard let image = UIImage(data: data) else {
            throw WatchBackgroundImportError.invalidImage
        }
        guard let jpegData = image.jpegData(compressionQuality: 0.9) else {
            throw WatchBackgroundImportError.unsupportedImageFormat
        }

        ConfigLoader.setupBackgroundsDirectory()
        let fileName = "background-\(UUID().uuidString).jpg"
        let fileURL = ConfigLoader.getBackgroundsDirectory().appendingPathComponent(fileName)
        do {
            try jpegData.write(to: fileURL, options: [.atomic])
        } catch {
            throw WatchBackgroundImportError.writeFailed(error.localizedDescription)
        }
        return fileName
    }

    private static func backgroundVideoExtension(for url: URL, response: URLResponse) -> String? {
        let pathExtension = url.pathExtension.lowercased()
        if ConfigLoader.supportedBackgroundVideoExtensions.contains(pathExtension) {
            return pathExtension
        }
        guard let mimeType = response.mimeType?.lowercased(), mimeType.hasPrefix("video/") else {
            return nil
        }
        if mimeType.contains("quicktime") {
            return "mov"
        }
        if mimeType.contains("x-m4v") {
            return "m4v"
        }
        return "mp4"
    }

    private static func storeVideoBackground(from sourceURL: URL, fileExtension: String) throws -> String {
        ConfigLoader.setupBackgroundsDirectory()
        let fileName = "background-\(UUID().uuidString).\(fileExtension)"
        let fileURL = ConfigLoader.getBackgroundsDirectory().appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: fileURL)
        } catch {
            throw WatchBackgroundImportError.writeFailed(error.localizedDescription)
        }
        return fileName
    }

    private static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

private enum WatchBackgroundImportError: LocalizedError {
    case emptySource
    case invalidURL
    case unsupportedScheme
    case invalidHTTPStatus(Int)
    case invalidImage
    case unsupportedImageFormat
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptySource:
            return NSLocalizedString("链接不能为空。", comment: "")
        case .invalidURL:
            return NSLocalizedString("链接格式无效，请输入完整 URL。", comment: "")
        case .unsupportedScheme:
            return NSLocalizedString("仅支持 http/https 链接。", comment: "")
        case .invalidHTTPStatus(let statusCode):
            return String(format: NSLocalizedString("下载失败：HTTP %d", comment: ""), statusCode)
        case .invalidImage:
            return NSLocalizedString("无法解析图片。", comment: "")
        case .unsupportedImageFormat:
            return NSLocalizedString("无法处理图片格式。", comment: "")
        case .writeFailed(let message):
            return String(format: NSLocalizedString("保存失败：%@", comment: ""), message)
        }
    }
}

// MARK: - 辅助视图

/// 一个辅助视图，用于从文件系统异步加载和显示图像。
private struct FileImage: View {
    let filename: String
    
    @State private var uiImage: UIImage? = nil
    
    var body: some View {
        Group {
            if let image = uiImage {
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                    if ConfigLoader.isVideoBackgroundFile(filename) {
                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                            .shadow(radius: 3)
                    }
                }
            } else {
                // 加载失败或加载中时显示的占位符
                ZStack {
                    Rectangle().fill(Color.gray.opacity(0.3))
                    ProgressView()
                }
            }
        }
        .task {
            await loadImage()
        }
    }
    
    private func loadImage() async {
        let fileURL = ConfigLoader.getBackgroundsDirectory().appendingPathComponent(filename)
        // watchOS 不支持视频背景，只加载静态图片
        let image = UIImage(contentsOfFile: fileURL.path)
        if let image {
            await MainActor.run {
                self.uiImage = image
            }
        }
    }
}
