import SwiftUI
import AppKit

/// Observe only the header so horizontal scrolling inside Mini Dock still works.
struct MenuSwipeSurface: NSViewRepresentable {
    var changePage: (Int) -> Void
    func makeNSView(context: Context) -> SwipeHeaderView {
        let view = SwipeHeaderView()
        view.changePage = changePage
        return view
    }
    func updateNSView(_ view: SwipeHeaderView, context: Context) { view.changePage = changePage }
}

final class SwipeHeaderView: NSView {
    var changePage: (Int) -> Void = { _ in }
    private var monitor: Any?
    private var distance: CGFloat = 0
    private var fired = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.phase.contains(.began) { self.distance = 0; self.fired = false }
            guard self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                  event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return event }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                self.distance = 0
                self.fired = false
                return event
            }
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
            if !self.fired {
                self.distance += event.scrollingDeltaX
                if abs(self.distance) >= 28 {
                    self.fired = true
                    self.changePage(self.distance < 0 ? 1 : -1)
                }
            }
            return nil
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
