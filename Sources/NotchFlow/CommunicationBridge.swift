import SwiftUI
import ApplicationServices
import CoreAudio
import Vision
import CoreGraphics

struct MirroredBanner: Identifiable {
    let id = UUID()
    let text: String
    let date = Date()
    var parts: [String] { text.components(separatedBy: " · ") }
    var sender: String { parts.count > 1 ? parts[1] : parts[0] }
    var preview: String { parts.count > 2 ? parts.dropFirst(2).joined(separator: " · ") : "New message" }
}

struct IncomingCall {
    let app: String
    let title: String
    let state: String
    let appPID: pid_t
    let window: AXUIElement?
    let customCanvasControls: Bool
    let accept: AXUIElement?
    let decline: AXUIElement?
}

/// Opt-in, best-effort bridge for visible system banners and incoming-call UI.
/// It reads no message database and stores no message bodies on disk.
final class CommunicationBridge: ObservableObject {
    @Published var enabled = false
    @Published var trusted = AXIsProcessTrusted()
    @Published var banners: [MirroredBanner] = []
    @Published var activeMessage: MirroredBanner?
    private var messageExpiry: DispatchWorkItem?
    @Published var call: IncomingCall?
    @Published var nativeWindowSuppressed = false
    @Published var status = "Off · no notification content is being read"
    var announce: (() -> Void)?
    private var timer: Timer?
    private var busy = false
    private var lastDiagnostics = Date.distantPast
    private var lastCallProbe = Date.distantPast
    private struct WatchedApp {
        let bundleIdentifier: String
        let localizedName: String
        let processIdentifier: pid_t
    }
    private var watchedApps: [WatchedApp] = []
    private var appObservers: [NSObjectProtocol] = []
    private var lastAppRefresh = Date.distantPast

    private func refreshWatchedApps() {
        watchedApps = NSWorkspace.shared.runningApplications.compactMap { app in
            let id = app.bundleIdentifier ?? ""
            // Fetch names only for relevant bundles, not every system process.
            guard Self.isSupported(id: id, name: "") else { return nil }
            return WatchedApp(bundleIdentifier: id,
                              localizedName: Self.cleanText(app.localizedName ?? ""),
                              processIdentifier: app.processIdentifier)
        }
        lastAppRefresh = Date()
    }
    private var seen: Set<String> = []
    private var baselined = false
    private var epoch = 0
    private var lastCallSignature = ""
    private var revealOriginalRequested = false
    private var managedWindow: AXUIElement?
    private var callerNames: [pid_t: String] = [:]
    private var screenAccessPrompted = false
    private let queue = DispatchQueue(label: "notchflow.communications", qos: .utility)

    static func printDiagnostics() {
        print("trusted=\(AXIsProcessTrusted())")
        for app in NSWorkspace.shared.runningApplications {
            let id = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            guard isSupported(id: id, name: name), id != "com.apple.notificationcenterui" else { continue }
            print("APP name=\(name) id=\(id) pid=\(app.processIdentifier)")
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 1)
            let windows = elements(root, kAXWindowsAttribute)
            print("windows=\(windows.count)")
            for (windowIndex, window) in windows.prefix(10).enumerated() {
                var pending: [(AXUIElement, Int)] = [(window, 0)]
                var count = 0
                while !pending.isEmpty && count < 500 {
                    let (node, depth) = pending.removeFirst()
                    count += 1
                    let role = string(node, kAXRoleAttribute)
                    let subrole = string(node, kAXSubroleAttribute)
                    let title = string(node, kAXTitleAttribute)
                    let desc = string(node, kAXDescriptionAttribute)
                    let value = string(node, kAXValueAttribute)
                    var actions: CFArray?
                    AXUIElementCopyActionNames(node, &actions)
                    let actionList = (actions as? [String] ?? []).joined(separator: ",")
                    if depth == 0 || !title.isEmpty || !desc.isEmpty || !value.isEmpty || !actionList.isEmpty {
                        print("W\(windowIndex) D\(depth) role=\(role) sub=\(subrole) title=\(title) desc=\(desc) value=\(value) actions=\(actionList)")
                    }
                    pending.append(contentsOf: elements(node, kAXChildrenAttribute).prefix(40).map { ($0, depth + 1) })
                }
            }
        }
    }

    init() {
        refreshWatchedApps()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            appObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshWatchedApps()
            })
        }
        trusted = AXIsProcessTrusted()
        // Once the user has enabled the bridge, keep it alive across updates and
        // login. On an already-trusted install, enable it by default.
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "communicationsEnabled") == nil
            ? true : defaults.bool(forKey: "communicationsEnabled")
        if enabled && !trusted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(options)
        }
        if enabled {
            status = trusted
                ? "Watching Telegram, WhatsApp, FaceTime and visible banners"
                : "Accessibility entry is stale. Remove and add NotchFlow again."
            // Keep polling even while permission is unavailable, so monitoring
            // recovers immediately after the user repairs the TCC entry.
            DispatchQueue.main.async { [weak self] in self?.startTimer() }
        }
    }

    func toggle() {
        trusted = AXIsProcessTrusted()
        guard trusted else {
            status = "Allow Accessibility in System Settings, then enable again."
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            return
        }
        enabled.toggle()
        UserDefaults.standard.set(enabled, forKey: "communicationsEnabled")
        epoch += 1
        timer?.invalidate()
        if enabled {
            baselined = false
            status = "Watching Telegram, WhatsApp, FaceTime and visible banners"
            startTimer()
        } else {
            banners = []; seen = []; call = nil
            status = "Off · history cleared"
        }
    }
    deinit {
        timer?.invalidate()
        appObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        timer?.tolerance = 0.1
        BackgroundWork.shared.register(timer!)
        poll()
    }
    func showOriginalControls() {
        guard let call else { return }
        let window = call.window
        let pid = call.appPID
        queue.async { [weak self] in
            guard let self else { return }
            self.revealOriginalRequested = true
            if let window {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
            DispatchQueue.main.async {
                NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
                self.nativeWindowSuppressed = false
                self.status = "Original \(call.app) controls opened"
            }
        }
    }
    private func poll() {
        guard enabled, !busy else { return }
        let permission = AXIsProcessTrusted()
        if trusted != permission { trusted = permission }
        let writeDiagnostics = Date().timeIntervalSince(lastDiagnostics) >= 30
        if writeDiagnostics {
            lastDiagnostics = Date()
            UserDefaults.standard.set(trusted, forKey: "lastAccessibilityCheck")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastAccessibilityCheckDate")
        }
        guard trusted else {
            let message = "Accessibility entry is stale. Remove and add NotchFlow again."
            if status != message { status = message }
            return
        }
        busy = true
        let token = epoch
        let scanCalls = call != nil || Date().timeIntervalSince(lastCallProbe) >= 3
        if scanCalls { lastCallProbe = Date() }
        let previousCall = call
        // A slow fallback covers background agents that do not publish launch events.
        if Date().timeIntervalSince(lastAppRefresh) >= 60 { refreshWatchedApps() }
        let apps = watchedApps
        queue.async { [weak self] in
            guard let self else { return }
            var texts: [String] = []
            var incoming: IncomingCall? = scanCalls ? nil : previousCall
            var appDiagnostics: [String] = []
            for app in apps {
                let id = app.bundleIdentifier
                let appName = app.localizedName
                let root = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(root, 0.8)
                if id == "com.apple.notificationcenterui" {
                    texts.append(contentsOf: Self.chatBanners(root))
                    continue
                }
                guard scanCalls else { continue }
                let windows = Self.elements(root, kAXWindowsAttribute)
                guard !windows.isEmpty else { continue }
                let audio = Self.audioActivity(pid: app.processIdentifier)
                if id != "com.apple.notificationcenterui" {
                    appDiagnostics.append("\(appName):audioIn=\(audio.input),audioOut=\(audio.output)")
                }
                if id != "com.apple.notificationcenterui" && windows.isEmpty {
                    appDiagnostics.append("\(appName):windows=0")
                }
                for window in windows.prefix(8) {
                    var nodes: [AXUIElement] = [window]
                    var labels: [String] = []
                    var accept: AXUIElement?, decline: AXUIElement?
                    var buttons: [AXUIElement] = []
                    var callControls = 0
                    var buttonCount = 0
                    var staticTextCount = 0
                    var count = 0
                    while !nodes.isEmpty && count < 300 {
                        let node = nodes.removeFirst()
                        count += 1
                        let role = Self.string(node, kAXRoleAttribute)
                        let title = Self.string(node, kAXTitleAttribute)
                        let description = Self.string(node, kAXDescriptionAttribute)
                        if role == kAXStaticTextRole && id == "com.apple.notificationcenterui" {
                            let value = Self.string(node, kAXValueAttribute)
                            let text = value.isEmpty ? title : value
                            if !text.isEmpty && !labels.contains(text) { labels.append(String(text.prefix(300))) }
                        }
                        if role == kAXStaticTextRole { staticTextCount += 1 }
                        if id != "com.apple.notificationcenterui" {
                            let value = Self.string(node, kAXValueAttribute)
                            for text in [title, description, value] where !text.isEmpty && !labels.contains(text) {
                                labels.append(String(text.prefix(200)))
                            }
                        }
                        if role == kAXButtonRole {
                            buttonCount += 1
                            buttons.append(node)
                            let labels = [title, description, Self.string(node, kAXValueAttribute)]
                            let label = labels.joined(separator: " ").lowercased()
                            let actionable = Self.string(node, kAXSubroleAttribute).isEmpty && Self.isEnabled(node)
                            if actionable && labels.contains(where: { Self.matchesCallAction($0, accept: true) }) { accept = node; callControls += 1 }
                            if actionable && labels.contains(where: { Self.matchesCallAction($0, accept: false) }) { decline = node; callControls += 1 }
                            if Self.containsAny(label, Self.callControlWords) { callControls += 1 }
                        }
                        nodes.append(contentsOf: Self.elements(node, kAXChildrenAttribute).prefix(25))
                    }
                    if id != "com.apple.notificationcenterui" {
                        let windowTitle = Self.string(window, kAXTitleAttribute)
                        let combined = ([windowTitle] + labels).joined(separator: " ").lowercased()
                        let hasCallLanguage = Self.containsAny(combined, Self.callStateWords)
                        let hasAnswerPair = accept != nil && decline != nil
                        let size = Self.size(window)
                        let appIdentity = (id + " " + appName).lowercased()
                        // Telegram's native call surface is custom-drawn: it exposes
                        // three unlabeled buttons and almost no accessibility text.
                        let telegramCallSurface = appIdentity.contains("telegram") &&
                            buttonCount >= 3 && count <= 24 && staticTextCount <= 3 &&
                            size.width >= 420 && size.height >= 360 &&
                            (audio.input || audio.output)
                        appDiagnostics.append("\(appName):nodes=\(count),buttons=\(buttonCount),texts=\(staticTextCount),size=\(Int(size.width))x\(Int(size.height)),controls=\(callControls),callText=\(hasCallLanguage),answerPair=\(hasAnswerPair)")
                        let ended = Self.containsAny(combined, ["call ended", "missed call", "no answer", "call declined", "panggilan berakhir", "tidak dijawab"])
                        if !ended && (telegramCallSurface || (hasCallLanguage && hasAnswerPair) || (hasCallLanguage && decline != nil && audio.input)) {
                            let state = telegramCallSurface
                                ? (audio.input ? "Call in progress" : "Calling or ringing")
                                : Self.callState(in: combined, hasAnswer: accept != nil)
                            var person = Self.callTitle(windowTitle: windowTitle, labels: labels, appName: appName)
                            if telegramCallSurface && person.isEmpty {
                                if let cached = self.callerNames[app.processIdentifier] {
                                    person = cached
                                } else if let recognized = Self.recognizeCallerName(pid: app.processIdentifier, window: window, appName: appName) {
                                    self.callerNames[app.processIdentifier] = recognized
                                    person = recognized
                                } else if !CGPreflightScreenCaptureAccess() && !self.screenAccessPrompted {
                                    self.screenAccessPrompted = true
                                    DispatchQueue.main.async { self.requestCallerNameAccess() }
                                }
                            }
                            incoming = IncomingCall(app: appName.isEmpty ? "Call" : appName,
                                                    title: person,
                                                    state: state,
                                                    appPID: app.processIdentifier,
                                                    window: window,
                                                    customCanvasControls: false,
                                                    accept: telegramCallSurface ? nil : accept,
                                                    decline: telegramCallSurface ? nil : decline)
                            break
                        }
                    }
                    if id == "com.apple.notificationcenterui", !labels.isEmpty {
                        // Only a small banner window, never the expanded Notification Center.
                        var rawSize: CFTypeRef?
                        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &rawSize) == .success,
                           let rawSize, CFGetTypeID(rawSize) == AXValueGetTypeID() {
                            var size = CGSize.zero
                            AXValueGetValue(unsafeBitCast(rawSize, to: AXValue.self), .cgSize, &size)
                            if size.width <= 500 && size.height <= 250 {
                                texts.append(labels.prefix(5).joined(separator: " · "))
                            }
                        }
                    }
                }
            }
            let suppressed = false
            DispatchQueue.main.async {
                self.busy = false
                guard self.enabled, self.epoch == token else { return }
                let signature = incoming.map { "\($0.app)|\($0.title)|\($0.state)" } ?? ""
                if writeDiagnostics {
                UserDefaults.standard.set(incoming?.state ?? "", forKey: "lastDetectedCall")
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastCallScanDate")
                UserDefaults.standard.set(appDiagnostics.joined(separator: ";"), forKey: "lastCallScanSummary")
                }
                let newCall = !signature.isEmpty && signature != self.lastCallSignature
                if signature != self.lastCallSignature { self.call = incoming }
                self.lastCallSignature = signature
                if self.nativeWindowSuppressed != suppressed { self.nativeWindowSuppressed = suppressed }
                if incoming == nil {
                    self.queue.async {
                        self.revealOriginalRequested = false
                        self.callerNames.removeAll()
                    }
                }
                var added = false
                for text in Set(texts) where !self.seen.contains(text) {
                    if self.baselined {
                        let message = MirroredBanner(text: text)
                        self.banners.insert(message, at: 0)
                        self.activeMessage = message
                        self.messageExpiry?.cancel()
                        let expiry = DispatchWorkItem { [weak self] in self?.activeMessage = nil }
                        self.messageExpiry = expiry
                        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: expiry)
                        added = true
                    }
                }
                // A repeated message is new when its previous banner has disappeared.
                self.seen = Set(texts)
                self.baselined = true
                if self.banners.count > 20 { self.banners = Array(self.banners.prefix(20)) }
                if self.seen.count > 200 { self.seen = Set(texts) }
                if newCall && !added { self.announce?() }
            }
        }
    }
    private static let acceptWords = ["accept", "answer", "terima", "jawab", "angkat"]
    /// Notification Center may put banners inside a full-display AX window.
    /// Inspect bounded card containers, never treat that whole window as a message.
    private static func chatBanners(_ root: AXUIElement) -> [String] {
        var pending = elements(root, kAXWindowsAttribute)
        var results: [String] = []
        var visited = 0
        while !pending.isEmpty && visited < 180 {
            let node = pending.removeFirst()
            visited += 1
            let dimensions = size(node)
            let role = string(node, kAXRoleAttribute)
            if [kAXWindowRole, kAXGroupRole].contains(role),
               dimensions.width >= 220, dimensions.width <= 500,
               dimensions.height >= 45, dimensions.height <= 320 {
                var children = [node]
                var labels: [String] = []
                var dismissControl: AXUIElement?
                var count = 0
                while !children.isEmpty && count < 100 {
                    let child = children.removeFirst()
                    count += 1
                    let childRole = string(child, kAXRoleAttribute)
                    if childRole == kAXButtonRole {
                        let names = [string(child, kAXTitleAttribute), string(child, kAXDescriptionAttribute)].map { cleanText($0).lowercased() }
                        if names.contains(where: { ["close", "dismiss", "tutup", "close notification", "dismiss notification"].contains($0) }) {
                            dismissControl = child
                        }
                    }
                    if childRole != kAXButtonRole {
                        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                            let text = cleanText(string(child, attribute))
                            if !text.isEmpty && !labels.contains(text) { labels.append(String(text.prefix(400))) }
                        }
                    }
                    children.append(contentsOf: elements(child, kAXChildrenAttribute).prefix(30))
                }
                // Container descriptions often repeat all child labels in one sentence.
                // Keep individual leaf labels when they are available.
                let filtered = labels.filter { candidate in
                    !labels.contains { other in other != candidate && candidate.contains(other) && candidate.count > other.count + 3 }
                }
                let appName = labels.joined(separator: " ").lowercased().contains("whatsapp") ? "WhatsApp" : "Telegram"
                let content = filtered.filter { $0.lowercased() != appName.lowercased() }
                let combined = ([appName] + content).joined(separator: " · ")
                if isChatBanner(labels.joined(separator: " ")), !content.isEmpty, !results.contains(combined) {
                    results.append(combined)
                    // Only dismiss this exact card, after its text has been copied.
                    // Never invoke Clear All or disable the app's notifications.
                    if let dismissControl {
                        AXUIElementPerformAction(dismissControl, kAXPressAction as CFString)
                    }
                    continue
                }
            }
            pending.append(contentsOf: elements(node, kAXChildrenAttribute).prefix(40))
        }
        return results
    }
    static func isChatBanner(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("telegram") || lower.contains("whatsapp")
    }
    func clearMessages() { banners.removeAll(); activeMessage = nil; messageExpiry?.cancel() }
    static func matchesCallAction(_ text: String, accept: Bool) -> Bool {
        let normalized = cleanText(text).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let words = accept
            ? ["accept", "answer", "accept call", "answer call", "terima", "jawab", "angkat"]
            : ["decline", "reject", "end", "end call", "hang up", "decline call", "reject call", "tolak", "akhiri"]
        return words.contains(normalized)
    }
    private static func isEnabled(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value) == .success else { return false }
        return (value as? Bool) == true
    }
    private static let declineWords = ["decline", "reject", "tolak", "end call", "hang up", "akhiri"]
    private static let callControlWords = ["mute", "unmute", "camera", "video", "speaker", "microphone", "end", "hang up", "accept", "answer", "decline", "reject", "terima", "tolak"]
    private static let callStateWords = ["incoming call", "calling", "ringing", "audio call", "video call", "on call", "panggilan masuk", "memanggil", "berdering", "sedang menelepon"]
    private static func containsAny(_ text: String, _ words: [String]) -> Bool {
        words.contains { text.contains($0) }
    }
    private static func isSupported(id: String, name: String) -> Bool {
        if id == "com.apple.notificationcenterui" { return true }
        return ["ru.keepcoder.Telegram", "org.telegram.desktop", "net.whatsapp.WhatsApp", "com.apple.FaceTime"].contains(id)
    }
    private static func callState(in text: String, hasAnswer: Bool) -> String {
        if hasAnswer || containsAny(text, ["incoming", "ringing", "panggilan masuk", "berdering"]) { return "Incoming call" }
        if containsAny(text, ["calling", "memanggil"]) { return "Calling" }
        return "Call in progress"
    }
    private static func callTitle(windowTitle: String, labels: [String], appName: String) -> String {
        let ignored = (callStateWords + callControlWords + [appName, "call", "panggilan"]).map { $0.lowercased() }
        let candidates = ([windowTitle] + labels).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let found = candidates.first {
            let lower = $0.lowercased()
            return $0.count >= 2 && $0.count <= 80 && !ignored.contains(lower) && !containsAny(lower, callControlWords)
        } ?? ""
        return cleanText(found)
            .replacingOccurrences(of: " - WhatsApp voice call", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " - WhatsApp audio call", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " - WhatsApp video call", with: "", options: .caseInsensitive)
    }
    private static func cleanText(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{200e}", with: "")
            .replacingOccurrences(of: "\u{200f}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func string(_ element: AXUIElement, _ name: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }
    private static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
    private static func size(_ element: AXUIElement) -> CGSize {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return .zero }
        var size = CGSize.zero
        AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgSize, &size)
        return size
    }
    private static func position(_ element: AXUIElement) -> CGPoint {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return .zero }
        var point = CGPoint.zero
        AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgPoint, &point)
        return point
    }
    private static func recognizeCallerName(pid: pid_t, window: AXUIElement, appName: String) -> String? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        let origin = position(window)
        let windowSize = size(window)
        guard windowSize.width > 0, windowSize.height > 0,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let match = info.first { item in
            guard (item[kCGWindowOwnerPID as String] as? Int32) == pid,
                  let bounds = item[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            let x = bounds["X"] ?? -1, y = bounds["Y"] ?? -1
            let width = bounds["Width"] ?? 0, height = bounds["Height"] ?? 0
            return abs(x - origin.x) < 4 && abs(y - origin.y) < 4 &&
                abs(width - windowSize.width) < 8 && abs(height - windowSize.height) < 8
        }
        guard let number = match?[kCGWindowNumber as String] as? CGWindowID,
              let image = CGWindowListCreateImage(.null, .optionIncludingWindow, number, [.boundsIgnoreFraming, .bestResolution]) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["id-ID", "en-US"]
        request.regionOfInterest = CGRect(x: 0.18, y: 0.30, width: 0.64, height: 0.48)
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { return nil }
        let ignored = (callStateWords + callControlWords + [appName, "mute", "accept", "end", "calling"]).map { $0.lowercased() }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { text in
                let lower = text.lowercased()
                return text.count >= 2 && text.count <= 60 && !containsAny(lower, ignored)
            }
    }
    func requestCallerNameAccess() {
        if CGRequestScreenCaptureAccess() {
            status = "Caller-name recognition enabled. Start the next call to refresh it."
        } else {
            status = "Allow NotchFlow in Screen & System Audio Recording, then reopen it."
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
    private static func audioActivity(pid: pid_t) -> (input: Bool, output: Bool) {
        guard #available(macOS 14.2, *) else { return (false, false) }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var process = kAudioObjectUnknown
        var processSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var qualifier = pid
        let translated = withUnsafePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<pid_t>.size), pointer,
                                       &processSize, &process)
        }
        guard translated == noErr, process != kAudioObjectUnknown else { return (false, false) }
        func flag(_ selector: AudioObjectPropertySelector) -> Bool {
            var property = AudioObjectPropertyAddress(mSelector: selector,
                                                      mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(process, &property, 0, nil, &size, &value) == noErr && value != 0
        }
        return (flag(kAudioProcessPropertyIsRunningInput), flag(kAudioProcessPropertyIsRunningOutput))
    }
}

struct CommunicationsView: View {
    @ObservedObject var bridge: CommunicationBridge
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Messages & calls").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(bridge.enabled ? "Turn off" : "Turn on") { bridge.toggle() }
            }
            Text(bridge.status).font(.system(size: 10)).foregroundStyle(.gray)
            if !bridge.banners.isEmpty {
                Button("Clear messages") { bridge.clearMessages() }.font(.system(size: 10))
            }
            if !bridge.enabled {
                Text("Experimental: mirrors visible notification banners and recognized incoming-call controls via Accessibility. Content stays in memory. macOS and app versions may not expose these controls.")
                    .font(.system(size: 11)).foregroundStyle(.gray)
            }
            if let call = bridge.call {
                HStack {
                    CallPulseView(color: .green, state: call.state)
                    VStack(alignment: .leading) {
                        Text(call.app).font(.system(size: 13, weight: .semibold))
                        Text(call.title.isEmpty ? call.state : "\(call.title) · \(call.state)").lineLimit(1)
                    }
                    Spacer()
                    Button { bridge.showOriginalControls() } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }.help("Open original \(call.app) controls")
                    if call.title.isEmpty && !CGPreflightScreenCaptureAccess() {
                        Button { bridge.requestCallerNameAccess() } label: {
                            Image(systemName: "person.text.rectangle")
                        }.help("Enable caller-name recognition")
                    }
                }.padding(10).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(bridge.banners) { banner in
                        Text(banner.text).font(.system(size: 11)).lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            if bridge.enabled && bridge.banners.isEmpty && bridge.call == nil {
                Text("Waiting for Telegram or WhatsApp banners. Enable notifications for those apps in System Settings. Hidden message previews stay hidden.")
                    .font(.system(size: 11)).foregroundStyle(.gray)
            }
        }.buttonStyle(.plain)
    }
}
