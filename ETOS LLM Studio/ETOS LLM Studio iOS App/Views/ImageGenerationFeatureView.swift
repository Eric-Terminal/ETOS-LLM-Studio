// ============================================================================
// ImageGenerationFeatureView.swift
// ============================================================================
// 图片相册入口 (iOS)
// - 只展示当前会话中助手返回并落盘的图片
// - 图片生成能力保留在聊天请求链路中
// ============================================================================

import SwiftUI

struct ImageGenerationFeatureView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    var body: some View {
        ImageGenerationGalleryView()
            .environmentObject(viewModel)
    }
}
