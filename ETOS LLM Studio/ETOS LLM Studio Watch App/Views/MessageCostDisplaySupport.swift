// ============================================================================
// MessageCostDisplaySupport.swift
// ============================================================================
// ETOS LLM Studio Watch App 消息费用展示辅助
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

enum MessageCostFormatter {
    static func formatTotal(_ value: Double) -> String {
        if value > 0, value < 0.000001 {
            return "<0.000001"
        }
        return formatNumber(value, minimumFractionDigits: 2, maximumFractionDigits: 6)
    }

    static func formatPriceValue(_ value: Double) -> String {
        formatNumber(value, minimumFractionDigits: 2, maximumFractionDigits: 6)
    }

    static func formatCompact(_ estimate: MessageCostEstimate) -> String {
        formatTotal(estimate.totalCost)
    }

    private static func formatNumber(
        _ value: Double,
        minimumFractionDigits: Int,
        maximumFractionDigits: Int
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: NSNumber(value: max(0, value))) ?? String(format: "%.6f", max(0, value))
    }
}

struct MessageCostDetailSection: View {
    let estimate: MessageCostEstimate

    var body: some View {
        Section(NSLocalizedString("费用", comment: "Message cost section title")) {
            MessageCostDetailRows(estimate: estimate)
        }
    }
}

struct MessageCostDetailRows: View {
    let estimate: MessageCostEstimate

    var body: some View {
        LabeledContent(NSLocalizedString("估算费用", comment: "Estimated cost label")) {
            Text(MessageCostFormatter.formatTotal(estimate.totalCost))
                .monospacedDigit()
        }

        LabeledContent(NSLocalizedString("阶梯依据", comment: "Tier basis label")) {
            Text(String(format: NSLocalizedString("%d tokens", comment: "Token count with unit"), estimate.tierBasisTokens))
        }

        if let tierMinimumTokens = estimate.tierMinimumTokens {
            LabeledContent(NSLocalizedString("命中阶梯", comment: "Matched pricing tier label")) {
                Text(tierRangeText(minimumTokens: tierMinimumTokens))
            }
        }

        ForEach(estimate.components) { component in
            VStack(alignment: .leading, spacing: 3) {
                LabeledContent(component.kind.localizedTitle) {
                    Text(MessageCostFormatter.formatTotal(component.subtotal))
                        .monospacedDigit()
                }
                Text(componentFormula(component))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }

        Text(estimate.isEstimatedFromCurrentPricing
             ? NSLocalizedString("按当前模型价格估算，仅供参考。", comment: "Watch current pricing estimated cost footer")
             : NSLocalizedString("仅供参考，以服务商实际扣费为准。", comment: "Estimated cost footer"))
            .etFont(.caption2)
            .foregroundStyle(.secondary)
    }

    private func componentFormula(_ component: MessageCostComponent) -> String {
        String(
            format: NSLocalizedString("%d tokens / 1M tokens × %@", comment: "Cost component calculation formula"),
            component.tokens,
            MessageCostFormatter.formatPriceValue(component.pricePerMillionTokens)
        )
    }

    private func tierRangeText(minimumTokens: Int) -> String {
        ModelPricingTierRangeText.text(minimumTokens: minimumTokens)
    }
}
