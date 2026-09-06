// ============================================================================
// ModelConnectivityTestView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 展示当前提供商已激活聊天模型的连通性测试结果。
// ============================================================================

import SwiftUI
import ETOSCore

struct ModelConnectivityTestView: View {
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
                Text(NSLocalizedString("点击开始后，会按模型用途发送真实的聊天、嵌入或图片生成请求。图片生成可能产生费用，并发数量会自动保存。", comment: "Watch model test explanation"))
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
        .onDisappear {
            viewModel.cancel()
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

struct SingleModelConnectivityTestView: View {
    @StateObject private var viewModel: SingleModelConnectivityTestViewModel
    private let providerName: String
    private let modelDisplayName: String
    private let modelName: String
    private let testDescription: String

    init(provider: Provider, model: Model) {
        self.providerName = provider.name
        self.modelDisplayName = model.displayName
        self.modelName = model.modelName
        self.testDescription = Self.description(for: model.kind)
        _viewModel = StateObject(wrappedValue: SingleModelConnectivityTestViewModel(provider: provider, model: model))
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Text(modelDisplayName)
                        .lineLimit(1)
                    Text(modelName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Text(providerName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Text(viewModel.progressText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } footer: {
                Text(testDescription)
            }

            Section(NSLocalizedString("测试结果", comment: "Model test result section")) {
                ForEach(viewModel.results) { result in
                    resultRow(result)
                }
            }
        }
        .navigationTitle(NSLocalizedString("模型测试", comment: "Model connectivity test title"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
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
        .onDisappear {
            viewModel.cancel()
        }
    }

    private func resultRow(_ result: SingleModelConnectivityTestResult) -> some View {
        HStack(alignment: .top, spacing: 6) {
            statusIcon(for: result.status)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(result.kind.localizedName)
                    .lineLimit(1)
                if let latency = result.latencyMilliseconds {
                    Text(String(format: NSLocalizedString("耗时 %d ms", comment: "Model test latency"), latency))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let responsePreview = result.responsePreview, !responsePreview.isEmpty {
                    Text(responsePreview)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
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

    private static func description(for kind: ModelKind) -> String {
        switch kind {
        case .chat:
            return NSLocalizedString("会依次发送非流式、流式和工具调用请求，并验证响应中包含有效内容。测试请求不会写入聊天历史。", comment: "Single chat model connectivity test explanation")
        case .embedding:
            return NSLocalizedString("会向嵌入接口发送一段测试文本，并验证返回的向量与维度。", comment: "Single embedding model connectivity test explanation")
        case .image:
            return NSLocalizedString("会向图片生成接口发送一条简单提示并验证图片结果，可能产生费用。", comment: "Single image model connectivity test explanation")
        case .rerank, .textToSpeech:
            return NSLocalizedString("当前模型用途暂不支持测活。", comment: "Unsupported model connectivity test explanation")
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
