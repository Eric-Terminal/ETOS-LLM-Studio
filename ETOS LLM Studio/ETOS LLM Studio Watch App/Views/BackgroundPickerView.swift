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
import Shared
import WatchKit

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
                .padding(.vertical, gridPadding)
            }
        }
        .navigationTitle("选择背景")
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
        .alert("无法删除背景", isPresented: Binding(get: {
            deleteErrorMessage != nil
        }, set: { newValue in
            if !newValue {
                deleteErrorMessage = nil
            }
        })) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "")
        }
        .task {
            let loaded = ConfigLoader.loadBackgroundImages()
            backgrounds = loaded.isEmpty ? allBackgrounds : loaded
        }
    }
    
    // MARK: - 私有方法
    
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
}

// MARK: - 辅助视图

/// 一个辅助视图，用于从文件系统异步加载和显示图像。
private struct FileImage: View {
    let filename: String
    
    @State private var uiImage: UIImage? = nil
    
    var body: some View {
        Group {
            if let image = uiImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
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
        if let image = UIImage(contentsOfFile: fileURL.path) {
            await MainActor.run {
                self.uiImage = image
            }
        }
    }
}
