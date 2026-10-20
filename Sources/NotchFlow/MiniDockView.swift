import SwiftUI
import AppKit

struct MiniDockView: View {
    @ObservedObject var model: Switcher
    let finished: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Mini Dock").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { model.addFavorite() } label: {
                    Label("Add app", systemImage: "plus")
                }.help("Choose a favorite application")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(model.dockURLs, id: \.path) { url in
                        DockTile(model: model, url: url, finished: finished)
                    }
                }.padding(10)
            }
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
            Text("Click to open · Right-click to pin or choose windows\nDrop files onto an app to open them there")
                .font(.system(size: 10)).foregroundStyle(.gray)
            if let message = model.message {
                Text(message).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct DockTile: View {
    @ObservedObject var model: Switcher
    let url: URL
    let finished: () -> Void
    @State private var hovered = false
    @State private var targeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var running: NSRunningApplication? { model.apps.first { $0.bundleURL == url } }
    private var pinned: Bool { model.pins.contains(Bundle(url: url)?.bundleIdentifier ?? "") }
    private var name: String { FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "") }

    var body: some View {
        Button { model.launch(url, finished: finished) } label: {
            VStack(spacing: 5) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().interpolation(.high).frame(width: 42, height: 42)
                    .scaleEffect(hovered || targeted ? 1.12 : 1)
                    .frame(width: 56, height: 52)
                    .background(targeted ? Color.mint.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                Text(name).font(.system(size: 10, weight: .medium)).lineLimit(1).frame(width: 64)
                HStack(spacing: 4) {
                    Circle().fill(running?.isActive == true ? Color.mint : .white.opacity(0.6))
                        .frame(width: 4, height: 4).opacity(running == nil ? 0 : 1)
                    if pinned { Image(systemName: "pin.fill").font(.system(size: 7)).foregroundStyle(.gray) }
                }.frame(height: 8)
            }.padding(.vertical, 3).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(name)\(running == nil ? "" : " — running")")
        .accessibilityLabel("Open \(name)")
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.8), value: hovered || targeted)
        .contextMenu {
            Button(pinned ? "Unpin from Mini Dock" : "Pin to Mini Dock") { model.toggleFavorite(url) }
            if let running {
                Button("Choose window…") { model.inspect(running) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            model.launch(url, files: files, finished: finished)
            return true
        } isTargeted: { targeted = $0 }
    }
}
