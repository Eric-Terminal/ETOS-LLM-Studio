import ETOSCore
import SwiftUI

@MainActor
struct MacUsageCalendarView: View {
    let snapshot: MacUsageAnalyticsPresentation
    @ObservedObject var model: MacUsageAnalyticsModel
    private let columns = Array(repeating: GridItem(.flexible()), count: 7)

    var body: some View {
        GroupBox(NSLocalizedString("活跃热力图", comment: "")) {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top) {
                    ForEach(snapshot.weeks) { week in
                        VStack {
                            Text(week.title).font(.caption2).foregroundStyle(.secondary)
                            ForEach(week.days) { day in
                                Button { model.selectDay(day.id) } label: {
                                    Image(systemName: day.id == snapshot.selectedDay ? "square.inset.filled" : "square.fill")
                                        .foregroundStyle(color(day.intensity))
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(day.help).help(day.help)
                                .accessibilityAddTraits(day.id == snapshot.selectedDay ? .isSelected : [])
                            }
                        }
                    }
                }
            }
            .defaultScrollAnchor(.trailing)
            .fixedSize(horizontal: false, vertical: true)
        }
        GroupBox {
            VStack {
                HStack {
                    Button { model.previousMonth() } label: { Label(NSLocalizedString("上个月", comment: ""), systemImage: "chevron.left") }
                    Spacer()
                    Text(snapshot.monthTitle).font(.headline)
                    Spacer()
                    Button { model.nextMonth() } label: { Label(NSLocalizedString("下个月", comment: ""), systemImage: "chevron.right") }
                }
                .buttonStyle(.borderless)
                LazyVGrid(columns: columns) {
                    ForEach(snapshot.weekdays) { weekday in Text(weekday.title).font(.caption).foregroundStyle(.secondary) }
                    ForEach(snapshot.calendar) { cell in
                        if let day = cell.day {
                            Button { model.selectDay(day.id) } label: {
                                VStack {
                                    HStack {
                                        Image(systemName: "circle.fill").font(.caption2).foregroundStyle(color(day.intensity))
                                        Text(day.number)
                                    }
                                    Text(day.tokenText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(day.id == snapshot.selectedDay ? .accentColor : .secondary)
                            .accessibilityLabel(day.help).help(day.help)
                            .accessibilityAddTraits(day.id == snapshot.selectedDay ? .isSelected : [])
                        } else { Color.clear.accessibilityHidden(true) }
                    }
                }
                Text(NSLocalizedString("日期下方为 Token 数，点击日期查看对应范围。", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } label: { Text(NSLocalizedString("日历面板", comment: "")) }
    }

    private func color(_ intensity: Int) -> Color {
        intensity == 0 ? .secondary.opacity(0.2) : .accentColor.opacity(0.25 + 0.1875 * Double(intensity))
    }
}
