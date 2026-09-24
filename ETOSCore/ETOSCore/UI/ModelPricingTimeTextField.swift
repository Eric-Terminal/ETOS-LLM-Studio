import SwiftUI

/// 草稿与有效分钟值分开保存，输入尚未完成时不会改动计费时段。
public struct ModelPricingTimeTextField: View {
    private let title: String
    @Binding private var minuteOfDay: Int
    @State private var draft: String
    @State private var isInvalid = false

    public init(title: String, minuteOfDay: Binding<Int>) {
        self.title = title
        _minuteOfDay = minuteOfDay
        _draft = State(initialValue: ModelPricingTimeRangeText.displayTime(minuteOfDay: minuteOfDay.wrappedValue))
    }

    public var body: some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: $draft)
                .monospacedDigit()
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(title)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
            if isInvalid {
                Text(NSLocalizedString("pricing.time.invalid", value: "Enter a time from 00:00 to 23:59. The last valid time is kept until then.", comment: "时间格式错误提示"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: draft) { _, text in
            guard let minute = ModelPricingTimeRangeText.minuteOfDay(from: text) else {
                isInvalid = true
                return
            }
            isInvalid = false
            if minuteOfDay != minute { minuteOfDay = minute }
        }
        .onChange(of: minuteOfDay) { _, minute in
            // 向导修改仍沿用分钟字段；只在外部值变化时刷新输入，保留用户正在输入的格式。
            if ModelPricingTimeRangeText.minuteOfDay(from: draft) != minute {
                draft = ModelPricingTimeRangeText.displayTime(minuteOfDay: minute)
                isInvalid = false
            }
        }
        .onSubmit {
            guard !isInvalid else { return }
            draft = ModelPricingTimeRangeText.displayTime(minuteOfDay: minuteOfDay)
        }
    }
}
