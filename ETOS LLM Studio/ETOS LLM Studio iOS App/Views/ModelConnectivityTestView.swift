// ============================================================================
// ModelConnectivityTestView.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 展示当前提供商已激活聊天模型的连通性测试结果。
// ============================================================================

import SwiftUI
import ETOSCore

struct ModelConnectivityTestView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ModelConnectivityTestViewModel
    private let providerName: String
    private let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    init(provider: Provider) {
        self.providerName = provider.name
        _viewModel = StateObject(wrappedValue: ModelConnectivityTestViewModel(provider: provider))
    }

    var body: some View {
        List {
            Section {
                summaryRow
                concurrencyLimitRow
            } footer: {
                Text(NSLocalizedString("模型测试会向每个已添加的聊天模型发送一条轻量请求，用于确认 API Key、地址和模型 ID 是否可用。并发数量会自动保存。", comment: "Model test explanation"))
            }

            Section(NSLocalizedString("测试结果", comment: "Model test result section")) {
                if viewModel.results.isEmpty {
                    Text(NSLocalizedString("没有可测试的已添加聊天模型。", comment: "Model test empty state"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.results) { result in
                        resultRow(result)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("模型测试", comment: "Model connectivity test title"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("关闭", comment: "Close button")) {
                    viewModel.cancel()
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(viewModel.completedCount > 0 ? NSLocalizedString("重新测试", comment: "Retest models") : NSLocalizedString("开始测试", comment: "Start model test")) {
                    viewModel.start()
                }
                .disabled(viewModel.isRunning || viewModel.results.isEmpty)
            }
        }
        .task {
            guard viewModel.completedCount == 0 else { return }
            viewModel.start()
        }
    }

    private var summaryRow: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(providerName)
                Text(viewModel.progressText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if viewModel.isRunning {
                ProgressView()
            } else if viewModel.completedCount > 0 {
                Text(String(format: NSLocalizedString("%d 可用 / %d 不可用", comment: "Model test summary"), viewModel.succeededCount, viewModel.failedCount))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var concurrencyLimitRow: some View {
        LabeledContent(NSLocalizedString("并发数量", comment: "Model test concurrency limit field")) {
            TextField("1", value: $viewModel.concurrencyLimit, formatter: numberFormatter)
                .multilineTextAlignment(.trailing)
                .keyboardType(.numberPad)
                .frame(width: 80)
                .disabled(viewModel.isRunning)
                .onChange(of: viewModel.concurrencyLimit) { _, newValue in
                    viewModel.concurrencyLimit = ModelConnectivityTestViewModel.normalizedConcurrencyLimit(newValue)
                }
        }
    }

    private func resultRow(_ result: ModelConnectivityTestResult) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon(for: result.status)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.displayName)
                Text(result.modelName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let latency = result.latencyMilliseconds {
                    Text(String(format: NSLocalizedString("耗时 %d ms", comment: "Model test latency"), latency))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let responsePreview = result.responsePreview, !responsePreview.isEmpty {
                    Text(responsePreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let errorMessage = result.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func statusIcon(for status: ModelConnectivityTestResult.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .testing:
            ProgressView()
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

struct SingleModelConnectivityTestView: View {
    @StateObject private var viewModel: SingleModelConnectivityTestViewModel
    private let providerName: String
    private let modelDisplayName: String
    private let modelName: String

    init(provider: Provider, model: Model) {
        self.providerName = provider.name
        self.modelDisplayName = model.displayName
        self.modelName = model.modelName
        _viewModel = StateObject(wrappedValue: SingleModelConnectivityTestViewModel(provider: provider, model: model))
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(modelDisplayName)
                    Text(modelName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(providerName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(viewModel.progressText)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if viewModel.isRunning {
                        ProgressView()
                    }
                }
            } footer: {
                Text(NSLocalizedString("会依次测试非流式、流式和工具调用请求。测试请求不会写入聊天历史。", comment: "Single model connectivity test explanation"))
            }

            Section(NSLocalizedString("测试结果", comment: "Model test result section")) {
                ForEach(viewModel.results) { result in
                    resultRow(result)
                }
            }
        }
        .navigationTitle(NSLocalizedString("模型测试", comment: "Model connectivity test title"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(viewModel.completedCount > 0 ? NSLocalizedString("重新测试", comment: "Retest models") : NSLocalizedString("开始测试", comment: "Start model test")) {
                    viewModel.start()
                }
                .disabled(viewModel.isRunning)
            }
        }
        .task {
            guard viewModel.completedCount == 0 else { return }
            viewModel.start()
        }
        .onDisappear {
            viewModel.cancel()
        }
    }

    private func resultRow(_ result: SingleModelConnectivityTestResult) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon(for: result.status)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.kind.localizedName)
                if let latency = result.latencyMilliseconds {
                    Text(String(format: NSLocalizedString("耗时 %d ms", comment: "Model test latency"), latency))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let responsePreview = result.responsePreview, !responsePreview.isEmpty {
                    Text(responsePreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                if let errorMessage = result.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func statusIcon(for status: ModelConnectivityTestResult.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .testing:
            ProgressView()
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}
