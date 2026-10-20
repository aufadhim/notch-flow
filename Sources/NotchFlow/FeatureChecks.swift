import Foundation
import JavaScriptCore

final class FeatureChecks {
    static func run() throws {
        let checks = FeatureChecks()
        try checks.testShelfReferencesPersistWithoutMovingOrDeletingOriginal()
        checks.testActivityValidationAndUpdateLifecycle()
        checks.testActivityPresentation()
        checks.testRadioMetadata()
        checks.testCallLabels()
        checks.testHoverTopEdge()
        print("PASS: shelf persistence, deduplication, original-file preservation, missing-file rejection")
        print("PASS: activity validation, update, completion and dismissal")
        print("PASS: Mini Dock default, open-page preservation, simultaneous activities")
        print("PASS: radio without track metadata and normal music metadata")
    }
    func testHoverTopEdge() {
        for rect in [CGRect(x: 500, y: 970, width: 180, height: 30),
                     CGRect(x: -900, y: 700, width: 440, height: 300)] {
            XCTAssertEqual(NotchHoverRegion.contains(CGPoint(x: rect.midX, y: rect.maxY), in: rect), true)
            XCTAssertEqual(NotchHoverRegion.contains(CGPoint(x: rect.midX, y: rect.maxY - 1), in: rect), true)
            XCTAssertEqual(NotchHoverRegion.contains(CGPoint(x: rect.midX, y: rect.maxY + 1), in: rect), false)
            XCTAssertEqual(NotchHoverRegion.contains(CGPoint(x: rect.maxX + 1, y: rect.maxY), in: rect), false)
            XCTAssertEqual(NotchHoverRegion.contains(CGPoint(x: rect.midX, y: rect.minY - 1), in: rect), false)
        }
        print("PASS: notch hover includes exact screen top; outside points remain excluded")
    }
    func testRadioMetadata() {
        let context = JSContext()!
        context.evaluateScript("""
        function Application() { return {
            playerState: function(){ return 'playing'; },
            currentTrack: function(){ throw Error('No track for live radio'); },
            currentStreamTitle: function(){ return 'Live station'; },
            playerPosition: function(){ throw Error('No position'); }
        }; }
        """)
        let result = context.evaluateScript(MediaPlayer.script(source: .music, command: nil))!.toString()!
        let data = try! JSONSerialization.jsonObject(with: Data(result.utf8)) as! [String: Any]
        XCTAssertEqual(data["playing"] as? Bool, true)
        XCTAssertEqual(data["title"] as? String, "Live station")
        XCTAssertEqual(data["duration"] as? Double, 0)
        context.evaluateScript("""
        function Application() { return {
            playerState: function(){ return 'playing'; },
            currentTrack: function(){ return {
                name: function(){ return 'Track title'; },
                artist: function(){ return 'Artist'; },
                duration: function(){ return 240; }
            }; },
            playerPosition: function(){ return 12; }
        }; }
        """)
        let normal = context.evaluateScript(MediaPlayer.script(source: .music, command: nil))!.toString()!
        let track = try! JSONSerialization.jsonObject(with: Data(normal.utf8)) as! [String: Any]
        XCTAssertEqual(track["title"] as? String, "Track title")
        XCTAssertEqual(track["duration"] as? Double, 240)
    }
    func testCallLabels() {
        XCTAssertTrue(CommunicationBridge.isChatBanner("Telegram · Sender · Hello"))
        XCTAssertTrue(CommunicationBridge.isChatBanner("WhatsApp · New message"))
        XCTAssertEqual(CommunicationBridge.isChatBanner("Calendar · Meeting"), false)
        XCTAssertTrue(CommunicationBridge.matchesCallAction("Accept", accept: true))
        XCTAssertTrue(CommunicationBridge.matchesCallAction("Decline", accept: false))
        XCTAssertEqual(CommunicationBridge.matchesCallAction("Send message", accept: false), false)
        XCTAssertEqual(CommunicationBridge.matchesCallAction("Call ended", accept: false), false)
        XCTAssertEqual(CommunicationBridge.matchesCallAction("Accept incoming calls automatically", accept: true), false)
        print("PASS: exact call controls reject unrelated and ended-call labels")
    }
    func testActivityPresentation() {
        let state = IslandState()
        XCTAssertTrue(state.liveItems.isEmpty)
        state.running = true
        state.remaining = 90
        state.media.connected = true
        state.media.playing = true
        state.media.title = "A song"
        XCTAssertEqual(state.liveItems.map(\.id), [1, 5])
        XCTAssertEqual(state.liveItems.first?.detail, "01:30")
        state.openIsland()
        XCTAssertEqual(state.tab, 0)
        state.tab = 5
        state.openIsland()
        XCTAssertEqual(state.tab, 5)
        state.running = false
        state.expanded = false
        state.openIsland()
        XCTAssertEqual(state.tab, 0)
        state.media.playing = false
        state.expanded = false
        state.openIsland()
        XCTAssertEqual(state.tab, 0)
    }
    private func XCTAssertEqual<T: Equatable>(_ left: T, _ right: T) {
        if left != right {
            FileHandle.standardError.write(Data("FAIL: Expected \(left) == \(right)\n".utf8))
            exit(1)
        }
    }
    private func XCTAssertTrue(_ value: Bool) { XCTAssertEqual(value, true) }
    private func XCTAssertNotNil<T>(_ value: T?) { XCTAssertEqual(value != nil, true) }
    func testShelfReferencesPersistWithoutMovingOrDeletingOriginal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("example.txt")
        try Data("original".utf8).write(to: file)
        let suite = "notchflow.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let shelf = FileShelf(defaults: defaults)
        shelf.add(file)
        shelf.add(file)
        XCTAssertEqual(shelf.urls, [file.resolvingSymlinksInPath()])
        XCTAssertEqual(FileShelf(defaults: defaults).urls, [file.resolvingSymlinksInPath()])
        shelf.remove(file)
        XCTAssertEqual(try String(contentsOf: file), "original")
        XCTAssertTrue(FileShelf(defaults: defaults).urls.isEmpty)
        shelf.add(directory.appendingPathComponent("missing"))
        XCTAssertTrue(shelf.urls.isEmpty)
        XCTAssertNotNil(shelf.error)
    }

    func testActivityValidationAndUpdateLifecycle() {
        let state = IslandState()
        state.receive(URL(string: "notchflow://activity?id=build&title=Build&progress=0.4")!)
        XCTAssertEqual(state.activities.count, 1)
        XCTAssertEqual(state.activities.first?.progress, 0.4)
        state.receive(URL(string: "notchflow://activity?id=build&progress=nan")!)
        XCTAssertEqual(state.activities.first?.progress, 0.4)
        state.receive(URL(string: "notchflow://activity?id=build&status=done")!)
        XCTAssertEqual(state.activities.count, 1)
        XCTAssertEqual(state.activities.first?.progress, 1)
        state.receive(URL(string: "notchflow://activity?id=build&action=dismiss")!)
        XCTAssertTrue(state.activities.isEmpty)
        state.receive(URL(string: "https://activity?id=bad")!)
        XCTAssertTrue(state.activities.isEmpty)
    }
}
