import AppKit
import IOKit.ps

final class PowerStatus: ObservableObject {
    @Published var percent: Int?
    @Published var pluggedIn = false
    @Published var charging = false
    var changed: ((String) -> Void)?
    private var source: CFRunLoopSource?
    private var initialized = false

    init() {
        refresh()
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerStatus>.fromOpaque(context).takeUnretainedValue().refresh()
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
    }
    deinit { if let source { CFRunLoopSourceInvalidate(source) } }
    func refresh() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for entry in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, entry)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = info[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let connected = info[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let previous = pluggedIn
            percent = min(100, max(0, current * 100 / maximum))
            pluggedIn = connected
            charging = info[kIOPSIsChargingKey] as? Bool ?? false
            if initialized && previous != connected {
                changed?(connected ? "Charger connected · \(percent!)%" : "Running on battery · \(percent!)%")
            }
            initialized = true
            return
        }
        percent = nil
        initialized = false
    }
}
