import SwiftUI

struct PowerView: View {
    @ObservedObject var power: PowerStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: power.pluggedIn ? "battery.100.bolt" : "battery.100")
                    .font(.system(size: 32)).foregroundStyle(power.pluggedIn ? Color.mint : .white)
                Spacer()
                Text(power.percent.map { "\($0)%" } ?? "—")
                    .font(.system(size: 34, weight: .light, design: .rounded)).monospacedDigit()
            }
            ProgressView(value: Double(power.percent ?? 0), total: 100).tint(.mint)
            Text(power.percent == nil ? "No internal battery detected" : power.charging ? "Charging" : power.pluggedIn ? "Connected to power · not charging" : "On battery power")
                .font(.system(size: 13, weight: .medium))
            Text("Charger changes appear here automatically.")
                .font(.system(size: 11)).foregroundStyle(.gray)
        }.padding(16).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
    }
}
