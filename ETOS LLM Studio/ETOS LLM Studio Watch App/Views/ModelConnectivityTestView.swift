// ============================================================================
// ModelConnectivityTestView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 展示当前提供商已激活聊天模型的连通性测试结果。
// ============================================================================

import SwiftUI
import Shared

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
                VStack(alignment: .leading, spacing: 4) {
                    Text(providerName)
                    Text(viewModel.progressText)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    if viewModel.completedCount > 0 {
                        Text(String(format: NSLocalizedString("%d 可用 / %d 不可用", comment: "Model test summary"), viewModel.succeededCount, viewModel.failedCount))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    Text(NSLocalizedString("并发数量", comment: "Model test concurrency limit field"))
                    Spacer()
                    TextField("1", value: $viewModel.concurrencyLimit, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 48)
                        .disabled(viewModel.isRunning)
                        .onChange(of: viewModel.concurrencyLimit) { _, newValue in
                            viewModel.concurrencyLimit = ModelConnectivityTestViewModel.normalizedConcurrencyLimit(newValue)
                        }
                }
            } footer: {
                Text(NSLocalizedString("模型测试会向每个已添加的聊天模型发送一条轻量请求。并发数量会自动保存。", comment: "Watch model test explanation"))
            }

            Section(NSLocalizedString("测试结果", comment: "Model test result section")) {
                if viewModel.results.isEmpty {
                    Text(NSLocalizedString("没有可测试的已添加聊天模型。", comment: "Model test empty state"))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(viewModel.results) { result in
                        resultRow(result)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("模型测试", comment: "Model connectivity test title"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.cancel()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel(NSLocalizedString("关闭", comment: "Close button"))
            }

            ToolbarItem(placement: .bottomBar) {
                Button {
                    viewModel.start()
                } label: {
                    if viewModel.isRunning {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.isRunning || viewModel.results.isEmpty)
                .accessibilityLabel(viewModel.completedCount > 0 ? NSLocalizedString("重新测试", comment: "Retest models") : NSLocalizedString("开始测试", comment: "Start model test"))
            }
        }
        .task {
            guard viewModel.completedCount == 0 else { return }
            viewModel.start()
        }
    }

    private func resultRow(_ result: ModelConnectivityTestResult) -> some View {
        HStack(alignment: .top, spacing: 6) {
            statusIcon(for: result.status)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(result.displayName)
                    .lineLimit(1)
                Text(result.modelName)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if let latency = result.latencyMilliseconds {
                    Text(String(format: NSLocalizedString("耗时 %d ms", comment: "Model test latency"), latency))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let errorMessage = result.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(3)
                }
            }
        }
    }

    @ViewBuilder
    private func statusIcon(for status: ModelConnectivityTestResult.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundColor(.secondary)
        case .testing:
            ProgressView()
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        }
    }
}
