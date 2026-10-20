# Verification and remaining work

## Apple Music runtime verification — 2026-10-10

- Played the existing local track: title appeared automatically in the compact island; it disappeared when playback ended.
- Played the free Apple Music 1 live station: compact island displayed the current song title and artist.
- Expanded the island: the player displayed LIVE / STREAM, without an invalid seek duration.
- Pressed Pause in NotchFlow: the Apple Music transport returned to Play and the stream stopped. Test playback was left stopped.
- Source selection was set to Apple Music. This verifies this Mac's current Music integration, not Spotify or YouTube.
- Automated JavaScript tests also cover missing currentTrack/position/duration with a valid stream title.

## Implemented in this iteration

- Media remembers its selected source after a successful connection; periodically reconnects when the player returns. Permission denial disables retries. Pending playback commands are retained during status refresh.
- Seek slider for Music, Spotify, and supported Chrome YouTube video tabs. Spotify remote artwork and Apple Music local artwork, with placeholders on failure.
- Persisted screen selection, expanded width and exit grace period; launch-at-login toggle; links to privacy settings.
- Tool changes cross-fade; main-window geometry stays fixed while content morphs. Reduce Motion remains respected.
- File shelf: Quick Look window, native share menu, missing-file indication, bookmark-based relocation when macOS can resolve the original, canonicalized file identity, and removal without deleting originals.
- App pins, window pins keyed by app and exact title, recent-app ordering, Control–Option–N global shortcut.
- Permission and experimental-support messaging for calls/notifications.

## Automated checks

Run `.build/release/NotchFlow --self-test` after `swift build -c release`.
Checks cover canonical file reference persistence, deduplication, original-file preservation, missing-file rejection, activity input validation/lifecycle, and activity presentation priority.

## Requires real-device integration testing

- Apple Music/Spotify artwork, playback controls and seeking with granted Automation permission and real tracks.
- Chrome YouTube controls after user enables its Apple Events JavaScript setting.
- Quick Look and sharing for multiple file types; AirDrop only when available from the native share sheet.
- Screen disconnect/reconnect, sleep/wake, full-screen apps, mixed display scaling, rapid cursor movement.
- Pin persistence where a Terminal or Codex window changes its title: changed titles are treated as different windows.
- Registered shortcut availability if another app uses Control–Option–N.
- WhatsApp and FaceTime incoming calls, notification banners, language variants. These remain experimental, not certified supported.

No automated test has proven end-to-end media playback or calling support. The application must not be described as 100% equivalent to DynamicLake.
