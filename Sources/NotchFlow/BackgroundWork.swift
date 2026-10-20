import AppKit

/// Suspend recurring work while the display/system sleeps or the session is inactive.
final class BackgroundWork {
    static let shared = BackgroundWork()
    private var timers: [Timer] = []
    private var reasons = Set<String>()
    private var observers: [NSObjectProtocol] = []
    private init() {
        let center = NSWorkspace.shared.notificationCenter
        for (stop, start, reason) in [
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "display"),
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, "system"),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, "session")
        ] {
            observers.append(center.addObserver(forName: stop, object: nil, queue: .main) { [weak self] _ in
                self?.reasons.insert(reason); self?.update()
            })
            observers.append(center.addObserver(forName: start, object: nil, queue: .main) { [weak self] _ in
                self?.reasons.remove(reason); self?.update()
            })
        }
    }
    func register(_ timer: Timer) {
        timers.removeAll { !$0.isValid }
        timers.append(timer)
        if !reasons.isEmpty { timer.fireDate = .distantFuture }
    }
    private func update() {
        timers.removeAll { !$0.isValid }
        for timer in timers { timer.fireDate = reasons.isEmpty ? Date().addingTimeInterval(timer.timeInterval) : .distantFuture }
    }
}
