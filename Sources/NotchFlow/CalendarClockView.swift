import SwiftUI

struct CalendarClockView: View {
    @State private var monthOffset = 0
    private var calendar: Calendar { .autoupdatingCurrent }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
            let month = calendar.date(byAdding: .month, value: monthOffset, to: start) ?? start
            let count = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
            let leading = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "clock").foregroundStyle(.mint)
                    Text(now, format: .dateTime.hour().minute().second())
                        .font(.system(size: 21, weight: .light, design: .rounded))
                        .monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                    Text(now, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(TimeZone.autoupdatingCurrent.identifier.replacingOccurrences(of: "_", with: " "))
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                    Button("Today") { monthOffset = 0 }
                        .buttonStyle(.bordered).font(.system(size: 10))
                }.frame(width: 122, alignment: .leading)

                VStack(spacing: 5) {
                    HStack {
                        Button { monthOffset -= 1 } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel("Previous month")
                        Spacer(minLength: 0)
                        Text(month, format: .dateTime.month(.abbreviated).year())
                            .font(.system(size: 11, weight: .semibold))
                        Spacer(minLength: 0)
                        Button { monthOffset += 1 } label: { Image(systemName: "chevron.right") }
                            .accessibilityLabel("Next month")
                    }.buttonStyle(.plain)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                        ForEach(0..<7, id: \.self) { index in
                            let weekday = (calendar.firstWeekday - 1 + index) % 7
                            Text(calendar.veryShortStandaloneWeekdaySymbols[weekday])
                                .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                        }
                        ForEach(0..<42, id: \.self) { index in
                            let day = index - leading + 1
                            let valid = day > 0 && day <= count
                            let date = calendar.date(byAdding: .day, value: day - 1, to: month) ?? month
                            let today = valid && calendar.isDate(date, inSameDayAs: now)
                            Text(valid ? String(day) : "")
                                .font(.system(size: 10, weight: today ? .bold : .regular))
                                .frame(maxWidth: .infinity).frame(height: 20)
                                .background(today ? Color.mint.opacity(0.25) : .clear, in: Circle())
                                .foregroundStyle(today ? Color.mint : Color.white)
                        }
                    }
                }.frame(maxWidth: .infinity)
            }.padding(.top, 4)
        }
    }
}
