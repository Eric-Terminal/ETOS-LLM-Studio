// ============================================================================
// ImageGenerationFeatureView.swift
// ============================================================================
// 图片相册入口 (watchOS)
// - 只展示当前会话中助手返回并落盘的图片
// - 小屏保持直接进入相册，避免独立生成工作流占用层级
// ============================================================================

import SwiftUI

struct ImageGenerationFeatureView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    var body: some View {
        WatchImageGenerationGalleryView()
            .environmentObject(viewModel)
    }
}
