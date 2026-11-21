import ETOSCore
import SwiftUI

@MainActor
struct MacUsageCalendarView: View {
    @Environment(\.colorScheme) private var colorScheme
    let snapshot: MacUsageAnalyticsPresentation
    @ObservedObject var model: MacUsageAnalyticsModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)
    private let heatCellSide: CGFloat = 12
    private let heatCellSpacing: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            heatmapCard
            monthlyCalendarCard
        }
    }

    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(NSLocalizedString("活跃热力图", comment: ""))
                    .font(.headline)
                Spacer()
                Text(NSLocalizedString("最近 52 周", comment: ""))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: heatCellSpacing) {
                    ForEach(snapshot.weeks) { week in
                        VStack(spacing: heatCellSpacing) {
                            ForEach(week.days) { day in
                                Button {
                                    if snapshot.scope != .day {
                                        model.selectScope(.day)
                                    }
                                    model.selectDay(day.id)
                                } label: {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(heatColor(day.intensity))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                .strokeBorder(
                                                    day.id == snapshot.selectedDay ? Color.accentColor : Color.clear,
                                                    lineWidth: 1.4
                                                )
                                        )
                                        .frame(width: heatCellSide, height: heatCellSide)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(day.help)
                                .help(day.help)
                                .accessibilityAddTraits(day.id == snapshot.selectedDay ? .isSelected : [])
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .defaultScrollAnchor(.trailing)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text(NSLocalizedString("按请求次数着色，点按任意日期会联动下方详情。", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(NSLocalizedString("少", comment: ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(heatColor(level))
                        .frame(width: 10, height: 10)
                }

                Text(NSLocalizedString("多", comment: ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .usageCardSurface(cornerRadius: 20)
    }

    private var monthlyCalendarCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(NSLocalizedString("日历面板", comment: ""))
                    .font(.headline)

                Spacer()

                HStack(spacing: 10) {
                    Button {
                        model.previousMonth()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(NSLocalizedString("上个月", comment: ""))

                    Text(snapshot.monthTitle)
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 56, alignment: .center)

                    Button {
                        model.nextMonth()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(NSLocalizedString("下个月", comment: ""))
                }
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(snapshot.weekdays) { weekday in
                    Text(weekday.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }

                ForEach(snapshot.calendar) { cell in
                    if let day = cell.day {
                        let isSelected = day.id == snapshot.selectedDay
                        Button {
                            if snapshot.scope != .day {
                                model.selectScope(.day)
                            }
                            model.selectDay(day.id)
                        } label: {
                            VStack(spacing: 5) {
                                Text(day.number)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)

                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(heatColor(day.intensity))
                                    .frame(height: 6)
                                    .padding(.horizontal, 6)

                                Text(day.tokenText)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(day.help)
                        .help(day.help)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    } else {
                        Color.clear
                            .frame(minHeight: 54)
                            .accessibilityHidden(true)
                    }
                }
            }

            Text(NSLocalizedString("日期下方为 Token 数，点击日期查看对应范围。", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .usageCardSurface(cornerRadius: 20)
    }

    private func heatColor(_ intensity: Int) -> Color {
        switch intensity {
        case 1:
            return colorScheme == .dark
                ? Color(red: 0.06, green: 0.27, blue: 0.16)
                : Color(red: 0.82, green: 0.93, blue: 0.84)
        case 2:
            return colorScheme == .dark
                ? Color(red: 0.02, green: 0.44, blue: 0.21)
                : Color(red: 0.60, green: 0.84, blue: 0.63)
        case 3:
            return colorScheme == .dark
                ? Color(red: 0.15, green: 0.65, blue: 0.26)
                : Color(red: 0.33, green: 0.69, blue: 0.39)
        case 4:
            return colorScheme == .dark
                ? Color(red: 0.23, green: 0.82, blue: 0.34)
                : Color(red: 0.11, green: 0.47, blue: 0.20)
        default:
            return Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07)
        }
    }
}
