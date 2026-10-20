import SwiftUI
import AppKit

enum MediaSource: String, CaseIterable, Identifiable {
    case music = "Apple Music", spotify = "Spotify", youtube = "YouTube · Chrome"
    var id: String { rawValue }
    var bundle: String {
        switch self { case .music: return "com.apple.Music"; case .spotify: return "com.spotify.client"; case .youtube: return "com.google.Chrome" }
    }
}

final class MediaPlayer: ObservableObject {
    @Published var source: MediaSource = .music
    @Published var title = "Connect a player"
    @Published var artist = ""
    @Published var playing = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var error: String?
    @Published var connected = false
    @Published var busy = false
    @Published var artwork: URL?
    @Published var localArtwork: NSImage?
    private var artworkKey = ""
    private var reconnect = false
    private var retryAfter = Date.distantPast
    private var pending: String?
    private let queue = DispatchQueue(label: "notchflow.media")
    private var timer: Timer?
    private var generation = 0
    private var playbackObservers: [NSObjectProtocol] = []
    private var youtubeProbeRunning = false
    private var lastYouTubeProbe = Date.distantPast
    private var lastRefresh = Date.distantPast
    private var youtubeBrowserBundle = "com.google.Chrome"
    private let youtubeBrowsers = ["com.apple.Safari", "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac"]
    init() {
        source = MediaSource(rawValue: UserDefaults.standard.string(forKey: "media.source") ?? "") ?? .music
        reconnect = UserDefaults.standard.bool(forKey: "media.reconnect")
        for name in ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            playbackObservers.append(DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] notification in
                guard let self, let info = notification.userInfo else { return }
                let origin: MediaSource = name.hasPrefix("com.spotify") ? .spotify : .music
                guard self.source == origin, !UserDefaults.standard.bool(forKey: "media.disabled") else { return }
                let status = info["Player State"] as? String ?? ""
                guard ["Playing", "Paused", "Stopped"].contains(status) else { return }
                self.playing = status == "Playing"
                self.connected = status != "Stopped"
                if let title = info["Name"] as? String, !title.isEmpty { self.title = title }
                else if self.playing { self.title = "Live radio / audio" }
                self.artist = info["Artist"] as? String ?? origin.rawValue
                // Native playback events can display status without Automation.
                // Commands and full metadata still require an explicit connection.
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard !UserDefaults.standard.bool(forKey: "media.disabled") else { return }
            if self.playing && self.duration > 0 { self.position = min(self.duration, self.position + 1) }
            if !self.playing && Date().timeIntervalSince(self.lastYouTubeProbe) > 10 {
                self.discoverYouTube()
            }
            let interval: TimeInterval = self.playing ? 3 : 8
            if self.reconnect && Date().timeIntervalSince(self.lastRefresh) >= interval && (self.connected || Date() > self.retryAfter) { self.refresh() }
        }
        timer?.tolerance = 0.15
        BackgroundWork.shared.register(timer!)
    }
    deinit {
        timer?.invalidate()
        playbackObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    }
    func select(_ value: MediaSource) {
        if value == source { connect(); return }
        generation += 1; source = value; connected = false
        reconnect = false; pending = nil; artwork = nil; localArtwork = nil; artworkKey = ""
        UserDefaults.standard.set(value.rawValue, forKey: "media.source")
        UserDefaults.standard.set(false, forKey: "media.reconnect")
        title = "Connect a player"; artist = ""; position = 0; duration = 0; error = nil; playing = false
        connect()
    }
    func connect() {
        UserDefaults.standard.set(false, forKey: "media.disabled")
        reconnect = true
        refresh()
    }
    func disconnect() {
        generation += 1; reconnect = false; connected = false; playing = false; pending = nil
        UserDefaults.standard.set(true, forKey: "media.disabled")
        UserDefaults.standard.set(false, forKey: "media.reconnect")
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite, duration > 0 else { return }
        control("seek:" + String(min(duration, max(0, seconds))))
    }
    func refresh() { lastRefresh = Date(); execute(command: nil) }
    func control(_ command: String) { execute(command: command) }

    private func execute(command: String?) {
        guard !busy else { if let command { pending = command }; return }
        let target = source
        let targetBundle = target == .youtube ? runningYouTubeBrowser() ?? target.bundle : target.bundle
        guard NSRunningApplication.runningApplications(withBundleIdentifier: targetBundle).first != nil else {
            connected = false; playing = false; retryAfter = Date().addingTimeInterval(5)
            error = "Waiting for \(target.rawValue). Open it and start playback."; return
        }
        let token = generation
        if target == .youtube { youtubeBrowserBundle = targetBundle }
        let script = Self.script(source: target, command: command, browserBundle: targetBundle)
        busy = true
        queue.async { [weak self] in
            // Run out of process: Apple Events timeouts must not block hover or animation.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", target == .youtube ? "AppleScript" : "JavaScript", "-e", script]
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output; process.standardError = errors
            var data = Data(), failure: String?
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                    if process.isRunning { process.terminate() }
                }
                process.waitUntilExit()
                data = output.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus != 0 {
                    failure = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                }
            } catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                guard token == self.generation else { return }
                defer {
                    if let next = self.pending {
                        self.pending = nil
                        self.control(next)
                    }
                }
                if let failure {
                    self.connected = false
                    self.playing = false
                    self.retryAfter = Date().addingTimeInterval(8)
                    if failure.contains("-1743") || target == .youtube {
                        self.reconnect = false
                        UserDefaults.standard.set(false, forKey: "media.reconnect")
                    }
                    self.error = failure.contains("-1743")
                        ? "Allow NotchFlow in System Settings → Privacy & Security → Automation, then reconnect."
                        : target == .youtube
                        ? "Open a playing YouTube video. Safari/Chromium may also require Develop → Allow JavaScript from Apple Events."
                        : "Player connection failed: " + (failure.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "request timed out; check Automation permission." : String(failure.prefix(300)))
                    return
                }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.error = "Could not decode player status. Retrying."; self.connected = false; self.playing = false
                    self.retryAfter = Date().addingTimeInterval(5); return
                }
                self.title = object["title"] as? String ?? "Unknown track"
                self.artist = object["artist"] as? String ?? target.rawValue
                self.playing = object["playing"] as? Bool ?? false
                self.position = max(0, object["position"] as? Double ?? 0)
                self.duration = max(0, object["duration"] as? Double ?? 0)
                if let text = object["artwork"] as? String, let url = URL(string: text),
                   url.scheme == "https", let host = url.host,
                   host == "i.scdn.co" || host.hasSuffix(".spotifycdn.com") {
                    self.artwork = url
                } else { self.artwork = nil }
                self.connected = true
                UserDefaults.standard.set(target.rawValue, forKey: "media.source")
                UserDefaults.standard.set(true, forKey: "media.reconnect")
                self.error = nil
                if target == .music {
                    let key = self.title + self.artist
                    if self.artworkKey != key {
                        self.artworkKey = key
                        self.localArtwork = nil
                        self.loadMusicArtwork(generation: token, key: key)
                    }
                }
            }
        }
    }

    private func runningYouTubeBrowser() -> String? {
        youtubeBrowsers.first { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    private func discoverYouTube() {
        guard !youtubeProbeRunning, let browser = runningYouTubeBrowser(),
              !UserDefaults.standard.bool(forKey: "media.disabled") else { return }
        lastYouTubeProbe = Date()
        youtubeProbeRunning = true
        let script = Self.script(source: .youtube, command: nil, browserBundle: browser)
        queue.async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            var object: [String: Any]?
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if process.isRunning { process.terminate() } }
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                }
            } catch {}
            DispatchQueue.main.async {
                guard let self else { return }
                self.youtubeProbeRunning = false
                guard object?["playing"] as? Bool == true else {
                    if browser == "com.apple.Safari" { self.detectBlockedSafariYouTube() }
                    return
                }
                self.generation += 1
                self.source = .youtube
                self.youtubeBrowserBundle = browser
                self.connected = true
                self.reconnect = true
                self.playing = true
                self.title = object?["title"] as? String ?? "YouTube"
                self.artist = "YouTube"
                self.position = object?["position"] as? Double ?? 0
                self.duration = object?["duration"] as? Double ?? 0
                self.error = nil
                UserDefaults.standard.set(MediaSource.youtube.rawValue, forKey: "media.source")
                UserDefaults.standard.set(true, forKey: "media.reconnect")
            }
        }
    }

    private func detectBlockedSafariYouTube() {
        let script = """
        tell application id "com.apple.Safari"
          repeat with w in windows
            repeat with t in tabs of w
              if visible of t is true and (URL of t starts with "https://www.youtube.com/watch" or URL of t starts with "https://music.youtube.com/watch") then
                return name of t
              end if
            end repeat
          end repeat
          return ""
        end tell
        """
        queue.async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run(); process.waitUntilExit()
                let title = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard process.terminationStatus == 0, !title.isEmpty else { return }
                DispatchQueue.main.async {
                    guard let self, !self.playing else { return }
                    self.source = .youtube
                    self.title = title.replacingOccurrences(of: " - YouTube", with: "")
                    self.artist = "YouTube · Safari"
                    self.connected = false
                    self.error = "Safari found this YouTube tab, but cannot read playback. In Safari choose Develop → Allow JavaScript from Apple Events, then open Media and press Connect player."
                    UserDefaults.standard.set(MediaSource.youtube.rawValue, forKey: "media.source")
                }
            } catch {}
        }
    }

    private func loadMusicArtwork(generation: Int, key: String) {
        queue.async { [weak self] in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("notchflow-art-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: url) }
            let script = """
            with timeout of 3 seconds
              tell application id "com.apple.Music"
                set imageData to raw data of artwork 1 of current track
              end tell
              set outputFile to open for access POSIX file "\(url.path)" with write permission
              try
                write imageData to outputFile
                close access outputFile
              on error
                close access outputFile
              end try
            end timeout
            """
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 4) { if task.isRunning { task.terminate() } }
                task.waitUntilExit()
                guard task.terminationStatus == 0,
                      let data = try? Data(contentsOf: url), data.count < 8_000_000 else { return }
                DispatchQueue.main.async {
                    guard let self, self.generation == generation, self.artworkKey == key else { return }
                    self.localArtwork = NSImage(data: data)
                }
            } catch {}
        }
    }

    static func script(source: MediaSource, command: String?, browserBundle: String = "com.google.Chrome") -> String {
        // JXA produces correctly escaped JSON even for track titles containing quotes.
        let seek = command.flatMap { $0.hasPrefix("seek:") ? Double($0.dropFirst(5)) : nil }.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        var action: String
        switch command {
        case "toggle": action = "app.playpause();"
        case "next": action = "app.nextTrack();"
        case "previous": action = "app.previousTrack();"
        default: action = ""
        }
        if let seek { action = "app.playerPosition = \(seek);" }
        if source != .youtube {
            let scale = source == .spotify ? "1000" : "1"
            let js = """
            var app = Application('\(source.bundle)');
            \(action)
            // playerState is required: permission failures must not be swallowed.
            var state = String(app.playerState()).toLowerCase();
            function optional(read, fallback) {
                try { var value = read(); return value === null || value === undefined ? fallback : value; }
                catch(e) { return fallback; }
            }
            function text(value) { return typeof value === 'string' ? value.slice(0,300) : ''; }
            function number(value) { return typeof value === 'number' && isFinite(value) && value >= 0 ? value : 0; }
            var track = optional(function(){ return app.currentTrack(); }, null);
            var title = text(optional(function(){ return track.name(); }, ''));
            var stream = text(optional(function(){ return app.currentStreamTitle(); }, ''));
            if (stream) title = stream;
            if (!title) title = state === 'playing' ? 'Live radio / audio' : 'No active track';
            JSON.stringify({
                title: title,
                artist: text(optional(function(){ return track.artist(); }, '')) || '\(source.rawValue)',
                playing: state === 'playing',
                position: number(optional(function(){ return app.playerPosition(); }, 0)),
                duration: number(optional(function(){ return track.duration(); }, 0))/\(scale),
                artwork: text(optional(function(){ return track.artworkUrl(); }, ''))
            });
            """
            return js
        }
        var videoAction: String
        switch command {
        case "toggle": videoAction = "if(v.paused){v.play().catch(()=>{});}else{v.pause();}"
        case "next": videoAction = "document.querySelector('.ytp-next-button')?.click();"
        case "previous": videoAction = "v.currentTime=0;"
        default: videoAction = ""
        }
        if let seek { videoAction = "v.currentTime=\(seek);" }
        let js = """
        (()=>{const v=document.querySelector('video');if(!v)throw Error('No video');\(videoAction)return JSON.stringify({title:document.title.slice(0,300),artist:'YouTube',playing:!v.paused,position:v.currentTime,duration:Number.isFinite(v.duration)?v.duration:0});})()
        """
        if browserBundle == "com.apple.Safari" {
            return """
            with timeout of 3 seconds
              tell application id "com.apple.Safari"
                repeat with w in windows
                  repeat with t in tabs of w
                    if URL of t starts with "https://www.youtube.com/watch" or URL of t starts with "https://music.youtube.com/watch" then
                      return do JavaScript "\(escape(js))" in t
                    end if
                  end repeat
                end repeat
                error "Open a YouTube video first"
              end tell
            end timeout
            """
        }
        return """
        with timeout of 3 seconds
          tell application id "\(browserBundle)"
            repeat with w in windows
              repeat with t in tabs of w
                if URL of t starts with "https://www.youtube.com/watch" or URL of t starts with "https://music.youtube.com/watch" then
                  return execute t javascript "\(escape(js))"
                end if
              end repeat
            end repeat
            error "Open a YouTube video first"
          end tell
        end timeout
        """
    }
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ")
    }
}

struct MediaView: View {
    @ObservedObject var player: MediaPlayer
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ForEach(MediaSource.allCases) { source in
                    Button(source == .youtube ? "YouTube" : source.rawValue) { player.select(source) }
                        .foregroundStyle(player.source == source ? .mint : .gray)
                }
                Spacer()
            }.font(.system(size: 11))
            HStack(spacing: 14) {
                Group {
                  if let image = player.localArtwork {
                    Image(nsImage: image).resizable().scaledToFill()
                  } else {
                   AsyncImage(url: player.artwork) { image in image.resizable().scaledToFill() } placeholder: {
                    Image(systemName: player.playing ? "waveform" : "music.note").font(.system(size: 32))
                   }
                  }
                }
                    .frame(width: 62, height: 62).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text(player.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    Text(player.artist).font(.system(size: 11)).foregroundStyle(.gray).lineLimit(1)
                }
            }
            if player.connected {
                if player.duration > 0 {
                 Slider(value: Binding(get: { scrubbing ? scrubPosition : min(player.position, max(1, player.duration)) }, set: { scrubPosition = $0 }),
                       in: 0...max(1, player.duration), onEditingChanged: { editing in
                    scrubbing = editing
                    if !editing { player.seek(scrubPosition) }
                }).tint(.mint).disabled(player.duration <= 0)
                } else {
                    Text(player.playing ? "● LIVE / STREAM" : "Duration unavailable").font(.system(size: 10, weight: .semibold)).foregroundStyle(.mint)
                }
                HStack {
                    Text(time(player.position)).font(.system(size: 10)).monospacedDigit().foregroundStyle(.gray)
                    Spacer()
                    Button { player.control("previous") } label: { Image(systemName: "backward.end.fill") }
                    Button { player.control("toggle") } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 25)) }
                    Button { player.control("next") } label: { Image(systemName: "forward.end.fill") }
                    Spacer()
                    Text(time(player.duration)).font(.system(size: 10)).monospacedDigit().foregroundStyle(.gray)
                }
                Button("Disconnect") { player.disconnect() }.font(.system(size: 10)).foregroundStyle(.gray)
            } else {
                Button(player.busy ? "Connecting…" : "Connect player") { player.connect() }.disabled(player.busy)
            }
            if let error = player.error { Text(error).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }.buttonStyle(.plain)
    }
    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < 1e8 else { return "0:00" }
        let value = Int(seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
