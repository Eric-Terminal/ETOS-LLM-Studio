// ============================================================================
// ChatViewModelPicker.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 ChatView 的模型选择底部表单与顶部覆盖层。
// ============================================================================

import SwiftUI
import Shared

extension ChatView {
    var nativeModelPickerSheet: some View {
        NavigationStack {
            nativeModelPickerContent
            .navigationTitle(NSLocalizedString("选择模型", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", comment: "")) {
                        dismissModelPickerPanel()
                    }
                }
            }
        }
    }

    var nativeModelPickerContent: some View {
        List {
            if viewModel.activatedConversationModels.isEmpty {
                VStack(spacing: 6) {
                    Text(NSLocalizedString("暂无可用模型", comment: ""))
                        .etFont(.headline)
                    Text(NSLocalizedString("请先在设置中启用模型", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 28)
            } else {
                Section {
                    ForEach(topModelChoices, id: \.id) { runnable in
                        nativeModelPickerModelRow(runnable)
                    }
                } header: {
                    Text(NSLocalizedString("置顶模型", comment: ""))
                } footer: {
                    Text(NSLocalizedString("切换当前对话的模型", comment: ""))
                }

                if hasModelPickerRequestControls {
                    Section {
                        nativeModelPickerRequestControlRows
                    } header: {
                        Text(NSLocalizedString("请求控制", comment: ""))
                    } footer: {
                        Text(NSLocalizedString("点击控制名称后选择具体参数。", comment: ""))
                    }
                }

                if hasMoreModelChoices {
                    Section {
                        NavigationLink {
                            nativeModelPickerAllModelsList
                        } label: {
                            Label(NSLocalizedString("更多模型", comment: ""), systemImage: "ellipsis")
                        }
                    }
                }
            }
        }
    }

    var nativeModelPickerAllModelsList: some View {
        List {
            Section {
                ForEach(viewModel.activatedConversationModels, id: \.id) { runnable in
                    nativeModelPickerModelRow(runnable)
                }
            } header: {
                Text(NSLocalizedString("模型", comment: ""))
            }
        }
        .navigationTitle(NSLocalizedString("更多模型", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }

    func nativeModelPickerModelRow(_ runnable: RunnableModel) -> some View {
        Button {
            viewModel.setSelectedModel(runnable)
        } label: {
            MarqueeTitleSubtitleSelectionRow(
                title: runnable.model.displayName,
                subtitle: "\(runnable.provider.name) · \(runnable.model.modelName)",
                isSelected: runnable.id == viewModel.selectedModel?.id,
                subtitleUIFont: .monospacedSystemFont(ofSize: 12, weight: .regular)
            )
        }
    }

    @ViewBuilder
    var nativeModelPickerRequestControlRows: some View {
        if let selectedModel = viewModel.selectedModel {
            ForEach(selectedModelRequestControls) { control in
                NavigationLink {
                    ChatRequestBodyControlDetailView(runnableModel: selectedModel, control: control)
                } label: {
                    Text(control.title)
                }
            }
        }
    }

    var modelPickerOverlay: some View {
        GeometryReader { proxy in
            let panelHeight = proxy.size.height * modelPickerHeightRatio
            ZStack(alignment: .top) {
                Color.black.opacity(colorScheme == .dark ? 0.35 : 0.2)
                    .ignoresSafeArea()
                    .onTapGesture {
                        dismissModelPickerPanel()
                    }
                    .transition(.opacity)

                VStack(spacing: 12) {
                    modelPickerHeader

                    if viewModel.activatedConversationModels.isEmpty {
                        modelPickerEmptyState
                    } else if let control = modelPickerRequestControl,
                              let selectedModel = viewModel.selectedModel {
                        overlayRequestControlDetail(runnableModel: selectedModel, control: control)
                    } else if showAllModelsInPicker {
                        modelPickerAllModelsList
                    } else {
                        modelPickerSplitContent
                    }
                }
                .frame(width: proxy.size.width, height: panelHeight, alignment: .top)
                .background(modelPickerPanelBackground)
                .clipShape(RoundedRectangle(cornerRadius: modelPickerCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: modelPickerCornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 0.6)
                )
                .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 10)
                .offset(y: navBarHeight + 6)
                .transition(
                    .move(edge: .top)
                    .combined(with: .opacity)
                    .combined(with: .scale(scale: 0.96, anchor: .top))
                )
            }
        }
    }

    var modelPickerHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("选择模型", comment: ""))
                    .etFont(.system(size: 16, weight: .semibold))
                    .foregroundColor(TelegramColors.navBarText)
                Text(NSLocalizedString("切换当前对话的模型", comment: ""))
                    .etFont(.system(size: 12))
                    .foregroundColor(TelegramColors.navBarSubtitle)
            }

            Spacer()

            pickerHeaderActionButton(
                systemName: modelPickerBackButtonShowsClose ? "xmark" : "chevron.left",
                accessibilityLabel: modelPickerBackButtonShowsClose ? "关闭" : "返回"
            ) {
                if modelPickerRequestControl != nil {
                    modelPickerRequestControl = nil
                } else if showAllModelsInPicker {
                    showAllModelsInPicker = false
                } else {
                    dismissModelPickerPanel()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    var modelPickerBackButtonShowsClose: Bool {
        modelPickerRequestControl == nil && !showAllModelsInPicker
    }

    var modelPickerEmptyState: some View {
        VStack(spacing: 8) {
            Text(NSLocalizedString("暂无可用模型", comment: ""))
                .etFont(.system(size: 14, weight: .semibold))
                .foregroundColor(TelegramColors.navBarText)
            Text(NSLocalizedString("请先在设置中启用模型", comment: ""))
                .etFont(.system(size: 12))
                .foregroundColor(TelegramColors.navBarSubtitle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    var modelPickerList: some View {
        ScrollView {
            LazyVStack(spacing: 10, pinnedViews: []) {
                ForEach(topModelChoices, id: \.id) { runnable in
                    modelPickerRow(runnable)
                }

                if hasModelPickerRequestControls {
                    Divider()
                        .padding(.top, 2)

                    modelPickerRequestControlsPanel
                }

                if hasMoreModelChoices {
                    Divider()
                        .padding(.top, 2)

                    Button {
                        showAllModelsInPicker = true
                    } label: {
                        HStack(spacing: 10) {
                            Text(NSLocalizedString("更多模型", comment: ""))
                                .etFont(.system(size: 15, weight: .semibold))
                                .foregroundColor(TelegramColors.navBarText)

                            Spacer()

                            Image(systemName: "chevron.right")
                                .etFont(.system(size: 12, weight: .semibold))
                                .foregroundColor(TelegramColors.navBarSubtitle)
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(colorScheme == .dark ? Color.black.opacity(0.24) : Color.black.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(colorScheme == .dark ? 0.1 : 0.15), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    var modelPickerAllModelsList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(viewModel.activatedConversationModels, id: \.id) { runnable in
                    modelPickerRow(runnable)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    var topModelChoices: [RunnableModel] {
        Array(viewModel.activatedConversationModels.prefix(3))
    }

    var hasMoreModelChoices: Bool {
        viewModel.activatedConversationModels.count > topModelChoices.count
    }

    var selectedModelRequestControls: [ModelRequestBodyControl] {
        viewModel.selectedModel?.model.requestBodyControls.filter(\.isEnabled) ?? []
    }

    var hasModelPickerRequestControls: Bool {
        !selectedModelRequestControls.isEmpty
    }

    var modelPickerSplitContent: some View {
        modelPickerList
    }

    var modelPickerRequestControlsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("请求控制", comment: ""))
                .etFont(.system(size: 13, weight: .semibold))
                .foregroundColor(TelegramColors.navBarText)
                .padding(.horizontal, 2)

            LazyVStack(spacing: 8) {
                ForEach(selectedModelRequestControls) { control in
                    Button {
                        modelPickerRequestControl = control
                    } label: {
                        HStack(spacing: 8) {
                            Text(control.title)
                                .etFont(.system(size: 14, weight: .medium))
                                .foregroundColor(TelegramColors.navBarText)
                                .lineLimit(1)

                            Spacer()

                            Image(systemName: "chevron.right")
                                .etFont(.system(size: 11, weight: .semibold))
                                .foregroundColor(TelegramColors.navBarSubtitle)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(colorScheme == .dark ? Color.black.opacity(0.2) : Color.black.opacity(0.05))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    func overlayRequestControlDetail(
        runnableModel: RunnableModel,
        control: ModelRequestBodyControl
    ) -> some View {
        OverlayRequestControlDetailPanel(runnableModel: runnableModel, control: control)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .frame(maxHeight: .infinity)
    }

    func modelPickerRow(_ runnable: RunnableModel) -> some View {
        let isSelected = runnable.id == viewModel.selectedModel?.id
        let baseFill = colorScheme == .dark ? Color.black.opacity(0.24) : Color.black.opacity(0.05)
        let selectedFill = colorScheme == .dark ? Color.black.opacity(0.36) : Color.black.opacity(0.08)
        let borderOpacitySelected: Double = colorScheme == .dark ? 0.18 : 0.35
        let borderOpacityUnselected: Double = colorScheme == .dark ? 0.1 : 0.15

        return Button {
            viewModel.setSelectedModel(runnable)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                MarqueeTitleSubtitleLabel(
                    title: runnable.model.displayName,
                    subtitle: "\(runnable.provider.name) · \(runnable.model.modelName)",
                    titleUIFont: .systemFont(ofSize: 15, weight: .semibold),
                    subtitleUIFont: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    subtitleColor: TelegramColors.navBarSubtitle
                )
                .foregroundColor(TelegramColors.navBarText)
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .etFont(.system(size: 16, weight: .semibold))
                    .foregroundColor(isSelected ? TelegramColors.sendButtonColor : TelegramColors.navBarSubtitle.opacity(0.5))
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                Group {
                    if isLiquidGlassEnabled {
                        if #available(iOS 26.0, *) {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.clear)
                                .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(navBarGlassOverlayColor)
                                )
                        } else {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(navBarGlassOverlayColor)
                                )
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isSelected ? selectedFill : baseFill)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(isSelected ? borderOpacitySelected : borderOpacityUnselected), lineWidth: isSelected ? 0.8 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    var modelPickerPanelBackground: some View {
        modelPickerMorphBackground(isExpanded: true, isSource: showModelPickerPanel)
    }

    @ViewBuilder
    func modelPickerMorphBackground(isExpanded: Bool, isSource: Bool) -> some View {
        let cornerRadius = isExpanded ? modelPickerCornerRadius : navBarPillHeight / 2

        ZStack {
            if isExpanded {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(modelPickerPanelBaseTint)
            }

            if isLiquidGlassEnabled {
                if #available(iOS 26.0, *) {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.clear)
                        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(navBarGlassOverlayColor)
                        )
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(navBarGlassOverlayColor)
                        )
                }
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        .matchedGeometryEffect(id: modelPickerMorphID, in: modelPickerNamespace, isSource: isSource)
    }

    @ViewBuilder
    func sessionPickerMorphBackground(isExpanded: Bool, isSource: Bool) -> some View {
        let cornerRadius = isExpanded ? sessionPickerCornerRadius : navBarIconSize / 2

        ZStack {
            if isExpanded {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(modelPickerPanelBaseTint)
            }

            if isLiquidGlassEnabled {
                if #available(iOS 26.0, *) {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.clear)
                        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(navBarGlassOverlayColor)
                        )
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(navBarGlassOverlayColor)
                        )
                }
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        .matchedGeometryEffect(id: sessionPickerMorphID, in: sessionPickerNamespace, isSource: isSource)
    }
}
