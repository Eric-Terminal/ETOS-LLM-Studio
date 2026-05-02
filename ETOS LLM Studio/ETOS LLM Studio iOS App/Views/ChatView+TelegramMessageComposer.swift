// ============================================================================
// ChatView+TelegramMessageComposer.swift
// ============================================================================
// iOS Telegram 风格输入栏的状态、依赖与基础声明。
// ============================================================================

import SwiftUI
import Foundation
import MarkdownUI
import Shared
import UIKit
import PhotosUI
import Photos
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Telegram 主题颜色

/// Telegram 风格的消息输入框
struct TelegramMessageComposer: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) var colorScheme
    @Binding var text: String
    let isSending: Bool
    let sendAction: () -> Void
    let stopAction: () -> Void
    let focus: FocusState<Bool>.Binding
    
    @State var showImagePicker = false
    @State var showCamera = false
    @State var showAudioRecorder = false
    @State var audioRecorderSheetDetent: PresentationDetent = .fraction(0.5)
    @State var audioRecorderEntryMode: AudioRecorderEntryMode = .attachment
    @State var showAudioImporter = false
    @State var showFileImporter = false
    @State var selectedPhotos: [PhotosPickerItem] = []
    @State var isExpandedComposer = false
    @State var inputAvailableWidth: CGFloat = 0
    @State var compactInputWidth: CGFloat = 0
    @AppStorage(FontLibrary.customFontEnabledStorageKey) var isCustomFontEnabled: Bool = true
    @AppStorage(FontLibrary.fontScaleStorageKey) var customFontScale: Double = FontLibrary.defaultFontScale
    
    let controlSize: CGFloat = 40
    let expandedControlSize: CGFloat = 34
    let inputBasePointSize: CGFloat = 16
    let textContainerInset: CGFloat = 8
    let textHorizontalPadding: CGFloat = 10
}
