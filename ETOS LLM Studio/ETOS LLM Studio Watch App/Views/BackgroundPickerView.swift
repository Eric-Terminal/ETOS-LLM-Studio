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
                    ForEach(allBackgrounds, id: \.self) { bgName in
                        Button(action: {
                            selectedBackground = bgName
                        }) {
                            FileImage(filename: bgName)
                                .aspectRatio(previewAspectRatio, contentMode: .fill)
                                .frame(width: itemWidth, height: itemHeight)
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(selectedBackground == bgName ? Color.blue : Color.clear, lineWidth: 3)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, gridPadding)
                .padding(.vertical, gridPadding)
            }
        }
        .navigationTitle("选择背景")
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
            } else {
                // 加载失败或加载中时显示的占位符
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay(Image(systemName: "photo"))
            }
        }
        .onAppear(perform: loadImage)
    }
    
    private func loadImage() {
        // 在后台线程加载图片以避免卡顿 UI
        DispatchQueue.global().async {
            let fileURL = ConfigLoader.getBackgroundsDirectory().appendingPathComponent(filename)
            if let image = UIImage(contentsOfFile: fileURL.path) {
                DispatchQueue.main.async {
                    self.uiImage = image
                }
            }
        }
    }
}
