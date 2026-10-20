import SwiftUI

struct IslandActivity: Identifiable {
    let id: Int
    let symbol: String
    let title: String
    let detail: String
    let color: Color
}

extension IslandState {
    var liveItems: [IslandActivity] {
        var result: [IslandActivity] = []
        if let message = communications.activeMessage {
            result.append(IslandActivity(id: 6, symbol: "message.fill", title: message.sender, detail: message.preview, color: .mint))
        }
        if let call = communications.call {
            result.append(IslandActivity(id: 6, symbol: "phone.fill", title: call.title.isEmpty ? call.app : call.title, detail: call.state, color: .green))
        }
        if running {
            result.append(IslandActivity(id: 1, symbol: "timer", title: names[session], detail: time, color: .orange))
        }
        if media.connected && media.playing {
            result.append(IslandActivity(id: 5, symbol: "waveform", title: media.title, detail: media.artist, color: .mint))
        }
        if let activity = activities.first(where: { $0.status == "running" }) {
            let detail = activity.progress.map { "\(Int($0 * 100))%" } ?? "In progress"
            result.append(IslandActivity(id: 3, symbol: activity.symbol, title: activity.title, detail: detail, color: activity.color))
        }
        return result
    }
    var compactWidth: CGFloat {
        // The resting surface follows the physical cutout exactly. Active content
        // grows sideways, never downward into the app underneath it.
        liveItems.first?.id == 6 ? min(410, notchWidth + 220) :
            liveItems.first?.id == 5 ? min(400, notchWidth + 220) :
            (liveItems.isEmpty && notice == nil ? notchWidth : min(360, notchWidth + 150))
    }
    func openIsland() {
        guard !expanded else { return }
        showTools = false
        tab = 0
        expanded = true
    }
}

struct CompactActivityView: View {
    @ObservedObject var state: IslandState
    var body: some View {
        Group {
            if let item = state.liveItems.first, item.id == 6 {
                HStack(spacing: 0) {
                    Button {
                        state.openIsland()
                        state.holdUntil = Date().addingTimeInterval(8)
                    } label: {
                        HStack(spacing: 5) {
                            if item.symbol == "message.fill" {
                                Image(systemName: item.symbol).foregroundStyle(item.color)
                            } else {
                                CallPulseView(color: item.color, state: item.detail)
                            }
                            Text(item.title).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    Color.clear.frame(width: max(102, state.notchWidth - 14))
                    Text(item.detail).lineLimit(1).foregroundStyle(item.color)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }.padding(.horizontal, 8).frame(maxHeight: .infinity)
                    .font(.system(size: 10.5, weight: .medium))
            } else {
                Button {
                    state.openIsland()
                    state.holdUntil = Date().addingTimeInterval(8)
                } label: {
                    Group {
                        if let item = state.liveItems.first, item.id == 5 {
                    HStack(spacing: 0) {
                        HStack(spacing: 6) {
                            MusicPulseView(color: item.color, isPlaying: state.media.playing)
                            Text(item.title).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(width: max(110, state.notchWidth - 8))
                        Text(item.detail).lineLimit(1).foregroundStyle(item.color)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }.padding(.horizontal, 10).frame(maxHeight: .infinity)
                } else if let item = state.liveItems.first {
                  HStack(spacing: 8) {
                    Image(systemName: item.symbol).foregroundStyle(item.color)
                    Text(item.title).lineLimit(1)
                    Spacer(minLength: 3)
                    Text(item.detail).lineLimit(1).monospacedDigit().foregroundStyle(item.color)
                    if let second = state.liveItems.dropFirst().first {
                        Image(systemName: second.symbol).foregroundStyle(second.color)
                            .padding(4).background(.white.opacity(0.1), in: Circle())
                    }
                  }.padding(.horizontal, 10)
                } else if let notice = state.notice {
                    HStack { Image(systemName: "checkmark.circle").foregroundStyle(.mint); Text(notice).lineLimit(1) }
                } else {
                    Color.clear
                }
                    }.font(.system(size: 10.5, weight: .medium)).frame(maxWidth: .infinity, maxHeight: .infinity)
                }.buttonStyle(.plain).accessibilityLabel(state.liveItems.first.map { "Open " + $0.title } ?? "Open NotchFlow")
            }
        }
    }
}

struct CallPulseView: View {
    let color: Color
    let state: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let connected = state.lowercased().contains("progress")
            let speed = connected ? 0.75 : 1.45
            let phase = timeline.date.timeIntervalSinceReferenceDate * speed
            ZStack {
                ForEach(0..<2, id: \.self) { index in
                    let progress = reduceMotion ? 0.35 : (phase + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke(color.opacity(max(0, 0.65 - progress * 0.62)), lineWidth: 1.2)
                        .scaleEffect(0.58 + progress * 0.78)
                }
                Circle().fill(color.opacity(connected ? 0.22 : 0.3)).frame(width: 14, height: 14)
                Image(systemName: "phone.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(color)
                    .rotationEffect(.degrees(!connected && !reduceMotion ? sin(phase * 10) * 7 : 0))
            }.frame(width: 19, height: 19)
        }
        .accessibilityLabel(state)
    }
}

private struct MusicPulseView: View {
    let color: Color
    let isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !isPlaying || reduceMotion)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate * 7.5
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0..<4, id: \.self) { index in
                    let wave = (sin(phase + Double(index) * 1.35) + 1) / 2
                    Capsule()
                        .fill(color)
                        .frame(width: 1.8, height: isPlaying && !reduceMotion ? 4 + wave * 9 : 5)
                }
            }
            .frame(width: 13, height: 14)
            .animation(.easeInOut(duration: 0.12), value: phase)
        }
        .accessibilityLabel(isPlaying ? "Audio playing" : "Audio paused")
    }
}

struct IslandHomeView: View {
    @ObservedObject var state: IslandState
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkle").font(.system(size: 27)).foregroundStyle(.white.opacity(0.7))
            Text(state.notice ?? "A little space for what's happening.")
                .font(.system(size: 16, weight: .medium)).multilineTextAlignment(.center)
            Text("Music, timers and live activities appear here when active.")
                .font(.system(size: 12)).foregroundStyle(.gray).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button { state.tab = 5 } label: { Label("Music", systemImage: "music.note") }
                Button { state.tab = 1 } label: { Label("Timer", systemImage: "timer") }
                Button { state.tab = 0 } label: { Label("Mini Dock", systemImage: "dock.rectangle") }
            }.font(.system(size: 11)).buttonStyle(.bordered)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
