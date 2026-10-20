import SwiftUI
import UniformTypeIdentifiers
import Quartz

final class FileShelf: ObservableObject {
    @Published var urls: [URL] = []
    @Published var error: String?
    private let defaults: UserDefaults
    private var previewWindow: NSWindow?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        urls = (defaults.stringArray(forKey: "shelf.paths") ?? [])
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if let bookmarks = defaults.array(forKey: "shelf.bookmarks") as? [Data] {
            let resolved = bookmarks.compactMap { data -> URL? in
                var stale = false
                return (try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale))?.resolvingSymlinksInPath()
            }
            if !resolved.isEmpty { urls = Array(NSOrderedSet(array: resolved)) as? [URL] ?? resolved }
        }
    }
    func add(_ url: URL) {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            error = "This file is no longer available."; return
        }
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
        error = nil
        guard !urls.contains(normalized) else { return }
        guard urls.count < 40 else { error = "Shelf full. Remove a reference to add another file."; return }
        urls.insert(normalized, at: 0)
        save()
    }
    func remove(_ url: URL) { urls.removeAll { $0 == url.standardizedFileURL.resolvingSymlinksInPath() }; save() }
    private func save() {
        defaults.set(urls.map(\.path), forKey: "shelf.paths")
        defaults.set(urls.compactMap { try? $0.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) }, forKey: "shelf.bookmarks")
    }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func preview(_ url: URL) {
        guard exists(url) else { error = "File missing. Remove its reference or drag its new location here."; return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = url.lastPathComponent
        let preview = QLPreviewView(frame: window.contentView!.bounds, style: .normal)!
        preview.autoresizingMask = [.width, .height]
        preview.previewItem = url as NSURL
        window.contentView = preview
        window.isReleasedWhenClosed = false
        previewWindow?.close()
        previewWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
    func accept(_ providers: [NSItemProvider]) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        for provider in files {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                let url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let value = item as? URL { url = value }
                else if let text = item as? String { url = URL(string: text) }
                else { url = nil }
                DispatchQueue.main.async {
                    if let url { self?.add(url) } else { self?.error = "Could not read the dropped file." }
                }
            }
        }
        return !files.isEmpty
    }
}

struct ShelfView: View {
    @ObservedObject var shelf: FileShelf
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if shelf.urls.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 32)).foregroundStyle(.mint)
                    Text("Drop files on your notch").font(.system(size: 15, weight: .semibold))
                    Text("Drag them back out to Finder or another app.\nOriginal files stay where they are.")
                        .font(.system(size: 11)).foregroundStyle(.gray).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(shelf.urls, id: \.self) { url in
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
                                Text(url.lastPathComponent).font(.system(size: 12)).lineLimit(1)
                                    .foregroundStyle(shelf.exists(url) ? .white : .orange)
                                Spacer()
                                Button { shelf.preview(url) } label: { Image(systemName: "eye") }.help("Quick Look")
                                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.disabled(!shelf.exists(url))
                                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }.help("Reveal in Finder")
                                Button { shelf.remove(url) } label: { Image(systemName: "xmark") }.help("Remove reference, keep original file")
                            }.padding(9).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
                                .onDrag { NSItemProvider(object: url as NSURL) }
                        }
                    }
                }
                Text("\(shelf.urls.count) files · Drag out to share").font(.system(size: 10)).foregroundStyle(.gray)
            }
            if let error = shelf.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
        }.buttonStyle(.plain)
    }
}
