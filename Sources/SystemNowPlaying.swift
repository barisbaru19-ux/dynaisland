import AppKit
import SwiftUI

/// "Now Playing" from every app: YouTube in any browser, Apple Podcasts, VLC, Spotify, Music…
///
/// Since macOS 15.4 only Apple's own programs may read the system Now Playing info. Apple's
/// /usr/bin/perl still can, so DynaIsland runs the open-source mediaremote-adapter
/// (BSD 3-Clause, github.com/ungive/mediaremote-adapter) through it and reads its JSON output.
/// When the adapter isn't bundled or doesn't work, the Spotify / Music AppleScript path stays in charge.
@MainActor
final class SystemNowPlaying {
    enum Command: Int {
        case play = 0, pause = 1, togglePlayPause = 2, next = 4, previous = 5
    }

    private let model: IslandModel
    private var process: Process?
    private var buffer = Data()
    private var state: [String: Any] = [:]
    private var artworkFingerprint = ""
    private var appNames: [String: String] = [:]
    private var restarts = 0
    private var stopping = false

    /// True once the adapter has produced output, i.e. it works on this Mac.
    private(set) var isActive = false

    init(model: IslandModel) {
        self.model = model
    }

    private static var scriptURL: URL? {
        Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl")
    }

    private static var frameworkURL: URL? {
        guard let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static var isBundled: Bool { scriptURL != nil && frameworkURL != nil }

    func start() {
        guard process == nil, !stopping,
              let script = SystemNowPlaying.scriptURL,
              let framework = SystemNowPlaying.frameworkURL else { return }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = [script.path, framework.path, "stream", "--no-diff", "--debounce=150"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }   // end of output
            let monitor = self
            Task { @MainActor in
                monitor?.receive(data)
            }
        }
        task.terminationHandler = { [weak self] _ in
            let monitor = self
            Task { @MainActor in
                monitor?.terminated()
            }
        }

        do {
            try task.run()
            process = task
        } catch {
            process = nil
        }
    }

    func stop() {
        stopping = true
        process?.terminate()
        process = nil
    }

    /// Play/pause, next, previous for whichever app is playing.
    func send(_ command: Command) {
        guard let script = SystemNowPlaying.scriptURL, let framework = SystemNowPlaying.frameworkURL else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = [script.path, framework.path, "send", String(command.rawValue)]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }

    // MARK: - Output

    private func terminated() {
        process = nil
        let wasActive = isActive
        isActive = false
        guard !stopping else { return }
        if wasActive {
            // Hand control back to the Spotify / Music path until the adapter is running again.
            model.player?.refresh()
        }
        guard restarts < 3 else { return }
        restarts += 1
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.start()
        }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line)
        }
        if buffer.count > 16_000_000 { buffer.removeAll() }   // never let a broken stream grow forever
    }

    private func handle(_ line: Data) {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (object["type"] as? String) == "data" else { return }
        let payload = object["payload"] as? [String: Any] ?? [:]
        if (object["diff"] as? Bool) == true {
            for (key, value) in payload {
                if value is NSNull { state[key] = nil } else { state[key] = value }
            }
        } else {
            state = payload
        }
        if !isActive {
            isActive = true
            restarts = 0
            model.automationDenied = false
        }
        apply()
    }

    private func apply() {
        guard let title = state["title"] as? String, !title.isEmpty,
              let bundle = state["bundleIdentifier"] as? String else {
            if model.track != nil {
                model.track = nil
                model.artwork = nil
                model.accent = .white
                artworkFingerprint = ""
            }
            return
        }

        let app = (state["parentApplicationBundleIdentifier"] as? String) ?? bundle
        let artist = state["artist"] as? String ?? ""
        let album = state["album"] as? String ?? ""
        let playing = (state["playing"] as? Bool) ?? false
        let duration = SystemNowPlaying.number(state["duration"]) ?? 0
        var position = SystemNowPlaying.number(state["elapsedTime"]) ?? 0
        // elapsedTime is the position at `timestamp`: move it forward to now.
        if playing, let stamp = SystemNowPlaying.date(state["timestamp"]) {
            let rate = SystemNowPlaying.number(state["playbackRate"]) ?? 1
            position += max(0, Date().timeIntervalSince(stamp)) * (rate > 0 ? rate : 1)
        }
        if duration > 0 { position = min(position, duration) }

        let source: PlayerSource
        switch app {
        case PlayerSource.spotify.bundleID: source = .spotify
        case PlayerSource.music.bundleID: source = .music
        default: source = .system
        }

        let info = TrackInfo(source: source,
                             id: "\(app)|\(title)|\(artist)|\(album)",
                             title: title,
                             artist: artist,
                             album: album,
                             duration: duration,
                             position: position,
                             isPlaying: playing,
                             artworkURL: "",
                             appBundleID: app,
                             appName: appName(for: app))
        let isNewTrack = model.track?.id != info.id
        model.player?.applyTrack(info, loadArtwork: false)
        if isNewTrack { artworkFingerprint = "" }   // same cover as the last song still needs setting
        updateArtwork()
    }

    private func updateArtwork() {
        guard let base64 = state["artworkData"] as? String, !base64.isEmpty else {
            // No picture (yet): keep whatever belongs to the same track.
            return
        }
        let fingerprint = "\(base64.count)|\(base64.prefix(64))|\(base64.suffix(64))"
        guard fingerprint != artworkFingerprint else { return }
        artworkFingerprint = fingerprint
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let image = NSImage(data: data) else { return }
        model.artwork = image
        model.accent = Color(nsColor: image.vibrantAccent())
    }

    private func appName(for bundleID: String) -> String {
        if let cached = appNames[bundleID] { return cached }
        var name = bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        }
        appNames[bundleID] = name
        return name
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    /// The adapter's timestamp: an ISO 8601 string or seconds / milliseconds since 1970.
    private static func date(_ value: Any?) -> Date? {
        if let text = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            if let seconds = Double(text) { return epochDate(seconds) }
            return nil
        }
        if let number = value as? NSNumber { return epochDate(number.doubleValue) }
        return nil
    }

    private static func epochDate(_ seconds: Double) -> Date? {
        guard seconds > 0 else { return nil }
        if seconds > 1e14 { return Date(timeIntervalSince1970: seconds / 1_000_000) }   // microseconds
        if seconds > 1e11 { return Date(timeIntervalSince1970: seconds / 1_000) }       // milliseconds
        return Date(timeIntervalSince1970: seconds)
    }
}
