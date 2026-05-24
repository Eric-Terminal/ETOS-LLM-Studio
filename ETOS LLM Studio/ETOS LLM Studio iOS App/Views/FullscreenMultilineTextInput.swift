// ============================================================================
// FullscreenMultilineTextInput.swift
// ============================================================================
// ETOS LLM Studio
//
// 提供 iOS 设置页常用的多行文本输入：
// - 右上角全屏编辑按钮
// - 全屏编辑页
// - 350ms 防抖提交
// ============================================================================

import SwiftUI
import UIKit

@MainActor
struct FullscreenMultilineTextInput: View {
    let identity: AnyHashable
    let placeholder: String
    let fullScreenTitle: String
    @Binding var text: String
    let lineLimit: ClosedRange<Int>
    let isEnabled: Bool
    let onDebouncedSave: (String) -> Void

    @State private var isPresentingFullscreenEditor = false
    @State private var pendingSaveTask: Task<Void, Never>?
    @State private var lastCommittedText = ""
    @FocusState private var isInlineFocused: Bool

    private static let saveDebounceNanoseconds: UInt64 = 350_000_000

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(lineLimit)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!isEnabled)
                .focused($isInlineFocused)

            Button {
                isPresentingFullscreenEditor = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel(NSLocalizedString("全屏编辑", comment: "Fullscreen editor button"))
            .disabled(!isEnabled)
        }
        .onAppear {
            lastCommittedText = text
        }
        .onChange(of: isEnabled) { _, newValue in
            if newValue {
                lastCommittedText = text
            } else {
                cancelPendingSave()
                isPresentingFullscreenEditor = false
            }
        }
        .onChange(of: text) { _, newValue in
            guard isEnabled else { return }
            guard newValue != lastCommittedText else { return }
            guard isInlineFocused || isPresentingFullscreenEditor else {
                lastCommittedText = newValue
                return
            }
            scheduleDebouncedSave(for: newValue)
        }
        .onChange(of: identity) { _, _ in
            cancelPendingSave()
            lastCommittedText = text
        }
        .fullScreenCover(isPresented: $isPresentingFullscreenEditor) {
            FullscreenMultilineTextEditor(
                title: fullScreenTitle,
                placeholder: placeholder,
                text: $text,
                isEnabled: isEnabled
            )
        }
        .onChange(of: isPresentingFullscreenEditor) { _, isPresented in
            if !isPresented {
                flushPendingSave()
            }
        }
        .onDisappear {
            flushPendingSave()
        }
        .id(identity)
    }

    private func scheduleDebouncedSave(for newValue: String) {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor [newValue] in
            do {
                try await Task.sleep(nanoseconds: Self.saveDebounceNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled, isEnabled, text != lastCommittedText else { return }
            lastCommittedText = newValue
            onDebouncedSave(newValue)
        }
    }

    private func cancelPendingSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
    }

    private func flushPendingSave() {
        guard isEnabled, text != lastCommittedText else { return }
        cancelPendingSave()
        lastCommittedText = text
        onDebouncedSave(text)
    }
}

@MainActor
private struct FullscreenMultilineTextEditor: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let isEnabled: Bool

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()

                TextEditor(text: $text)
                    .focused($isFocused)
                    .scrollContentBackground(.hidden)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!isEnabled)
                    .padding()

                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 24)
                        .allowsHitTesting(false)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label(NSLocalizedString("关闭", comment: ""), systemImage: "chevron.left")
                    }
                }
            }
        }
        .onAppear {
            isFocused = true
        }
    }
}
