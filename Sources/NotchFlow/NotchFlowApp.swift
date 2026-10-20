import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import Combine

@main
struct NotchFlowApp: App {
    init() {
        if CommandLine.arguments.contains("--call-diagnostics") {
            CommunicationBridge.printDiagnostics()
            exit(0)
        }
        if CommandLine.arguments.contains("--self-test") {
            do { try FeatureChecks.run(); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
    }
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

final class IslandState: ObservableObject {
    let power = PowerStatus()
    let preferences = Preferences()
    let shelf = FileShelf()
    let media = MediaPlayer()
    let communications = CommunicationBridge()
    @Published var dropTargeted = false
    @Published var expanded = false
    @Published var notchWidth: CGFloat = 180
    @Published var notchHeight: CGFloat = 32
    @Published var session = min(2, max(0, UserDefaults.standard.integer(forKey: "session")))
    @Published var remaining = 1500
    @Published var running = false
    @Published var notice: String?
    @Published var activities: [LiveActivity] = []
    @Published var tab = -1
    @Published var showTools = false
    private var observations = Set<AnyCancellable>()
    var compactHeight: CGFloat {
        // Compact content stays completely inside the menu-bar/notch safe area.
        notchHeight
    }
    var deadline: Date?
    var holdUntil = Date.distantPast
    let names = ["Focus", "Create", "Unwind"]
    let icons = ["moon.fill", "pencil.tip.crop.circle", "leaf.fill"]
    let colors: [Color] = [.purple, .orange, .mint]
    var time: String { String(format: "%02d:%02d", remaining / 60, remaining % 60) }
    init() {
        media.objectWillChange.merge(with: communications.objectWillChange).sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }.store(in: &observations)
        preferences.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }.store(in: &observations)
        power.changed = { [weak self] text in self?.alert(text) }
        communications.announce = { [weak self] in
            self?.showTools = false
            self?.tab = 6
            self?.holdUntil = Date().addingTimeInterval(5)
            self?.expanded = true
        }
    }
    func select(_ index: Int) {
        session = index
        UserDefaults.standard.set(index, forKey: "session")
        running = false
        remaining = [25, 45, 5][index] * 60
    }
    func toggleTimer() {
        if remaining == 0 { remaining = [25, 45, 5][session] * 60 }
        running.toggle()
        deadline = running ? Date().addingTimeInterval(Double(remaining)) : nil
    }
    func tick() {
        guard running, let deadline else { return }
        let seconds = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
        if remaining != seconds { remaining = seconds }
        if remaining == 0 {
            running = false
            alert("Session complete. Take a breath.")
            NSSound(named: "Glass")?.play()
        }
    }
    func alert(_ text: String) {
        notice = text
        holdUntil = Date().addingTimeInterval(5)
        expanded = true
    }
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = IslandState()
    private var panel: IslandPanel!
    private var statusItem: NSStatusItem!
    private var hoverTimer: Timer?
    private var clockTimer: Timer?
    private var shortcut: IslandHotKey?
    private var screen: NSScreen?
    private var centerX: CGFloat = 0
    private var lastInside = Date.distantPast
    private let canvas = NSSize(width: 520, height: 370)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        state.select(state.session)
        panel = IslandPanel(contentRect: NSRect(origin: .zero, size: canvas), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: IslandView(state: state))
        position()
        NotificationCenter.default.addObserver(self, selector: #selector(position), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(position), name: .init("NotchFlowDisplayChanged"), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(position), name: NSWorkspace.didWakeNotification, object: nil)
        hoverTimer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.trackPointer() }
        RunLoop.main.add(hoverTimer!, forMode: .common)
        BackgroundWork.shared.register(hoverTimer!)
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.state.tick() }
        clockTimer?.tolerance = 0.1
        BackgroundWork.shared.register(clockTimer!)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "capsule.inset.filled", accessibilityDescription: "NotchFlow")
        let menu = NSMenu()
        for (title, action) in [("Open NotchFlow", #selector(show)), ("Test notification", #selector(testNotification)), ("Enable launch at login", #selector(enableLogin)), ("Quit NotchFlow", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        statusItem.menu = menu
        shortcut = IslandHotKey { [weak self] in self?.show() }
        if !UserDefaults.standard.bool(forKey: "loginSetupAttempted") {
            UserDefaults.standard.set(true, forKey: "loginSetupAttempted")
            enableLogin()
        }
    }

    @objc func position() {
        guard let target = NSScreen.screens.first(where: { Preferences.id($0) == state.preferences.display })
            ?? NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first else { return }
        screen = target
        if let left = target.auxiliaryTopLeftArea, let right = target.auxiliaryTopRightArea, right.minX > left.maxX {
            state.notchWidth = right.minX - left.maxX
            centerX = (left.maxX + right.minX) / 2
        } else {
            state.notchWidth = 180
            centerX = target.frame.midX
        }
        state.notchHeight = max(28, target.safeAreaInsets.top)
        panel.setFrame(NSRect(x: centerX - canvas.width / 2, y: target.frame.maxY - canvas.height, width: canvas.width, height: canvas.height), display: true)
        panel.orderFrontRegardless()
    }

    private func trackPointer() {
        guard let screen else { return }
        let point = NSEvent.mouseLocation
        let now = Date()
        let trigger = NSRect(x: centerX - state.compactWidth / 2 - 2, y: screen.frame.maxY - state.compactHeight - 2, width: state.compactWidth + 4, height: state.compactHeight + 2)
        let width = state.preferences.width
        let expandedArea = NSRect(x: centerX - width / 2, y: screen.frame.maxY - state.notchHeight - 282, width: width, height: state.notchHeight + 282)
        let inside = NotchHoverRegion.contains(point, in: state.expanded ? expandedArea : trigger)
        if panel.ignoresMouseEvents != !inside { panel.ignoresMouseEvents = !inside }
        if inside {
            lastInside = now
            // Once the user engages with a banner, pointer exit controls dismissal.
            if state.holdUntil != .distantPast { state.holdUntil = .distantPast }
            if !state.expanded { state.openIsland() }
        } else {
            if state.expanded && !state.dropTargeted && now.timeIntervalSince(lastInside) > state.preferences.closeDelay && now > state.holdUntil {
                state.expanded = false
                state.notice = nil
            }
        }
    }
    @objc func show() { position(); state.holdUntil = Date().addingTimeInterval(3); state.openIsland() }
    @objc func testNotification() { state.alert("You're all set. Your island is ready.") }
    @objc func enableLogin() {
        do { try SMAppService.mainApp.register(); state.alert("Launch at login enabled.") }
        catch { state.alert("Check Login Items in System Settings."); SMAppService.openSystemSettingsLoginItems() }
    }
    @objc func quit() { NSApp.terminate(nil) }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { state.receive(url) }
    }
}

/// Screen-attached silhouette with outward-curving shoulders when expanded.
/// A custom path keeps this compatible with macOS 13.
struct IslandSilhouette: Shape {
    var radius: CGFloat
    var shoulder: CGFloat = 0
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(radius, shoulder) }
        set { radius = newValue.first; shoulder = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        let r = min(max(0, radius), min(rect.width / 2, rect.height))
        let k: CGFloat = 0.5522847498
        let s = min(max(0, shoulder), rect.height / 2)
        let left = rect.minX + s
        let right = rect.maxX - s
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addCurve(to: CGPoint(x: right, y: rect.minY + s),
                      control1: CGPoint(x: rect.maxX - k * s, y: rect.minY),
                      control2: CGPoint(x: right, y: rect.minY + s - k * s))
        path.addLine(to: CGPoint(x: right, y: rect.maxY - r))
        path.addCurve(to: CGPoint(x: right - r, y: rect.maxY),
                      control1: CGPoint(x: right, y: rect.maxY - r + k * r),
                      control2: CGPoint(x: right - r + k * r, y: rect.maxY))
        path.addLine(to: CGPoint(x: left + r, y: rect.maxY))
        path.addCurve(to: CGPoint(x: left, y: rect.maxY - r),
                      control1: CGPoint(x: left + r - k * r, y: rect.maxY),
                      control2: CGPoint(x: left, y: rect.maxY - r + k * r))
        path.addLine(to: CGPoint(x: left, y: rect.minY + s))
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                      control1: CGPoint(x: left, y: rect.minY + s - k * s),
                      control2: CGPoint(x: rect.minX + k * s, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct IslandView: View {
    @ObservedObject var state: IslandState
    @StateObject private var switcher = Switcher()
    private var tab: Int { state.tab }
    private var pageTitle: String {
        [0: "Mini Dock", 5: "Music", 4: "Files", 1: "Timer", 2: "Device", 3: "Activities", 6: "Messages", 8: "Clock & calendar", 7: "Settings"][tab] ?? "NotchFlow"
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                IslandSilhouette(radius: state.expanded ? 26 : 9, shoulder: state.expanded ? 12 : 0).fill(Color.black)
                if state.expanded {
                    VStack(spacing: 12) {
                        HStack {
                            Text(pageTitle)
                                .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Spacer()
                            ForEach(state.liveItems.filter { $0.id != tab }.prefix(2)) { item in
                                Button { state.tab = item.id } label: {
                                    Image(systemName: item.symbol).foregroundStyle(item.color)
                                }.help(item.title)
                            }
                            Button { state.showTools.toggle() } label: {
                                Image(systemName: state.showTools ? "xmark" : "square.grid.2x2")
                            }.help("All tools").accessibilityLabel("All tools")
                        }.buttonStyle(.plain)
                            .frame(minHeight: 26)
                            .background(MenuSwipeSurface { direction in
                                let pages = [0, 5, 4, 1, 2, 3, 6, 8, 7]
                                let index = pages.firstIndex(of: state.tab) ?? 0
                                state.tab = pages[(index + direction + pages.count) % pages.count]
                                state.showTools = false
                            })
                            .help("Swipe two fingers left or right here to switch tools")
                        if state.showTools {
                        HStack(spacing: 6) {
                            tabButton(0, "dock.rectangle", "Mini Dock")
                            tabButton(5, "music.note", "Media")
                            tabButton(4, "tray", "Files")
                            tabButton(1, "timer", "Timer")
                            tabButton(2, "battery.100", "Device")
                            tabButton(3, "waveform.path", "Activity")
                            tabButton(6, "bell", "Messages and calls")
                            tabButton(7, "gearshape", "Settings")
                            tabButton(8, "calendar", "Clock & calendar")
                            Spacer()
                            if tab == 0 {
                                Button { switcher.refresh(); if let app = switcher.selected { switcher.inspect(app) } } label: { Image(systemName: "arrow.clockwise") }
                            }
                          }.font(.system(size: 12, weight: .semibold)).buttonStyle(.plain)
                        }
                        if !state.showTools {
                        Group {
                        if tab == -1 {
                            IslandHomeView(state: state).frame(height: 205)
                        } else if tab == 0 {
                            SwitcherView(model: switcher) {
                                state.holdUntil = .distantPast
                                state.expanded = false
                            }.frame(height: state.notice == nil ? 210 : 182)
                        } else if tab == 1 {
                            content
                        } else if tab == 2 {
                            PowerView(power: state.power).frame(height: 180)
                        } else if tab == 3 {
                            ActivitiesView(state: state).frame(height: state.notice == nil ? 210 : 182)
                        } else if tab == 4 {
                            ShelfView(shelf: state.shelf).frame(height: 205)
                        } else if tab == 5 {
                            MediaView(player: state.media).frame(height: 205)
                        } else if tab == 6 {
                            CommunicationsView(bridge: state.communications).frame(height: 205)
                        } else if tab == 8 {
                            CalendarClockView().frame(height: 205)
                        } else {
                            PreferencesView(settings: state.preferences).frame(height: 205)
                        }
                        }.frame(maxHeight: 210).id(tab).transition(.opacity)
                        } else {
                            VStack(spacing: 12) {
                                Text("Your tools, one touch away").font(.system(size: 15, weight: .medium))
                                Text("Mini Dock · Music · Files · Timer\nBattery · Activities · Messages · Calendar")
                                    .font(.system(size: 12)).foregroundStyle(.gray).multilineTextAlignment(.center)
                            }.frame(height: 150)
                        }
                        if let notice = state.notice, tab != 1 {
                            Text(notice).font(.system(size: 11)).foregroundStyle(.mint).lineLimit(1)
                        }
                    }.padding(.horizontal, 22).padding(.top, state.notchHeight + 10)
                        .transition(.opacity.combined(with: .offset(y: -8)))
                } else {
                    CompactActivityView(state: state)
                }
            }
            .frame(width: state.expanded ? state.preferences.width : state.compactWidth, height: state.expanded ? state.notchHeight + 270 : state.compactHeight)
            .clipShape(IslandSilhouette(radius: state.expanded ? 26 : 9, shoulder: state.expanded ? 12 : 0))
            .onDrop(of: [UTType.fileURL], isTargeted: $state.dropTargeted) { providers in
                state.tab = 4
                state.holdUntil = Date().addingTimeInterval(2)
                return state.shelf.accept(providers)
            }
            .onChange(of: state.dropTargeted) { targeted in
                if targeted {
                    // Keep app drop targets available while Mini Dock is open.
                    let dockOpen = state.expanded && state.tab == 0 && !state.showTools
                    state.expanded = true
                    if !dockOpen { state.tab = 4 }
                }
            }
            .onHover { inside in
                if inside { state.openIsland() }
            }
            .shadow(color: .black.opacity(state.expanded ? 0.28 : 0), radius: 14, y: 7)
            Spacer(minLength: 0)
        }
        .frame(width: 520, height: 370, alignment: .top)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .animation(reduceMotion ? .linear(duration: 0.08) : .spring(response: 0.24, dampingFraction: 0.9), value: state.expanded)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9), value: state.compactWidth)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: tab)
    }

    private func tabButton(_ index: Int, _ icon: String, _ title: String) -> some View {
        Button { state.tab = index; state.showTools = false } label: {
            Image(systemName: icon).font(.system(size: 15))
                .frame(width: 30, height: 27)
                .background(tab == index ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.foregroundStyle(tab == index ? .white : .gray).help(title).accessibilityLabel(title)
    }

    private var content: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: state.icons[state.session]).foregroundStyle(state.colors[state.session]).font(.system(size: 21))
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.names[state.session]).font(.system(size: 15, weight: .semibold))
                    Text(state.running ? "Make room for what matters" : "Your space, at your pace").font(.system(size: 11)).foregroundStyle(.gray)
                }
                Spacer()
                Text(state.time).font(.system(size: 25, weight: .light, design: .rounded)).monospacedDigit()
            }
            HStack(spacing: 8) {
                ForEach(0..<3) { index in
                    Button { state.select(index) } label: {
                        HStack(spacing: 7) {
                            Image(systemName: state.icons[index]).foregroundStyle(state.colors[index])
                            Text(state.names[index]).font(.system(size: 12, weight: .medium))
                        }.frame(maxWidth: .infinity).padding(.vertical, 13)
                            .background(RoundedRectangle(cornerRadius: 13).fill(state.session == index ? state.colors[index].opacity(0.20) : .white.opacity(0.065)))
                            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(state.session == index ? state.colors[index].opacity(0.45) : .clear))
                    }.buttonStyle(.plain)
                }
            }
            HStack(spacing: 10) {
                Button { state.toggleTimer() } label: {
                    Label(state.running ? "Pause session" : "Start session", systemImage: state.running ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
                Button { state.select(state.session) } label: { Image(systemName: "arrow.counterclockwise").frame(width: 38, height: 38).background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 12)) }.help("Reset timer")
                Button { state.alert("A little space to stay in flow.") } label: { Image(systemName: "bell.badge").frame(width: 38, height: 38).background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 12)) }.help("Preview notification")
            }.buttonStyle(.plain)
            HStack {
                Circle().fill(state.running ? Color.mint : Color.gray).frame(width: 5, height: 5)
                Text(state.notice ?? (state.running ? "Session in progress" : "Ready when you are"))
                Spacer()
                Text("NOTCHFLOW").tracking(2).font(.system(size: 8, weight: .semibold))
            }.font(.system(size: 10)).foregroundStyle(.gray)
        }
    }
}
