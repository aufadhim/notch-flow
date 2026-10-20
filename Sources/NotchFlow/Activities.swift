import SwiftUI

struct LiveActivity: Identifiable {
    let id: String
    var title: String
    var detail: String
    var progress: Double?
    var status: String
    var symbol: String { status == "done" ? "checkmark.circle.fill" : status == "failed" ? "exclamationmark.circle.fill" : "terminal.fill" }
    var color: Color { status == "failed" ? .orange : .mint }
}

extension IslandState {
    /// Declarative status only: URLs never execute commands or launch arbitrary URLs.
    func receive(_ url: URL) {
        guard url.scheme == "notchflow", url.host == "activity",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let fields = parts.queryItems ?? []
        func value(_ key: String) -> String? { fields.first(where: { $0.name == key })?.value }
        guard let id = value("id"), !id.isEmpty, id.count <= 100 else { return }
        if value("action") == "dismiss" { activities.removeAll { $0.id == id }; return }
        let previous = activities.first { $0.id == id }
        let status = value("status") ?? previous?.status ?? "running"
        guard ["running", "done", "failed"].contains(status) else { return }
        var progress = previous?.progress
        if let text = value("progress") {
            guard let number = Double(text), number.isFinite, (0...1).contains(number) else { return }
            progress = number
        }
        if status == "done" { progress = 1 }
        let activity = LiveActivity(id: id,
            title: String((value("title") ?? previous?.title ?? "Terminal activity").prefix(100)),
            detail: String((value("detail") ?? previous?.detail ?? "").prefix(240)),
            progress: progress, status: status)
        activities.removeAll { $0.id == id }
        activities.insert(activity, at: 0)
        activities = Array(activities.prefix(20))
        if previous == nil || (status != "running" && previous?.status != status) {
            tab = 3
            alert(activity.title + (status == "done" ? " · Complete" : status == "failed" ? " · Failed" : " · Started"))
        }
    }
}

struct ActivitiesView: View {
    @ObservedObject var state: IslandState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if state.activities.isEmpty {
                    Image(systemName: "waveform.path").font(.system(size: 28)).foregroundStyle(.mint)
                    Text("Your work, at a glance").font(.system(size: 15, weight: .semibold))
                    Text("Send build progress or task status from Terminal. Activities stay here until dismissed.")
                        .font(.system(size: 12)).foregroundStyle(.gray)
                    Button("Preview activity") {
                        state.receive(URL(string: "notchflow://activity?id=preview&title=Example%20build&detail=Demo%20activity&progress=0.65")!)
                    }.padding(.vertical, 8)
                }
                ForEach(state.activities) { activity in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: activity.symbol).foregroundStyle(activity.color)
                            Text(activity.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Spacer()
                            Text(activity.status.capitalized).font(.system(size: 10)).foregroundStyle(.gray)
                            Button { state.activities.removeAll { $0.id == activity.id } } label: { Image(systemName: "xmark").font(.system(size: 10)) }.help("Dismiss activity")
                        }
                        if !activity.detail.isEmpty { Text(activity.detail).font(.system(size: 11)).foregroundStyle(.gray).lineLimit(2) }
                        if let progress = activity.progress { ProgressView(value: progress).tint(activity.color) }
                    }.padding(12).background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain)
    }
}
