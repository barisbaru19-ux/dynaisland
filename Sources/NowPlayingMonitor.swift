import AppKit
import SwiftUI

/// Reads "now playing" from Spotify and Apple Music.
///
/// Since macOS 15.4 third-party apps can no longer read the system-wide Now Playing
/// info (private MediaRemote framework), so this talks to the players directly:
///  - distributed notifications from Spotify/Music → instant updates, no permission needed
///  - AppleScript every second → position, artwork and playback controls
///    (needs the one-time "Automation" permission prompt).
@MainActor
final class NowPlayingMonitor: NSObject {
    private let model: IslandModel
    private var timer: Timer?
    private var statusScripts: [PlayerSource: NSAppleScript] = [:]
    private var commandScripts: [String: NSAppleScript] = [:]
    private var musicArtworkScript: NSAppleScript?
    private var artworkKey = ""
    private var musicArtworkRetries = 0

    private enum QueryResult {
        case track(TrackInfo)
        case nothing
        case denied
    }

    init(model: IslandModel) {
        self.model = model
        super.init()
    }

    func start() {
        model.player = self

        let center = DistributedNotificationCenter.default()
        for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo"] {
            center.addObserver(self,
                               selector: #selector(playerNotification(_:)),
                               name: Notification.Name(name),
                               object: nil,
                               suspensionBehavior: .deliverImmediately)
        }

        let timer = Timer(timeInterval: 1.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        refresh()
    }

    // MARK: - Controls (called from the expanded island)

    func playPause() {
        guard var track = model.track else { return }
        send("playpause", to: track.source)
        // Optimistic UI so the button flips immediately.
        if track.isPlaying {
            let elapsed = Date().timeIntervalSince(model.sampledAt)
            track.position = track.duration > 0
                ? min(track.duration, track.position + elapsed)
                : track.position + elapsed
        }
        track.isPlaying.toggle()
        model.track = track
        model.sampledAt = Date()
        refreshSoon()
    }

    func next() {
        guard let source = model.track?.source else { return }
        send("next track", to: source)
        refreshSoon()
    }

    func previous() {
        guard let source = model.track?.source else { return }
        send("previous track", to: source)
        refreshSoon()
    }

    func openPlayerApp() {
        guard let source = model.track?.source,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    // MARK: - Updates

    @objc private func tick() {
        refresh()
    }

    @objc private func playerNotification(_ note: Notification) {
        if model.automationDenied {
            applyNotification(note)   // no AppleScript access → use what the notification tells us
        } else {
            refresh()
            refreshSoon()
        }
    }

    private func refreshSoon() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.refresh()
        }
    }

    func refresh() {
        var found: [TrackInfo] = []
        var denied = false

        for source in PlayerSource.allCases where isRunning(source) {
            switch query(source) {
            case .track(let info): found.append(info)
            case .nothing: break
            case .denied: denied = true
            }
        }

        if found.isEmpty {
            if model.automationDenied != denied { model.automationDenied = denied }
            if denied { return }   // keep the notification-based info
            if model.track != nil {
                model.track = nil
                model.artwork = nil
                model.accent = .white
                artworkKey = ""
            }
            return
        }
        // The chosen track comes from a player we *can* script, so the controls work.
        if model.automationDenied { model.automationDenied = false }
        apply(choose(from: found))
    }

    private func choose(from list: [TrackInfo]) -> TrackInfo {
        let current = model.track?.source
        let playing = list.filter { $0.isPlaying }
        if let current = current, let same = playing.first(where: { $0.source == current }) { return same }
        if let first = playing.first { return first }
        if let current = current, let same = list.first(where: { $0.source == current }) { return same }
        return list[0]
    }

    private func apply(_ info: TrackInfo) {
        let old = model.track
        if old != info {
            model.track = info
            model.sampledAt = Date()
        }

        let isNewTrack = old?.id != info.id || old?.source != info.source
        if isNewTrack {
            if info.isPlaying { model.peek() }
        } else if old?.isPlaying == false && info.isPlaying {
            model.peek(seconds: 2)
        }
        loadArtworkIfNeeded(for: info)
    }

    private func applyNotification(_ note: Notification) {
        guard let info = note.userInfo else { return }
        let source: PlayerSource = note.name.rawValue.hasPrefix("com.spotify") ? .spotify : .music
        let state = ((info["Player State"] as? String) ?? "").lowercased()

        if state == "stopped" || state.isEmpty {
            if model.track?.source == source {
                model.track = nil
                model.artwork = nil
                artworkKey = ""
            }
            return
        }

        let title = (info["Name"] as? String) ?? ""
        let artist = (info["Artist"] as? String) ?? ""
        let album = (info["Album"] as? String) ?? ""
        let durationMs = (info["Duration"] as? NSNumber)?.doubleValue
            ?? (info["Total Time"] as? NSNumber)?.doubleValue
            ?? 0
        let position = (info["Playback Position"] as? NSNumber)?.doubleValue ?? 0
        let id = (info["Track ID"] as? String)
            ?? (info["PersistentID"] as? NSNumber)?.stringValue
            ?? "\(title)|\(artist)"

        apply(TrackInfo(source: source,
                        id: id,
                        title: title,
                        artist: artist,
                        album: album,
                        duration: durationMs / 1000,
                        position: position,
                        isPlaying: state == "playing",
                        artworkURL: ""))
    }

    // MARK: - AppleScript

    private func isRunning(_ source: PlayerSource) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).isEmpty
    }

    private func query(_ source: PlayerSource) -> QueryResult {
        guard let script = statusScript(for: source) else { return .nothing }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error = error {
            let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            return (code == -1743 || code == -1744) ? .denied : .nothing
        }
        guard result.numberOfItems >= 8,
              let state = result.atIndex(1)?.stringValue,
              state == "playing" || state == "paused" else { return .nothing }

        func text(_ index: Int) -> String { result.atIndex(index)?.stringValue ?? "" }
        func number(_ index: Int) -> Double { result.atIndex(index)?.doubleValue ?? 0 }

        return .track(TrackInfo(source: source,
                                id: text(8),
                                title: text(2),
                                artist: text(3),
                                album: text(4),
                                duration: number(5),
                                position: number(6),
                                isPlaying: state == "playing",
                                artworkURL: text(7)))
    }

    /// Compiled lazily, only once the player is running — compiling a `tell` for an app
    /// that isn't installed would pop up a "Where is …?" dialog.
    private func statusScript(for source: PlayerSource) -> NSAppleScript? {
        if let cached = statusScripts[source] { return cached }

        let body: String
        switch source {
        case .spotify:
            body = """
            set ps to player state as string
            if ps is "stopped" then return {"stopped"}
            set t to current track
            return {ps, (name of t), (artist of t), (album of t), ((duration of t) / 1000), (player position), (artwork url of t), (id of t)}
            """
        case .music:
            body = """
            set ps to player state as string
            if ps is "stopped" then return {"stopped"}
            set t to current track
            return {ps, (name of t), (artist of t), (album of t), (duration of t), (player position), "", (persistent ID of t)}
            """
        }

        let text = """
        if application id "\(source.bundleID)" is running then
            tell application id "\(source.bundleID)"
                with timeout of 1 second
                    try
        \(body)
                    on error errMsg number errNum
                        if errNum is -1743 or errNum is -1744 then error errMsg number errNum
                        return {"stopped"}
                    end try
                end timeout
            end tell
        end if
        return {"notrunning"}
        """

        guard let script = compile(text) else { return nil }
        statusScripts[source] = script
        return script
    }

    private func send(_ command: String, to source: PlayerSource) {
        guard isRunning(source) else { return }
        let key = "\(source.rawValue)|\(command)"
        let script: NSAppleScript
        if let cached = commandScripts[key] {
            script = cached
        } else {
            guard let compiled = compile("tell application id \"\(source.bundleID)\" to \(command)") else { return }
            commandScripts[key] = compiled
            script = compiled
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
    }

    private func compile(_ source: String) -> NSAppleScript? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let ok = script.compileAndReturnError(&error)
        if !ok {
            print("DynaIsland: AppleScript compile error: \(String(describing: error))")
            return nil
        }
        return script
    }

    // MARK: - Artwork

    private func loadArtworkIfNeeded(for info: TrackInfo) {
        // Include the URL for Spotify so a URL that arrives a moment later still loads.
        let key = "\(info.source.rawValue)|\(info.id)|\(info.artworkURL)"
        guard key != artworkKey else { return }
        let sameTrack = artworkKey.hasPrefix("\(info.source.rawValue)|\(info.id)|")
        artworkKey = key
        if !sameTrack {
            model.artwork = nil
            model.accent = .white
            musicArtworkRetries = 0
        }

        switch info.source {
        case .spotify:
            guard !info.artworkURL.isEmpty, let url = URL(string: info.artworkURL) else { return }
            Task { [weak self] in
                guard let result = try? await URLSession.shared.data(from: url),
                      let image = NSImage(data: result.0) else { return }
                guard let self = self, self.artworkKey == key else { return }
                self.setArtwork(image)
            }
        case .music:
            if let image = fetchMusicArtwork() {
                setArtwork(image)
            } else if musicArtworkRetries < 3 {
                // Streamed tracks sometimes have no artwork for a moment after a change.
                // A different key makes the next tick try again without clearing anything.
                musicArtworkRetries += 1
                artworkKey = "\(info.source.rawValue)|\(info.id)|retry"
            }
        }
    }

    private func fetchMusicArtwork() -> NSImage? {
        if musicArtworkScript == nil {
            musicArtworkScript = compile("""
            if application id "com.apple.Music" is running then
                tell application id "com.apple.Music"
                    with timeout of 3 seconds
                        try
                            return raw data of artwork 1 of current track
                        end try
                    end timeout
                end tell
            end if
            return missing value
            """)
        }
        guard let script = musicArtworkScript else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        let data = result.data
        guard !data.isEmpty else { return nil }
        return NSImage(data: data)
    }

    private func setArtwork(_ image: NSImage) {
        model.artwork = image
        model.accent = Color(nsColor: image.vibrantAccent())
    }
}

// MARK: - Accent colour from album art (like iOS tints the waveform)

extension NSImage {
    func vibrantAccent() -> NSColor {
        let side = 12
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: side,
                                         pixelsHigh: side,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return .white }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
        for x in 0..<side {
            for y in 0..<side {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                // Favour colourful, bright pixels so the accent isn't muddy.
                let w = Double(0.12 + s * b)
                red += Double(color.redComponent) * w
                green += Double(color.greenComponent) * w
                blue += Double(color.blueComponent) * w
                weight += w
            }
        }
        guard weight > 0 else { return .white }

        let average = NSColor(deviceRed: CGFloat(red / weight),
                              green: CGFloat(green / weight),
                              blue: CGFloat(blue / weight),
                              alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        average.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.18 { return NSColor(white: 0.92, alpha: 1) }
        return NSColor(deviceHue: h, saturation: min(1, s * 1.15 + 0.1), brightness: max(0.82, b), alpha: 1)
    }
}
