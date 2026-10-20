import SwiftUI
import ServiceManagement
import ApplicationServices

final class Preferences: ObservableObject {
    @Published var width: Double { didSet { UserDefaults.standard.set(width, forKey: "panel.width") } }
    @Published var closeDelay: Double { didSet { UserDefaults.standard.set(closeDelay, forKey: "panel.closeDelay") } }
    @Published var display: String { didSet {
        UserDefaults.standard.set(display, forKey: "panel.display")
        NotificationCenter.default.post(name: .init("NotchFlowDisplayChanged"), object: nil)
    } }
    init() {
        let d = UserDefaults.standard
        width = d.object(forKey: "panel.width") == nil ? 460 : min(480, max(420, d.double(forKey: "panel.width")))
        closeDelay = d.object(forKey: "panel.closeDelay") == nil ? 0.08 : min(0.4, max(0.04, d.double(forKey: "panel.closeDelay")))
        display = d.string(forKey: "panel.display") ?? "auto"
    }
    static func id(_ screen: NSScreen) -> String { String(describing: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "") }
}

struct PreferencesView: View {
    @ObservedObject var settings: Preferences
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var feedback: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Display", selection: $settings.display) {
                    Text("Automatic · prefer notch").tag("auto")
                    ForEach(NSScreen.screens, id: \.self) { screen in Text(screen.localizedName).tag(Preferences.id(screen)) }
                }
                HStack { Text("Panel width"); Slider(value: $settings.width, in: 420...480, step: 10); Text("\(Int(settings.width))") }
                HStack { Text("Close delay"); Slider(value: $settings.closeDelay, in: 0.04...0.4, step: 0.02); Text("\(Int(settings.closeDelay * 1000)) ms") }
                Toggle("Launch at login", isOn: Binding(get: { login }, set: { value in
                    do {
                        if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        login = SMAppService.mainApp.status == .enabled
                        feedback = value && !login ? "Approval required in Login Items." : nil
                    } catch { feedback = error.localizedDescription }
                }))
                Text("Accessibility: " + (AXIsProcessTrusted() ? "Allowed" : "Not allowed")).foregroundStyle(.gray)
                HStack {
                    Button("Accessibility") { open("Privacy_Accessibility") }
                    Button("Automation") { open("Privacy_Automation") }
                    Button("Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
                Text("Calls and message mirroring: experimental. Accept/decline controls appear only when recognized; use the original app if none appear.")
                    .foregroundStyle(.orange)
                if let feedback { Text(feedback).foregroundStyle(.orange) }
                Text("Reduce Motion follows macOS. Player permissions are checked when connecting.").foregroundStyle(.gray)
            }.font(.system(size: 11)).padding(.trailing, 5)
        }
    }
    private func open(_ section: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?" + section)!)
    }
}
