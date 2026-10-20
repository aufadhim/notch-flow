import SwiftUI
import AppKit
import ApplicationServices
import UniformTypeIdentifiers

struct WindowDestination: Identifiable {
    let id: Int
    let title: String
    let element: AXUIElement
}

final class Switcher: ObservableObject {
    @Published var apps: [NSRunningApplication] = []
    @Published var windows: [WindowDestination] = []
    @Published var selected: NSRunningApplication?
    @Published var trusted = AXIsProcessTrusted()
    @Published var message: String?
    @Published var pins = Set(UserDefaults.standard.stringArray(forKey: "switcher.pins") ?? [])
    @Published var windowPins = Set(UserDefaults.standard.stringArray(forKey: "switcher.windowPins") ?? [])
    private var recent = UserDefaults.standard.stringArray(forKey: "switcher.recent") ?? []
    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if name == NSWorkspace.didActivateApplicationNotification,
                   let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   let id = app.bundleIdentifier, app.activationPolicy == .regular {
                    self?.recent.removeAll { $0 == id }
                    self?.recent.insert(id, at: 0)
                    self?.recent = Array(self?.recent.prefix(30) ?? [])
                    UserDefaults.standard.set(self?.recent, forKey: "switcher.recent")
                }
                self?.refresh()
            })
        }
    }
    deinit { observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }
    func refresh() {
        trusted = AXIsProcessTrusted()
        apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.sorted {
            let a = $0.bundleIdentifier ?? "", b = $1.bundleIdentifier ?? ""
            if pins.contains(a) != pins.contains(b) { return pins.contains(a) }
            let ai = recent.firstIndex(of: a) ?? Int.max, bi = recent.firstIndex(of: b) ?? Int.max
            if ai != bi { return ai < bi }
            return ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending
        }
        if let selected, selected.isTerminated { self.selected = nil; windows = [] }
    }
    func togglePin(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier else { return }
        if pins.contains(id) { pins.remove(id) } else { pins.insert(id) }
        UserDefaults.standard.set(Array(pins), forKey: "switcher.pins")
        refresh()
    }
    var dockURLs: [URL] {
        let favorites = pins.sorted().compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        var seen = Set<String>()
        return (favorites + apps.compactMap(\.bundleURL)).filter { seen.insert($0.path).inserted }
    }
    func toggleFavorite(_ url: URL) {
        guard let id = Bundle(url: url)?.bundleIdentifier else { return }
        if pins.contains(id) { pins.remove(id) } else { pins.insert(id) }
        UserDefaults.standard.set(Array(pins), forKey: "switcher.pins")
        refresh()
    }
    func addFavorite() {
        let picker = NSOpenPanel()
        picker.title = "Add an app to Mini Dock"
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.allowedContentTypes = [.applicationBundle]
        picker.allowsMultipleSelection = true
        picker.begin { [weak self] response in
            guard response == .OK, let self else { return }
            for url in picker.urls {
                if let id = Bundle(url: url)?.bundleIdentifier { self.pins.insert(id) }
            }
            UserDefaults.standard.set(Array(self.pins), forKey: "switcher.pins")
            self.refresh()
        }
    }
    func launch(_ url: URL, files: [URL] = [], finished: @escaping () -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        let completion: (NSRunningApplication?, Error?) -> Void = { [weak self] _, error in
            DispatchQueue.main.async {
                if let error { self?.message = error.localizedDescription }
                else { finished() }
            }
        }
        if files.isEmpty {
            NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: completion)
        } else {
            NSWorkspace.shared.open(files, withApplicationAt: url, configuration: configuration, completionHandler: completion)
        }
    }
    func windowKey(_ window: WindowDestination) -> String { (selected?.bundleIdentifier ?? "") + "|" + window.title }
    func toggleWindowPin(_ window: WindowDestination) {
        let key = windowKey(window)
        if windowPins.contains(key) { windowPins.remove(key) } else { windowPins.insert(key) }
        UserDefaults.standard.set(Array(windowPins), forKey: "switcher.windowPins")
        if let selected { inspect(selected) }
    }
    func inspect(_ app: NSRunningApplication) {
        selected = app
        windows = []
        message = nil
        trusted = AXIsProcessTrusted()
        guard trusted else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &result) == .success,
              let list = result as? [AXUIElement] else {
            message = "Window list unavailable. You can still open the app."
            return
        }
        windows = list.enumerated().map { index, window in
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
            let title = (value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Window \(index + 1)"
            return WindowDestination(id: index, title: title, element: window)
        }.sorted { a, b in
            let ap = windowPins.contains(windowKey(a)), bp = windowPins.contains(windowKey(b))
            return ap != bp ? ap : a.id < b.id
        }
        if windows.isEmpty { message = "No windows reported by this app." }
    }
    func activate(_ app: NSRunningApplication, window: WindowDestination? = nil) -> Bool {
        guard !app.isTerminated else { refresh(); message = "This app has closed."; return false }
        if let window {
            guard AXIsProcessTrusted() else { trusted = false; message = "Allow Accessibility to select a window."; return false }
            AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            let result = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
            guard result == .success else { message = "Window unavailable. Refresh and try again."; return false }
            AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        let success = app.activate(options: [.activateIgnoringOtherApps])
        if !success { message = "Could not activate this app." }
        return success
    }
    func openPermissionSettings() {
        // Only open settings. The user grants access themselves.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
}

struct SwitcherView: View {
    @ObservedObject var model: Switcher
    let finished: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let app = model.selected {
                HStack {
                    Button { model.selected = nil; model.windows = []; model.message = nil } label: { Image(systemName: "chevron.left") }.help("Back to apps")
                    Text(app.localizedName ?? "App").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Open app") { if model.activate(app) { finished() } }
                    Button { model.inspect(app) } label: { Image(systemName: "arrow.clockwise") }.help("Refresh windows")
                }
                if !model.trusted {
                    Text("Choose individual windows with Accessibility access. App switching works without it.").font(.system(size: 11)).foregroundStyle(.gray)
                    Button("Open Accessibility settings") { model.openPermissionSettings() }
                } else {
                    ScrollView {
                        VStack(spacing: 5) {
                            ForEach(model.windows) { window in
                              HStack {
                                Button { model.toggleWindowPin(window) } label: {
                                    Image(systemName: model.windowPins.contains(model.windowKey(window)) ? "pin.fill" : "pin")
                                }.help("Pin window by title")
                                Button { if model.activate(app, window: window) { finished() } } label: {
                                    HStack {
                                        Image(systemName: "macwindow").foregroundStyle(.mint)
                                        Text(window.title).lineLimit(1)
                                        Spacer()
                                        Image(systemName: "arrow.up.right").foregroundStyle(.gray)
                                    }.padding(10).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                                }.buttonStyle(.plain)
                              }
                            }
                        }
                    }
                }
                if let message = model.message { Text(message).font(.system(size: 11)).foregroundStyle(.orange) }
            } else {
                MiniDockView(model: model, finished: finished)
            }
        }.font(.system(size: 12)).buttonStyle(.plain)
        .onAppear { model.refresh() }
    }
}
