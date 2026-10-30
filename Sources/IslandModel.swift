import AppKit
import SwiftUI

// MARK: - Data types

enum PlayerSource: String, CaseIterable {
    case spotify
    case music
    /// Any other app, read through the system Now Playing (YouTube in a browser, Podcasts, VLC…).
    case system

    var bundleID: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .music: return "com.apple.Music"
        case .system: return ""
        }
    }

    var displayName: String {
        switch self {
        case .spotify: return "Spotify"
        case .music: return "Apple Music"
        case .system: return "Pemutar media"
        }
    }
}

struct TrackInfo: Equatable {
    var source: PlayerSource
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: Double   // seconds
    var position: Double   // seconds, sampled at IslandModel.sampledAt
    var isPlaying: Bool
    var artworkURL: String
    /// The app that plays it (browser, Podcasts…), when known.
    var appBundleID: String? = nil
    var appName: String? = nil

    var playerName: String { appName ?? source.displayName }
}

struct BatteryState: Equatable {
    var percent: Int
    var isCharging: Bool
    var isPluggedIn: Bool
}

enum NoticeTint: Equatable {
    case green, yellow, red, white, blue

    var color: Color {
        switch self {
        case .green: return Color(red: 0.30, green: 0.85, blue: 0.39)
        case .yellow: return Color(red: 1.00, green: 0.80, blue: 0.00)
        case .red: return Color(red: 1.00, green: 0.27, blue: 0.23)
        case .white: return .white
        case .blue: return Color(red: 0.35, green: 0.68, blue: 1.00)
        }
    }
}

struct IslandNotice: Equatable {
    let id = UUID()
    var symbol: String
    var title: String
    var detail: String
    var tint: NoticeTint
    /// Optional 0…1 level drawn as a small bar (volume).
    var level: Double? = nil
}

// MARK: - Tabs, focus timer

enum IslandTab: String, CaseIterable, Hashable {
    case music, agenda, prayer, focus, shelf, clipboard

    var title: String {
        switch self {
        case .music: return "Musik"
        case .agenda: return "Agenda"
        case .prayer: return "Sholat"
        case .focus: return "Fokus"
        case .shelf: return "Shelf"
        case .clipboard: return "Clipboard"
        }
    }

    var symbol: String {
        switch self {
        case .music: return "music.note"
        case .agenda: return "calendar"
        case .prayer: return "moon.stars"
        case .focus: return "timer"
        case .shelf: return "tray.and.arrow.down"
        case .clipboard: return "doc.on.clipboard"
        }
    }
}

struct FocusSession: Equatable {
    enum Phase: Equatable { case focus, rest }

    var phase: Phase
    var total: TimeInterval
    /// When the phase ends; nil while paused.
    var endDate: Date?
    var pausedRemaining: TimeInterval

    var isRunning: Bool { endDate != nil }

    func remaining(at now: Date) -> TimeInterval {
        guard let endDate = endDate else { return pausedRemaining }
        return max(0, endDate.timeIntervalSince(now))
    }

    func progress(at now: Date) -> Double {
        total > 0 ? min(1, max(0, 1 - remaining(at: now) / total)) : 0
    }

    var tint: Color {
        phase == .focus ? Color(red: 1.0, green: 0.62, blue: 0.22) : NoticeTint.green.color
    }
}

// MARK: - Layout (with or without a camera notch)

/// Geometry of the island on the current screen.
///
/// Notched MacBook (14"/16" M1 Pro/Max and later), default look: the island wraps the
/// camera. It is flush with the top edge, as tall as the notch, with small "ears" left
/// and right of the lens; it opens downward from the notch. Nothing is drawn under the lens.
/// Screens without a notch, or the optional pill look: a floating black pill.
struct IslandLayout: Equatable {
    /// Camera notch the island wraps, or nil for a floating pill.
    var notch: CGSize?
    /// Distance from the top of the screen to the floating pill.
    var pillTop: CGFloat = 1
    /// Camera notch the floating pill sits *under* (pill look). Hovering the camera opens the island.
    var camera: CGSize? = nil
    /// Menu bar height on screens without a notch (MacBooks from 2020 and earlier, external displays).
    var menuBarHeight: CGFloat = 24

    static let plain = IslandLayout(notch: nil)

    /// Width of each ear beside the camera (clock / battery / artwork / equalizer).
    static let wing: CGFloat = 60
    /// Wider ears for notices, so "Mengisi daya" fits left of the camera.
    static let noticeWing: CGFloat = 132
    /// Small outward curve where the island meets the top bezel, like the real notch.
    static let shoulderSize: CGFloat = 6

    var hasNotch: Bool { notch != nil }
    /// No camera notch at all: the compact pill sits inside the menu bar, like a menu bar item.
    var isMenuBarPill: Bool { notch == nil && camera == nil }
    var notchWidth: CGFloat { notch?.width ?? 0 }
    var notchHeight: CGFloat { notch?.height ?? 0 }
    var shoulder: CGFloat { hasNotch ? IslandLayout.shoulderSize : 0 }

    /// Gap between the top of the screen and the island.
    var topInset: CGFloat { hasNotch ? 0 : pillTop }

    /// Width of the open island on a notched screen.
    private var openWidth: CGFloat { max(420, notchWidth + 180) }

    /// Open island below the camera: tab bar + content.
    static let openBodyHeight: CGFloat = 190

    func size(for mode: IslandMode) -> CGSize {
        guard let notch = notch else { return isMenuBarPill ? menuBarSize(for: mode) : mode.plainSize }
        let w = notch.width
        let h = notch.height
        let s = 2 * IslandLayout.shoulderSize
        switch mode {
        case .hidden: return CGSize(width: w + s, height: h)
        case .idle, .music: return CGSize(width: w + 2 * IslandLayout.wing + s, height: h)
        case .peek: return CGSize(width: w + 2 * IslandLayout.wing + s, height: h + 26)
        case .focus: return CGSize(width: w + 2 * IslandLayout.wing + s, height: h)
        case .notice, .prayer, .meeting: return CGSize(width: w + 2 * IslandLayout.noticeWing + s, height: h)
        case .expanded: return CGSize(width: openWidth + s, height: h + IslandLayout.openBodyHeight)
        }
    }

    /// Compact states stay within the menu bar (1 pt from the top, 2 pt shorter than the bar),
    /// so they never hang over browser tabs or window title bars.
    private func menuBarSize(for mode: IslandMode) -> CGSize {
        let h = max(18, menuBarHeight - 2)
        switch mode {
        case .hidden: return CGSize(width: 90, height: h - 4)
        case .idle: return CGSize(width: 150, height: h)
        case .music, .focus: return CGSize(width: 236, height: h)
        case .peek: return CGSize(width: 320, height: h)
        case .notice, .prayer, .meeting: return CGSize(width: 300, height: h)
        case .expanded: return mode.plainSize
        }
    }

    /// Area that reacts to the mouse while the island is collapsed.
    func hoverSize(for mode: IslandMode) -> CGSize {
        mode == .hidden ? size(for: .idle) : size(for: mode)
    }

    func topRadius(for mode: IslandMode) -> CGFloat {
        hasNotch ? 0 : bottomRadius(for: mode)   // flush with the screen edge under a notch
    }

    func bottomRadius(for mode: IslandMode) -> CGFloat {
        switch mode {
        case .expanded: return hasNotch ? 26 : 30
        case .hidden: return hasNotch ? 9 : size(for: mode).height / 2
        case .idle, .music, .focus: return hasNotch ? 12 : size(for: mode).height / 2
        case .peek: return hasNotch ? 18 : size(for: mode).height / 2
        case .notice, .prayer, .meeting: return hasNotch ? 14 : size(for: mode).height / 2
        }
    }

    /// The transparent panel the island lives in: the largest state plus room for its shadow.
    var panelSize: CGSize {
        guard let notch = notch else {
            let expandedHeight = IslandMode.expanded.plainSize.height
            return CGSize(width: 440, height: max(184, pillTop + expandedHeight + 28))
        }
        let expanded = size(for: .expanded)
        let width = max(440, notch.width + 2 * IslandLayout.noticeWing + 40, expanded.width + 56)
        let height = max(184, expanded.height + 28)
        return CGSize(width: width, height: height)
    }
}

// MARK: - Island states

enum IslandMode: Equatable {
    case hidden
    case idle
    case music
    case peek
    case focus
    case prayer(PrayerAlert)
    case meeting(MeetingAlert)
    case notice(IslandNotice)
    case expanded

    /// Sizes for screens WITHOUT a camera notch (floating pill).
    var plainSize: CGSize {
        switch self {
        case .hidden: return CGSize(width: 90, height: 18)
        case .idle: return CGSize(width: 124, height: 22)
        case .music: return CGSize(width: 236, height: 26)
        case .peek: return CGSize(width: 300, height: 30)
        case .focus: return CGSize(width: 236, height: 26)
        case .notice, .prayer, .meeting: return CGSize(width: 286, height: 30)
        case .expanded: return CGSize(width: 420, height: 206)
        }
    }

    var isExpanded: Bool {
        switch self {
        case .expanded: return true
        default: return false
        }
    }

    var contentKey: String {
        switch self {
        case .hidden: return "hidden"
        case .idle: return "idle"
        case .music: return "music"
        case .peek: return "peek"
        case .focus: return "focus"
        case .prayer(let alert): return "prayer-\(alert.key)-\(alert.isNow)"
        case .meeting(let alert): return "meeting-\(alert.key)-\(alert.isNow)"
        case .notice(let notice): return "notice-\(notice.id.uuidString)"
        case .expanded: return "expanded"
        }
    }
}

// MARK: - Shared state

@MainActor
final class IslandModel: ObservableObject {
    @Published var track: TrackInfo?
    @Published var sampledAt = Date()
    @Published var artwork: NSImage?
    @Published var accent: Color = .white
    @Published var notice: IslandNotice?
    @Published var isPeeking = false
    @Published var isHovered = false
    @Published var battery: BatteryState?
    @Published var automationDenied = false
    @Published var layout = IslandLayout.plain
    /// The active app has a window right under the floating pill (full screen, maximized…).
    @Published var windowUnderPill = false
    /// Notched Macs: false = wrap the camera (default), true = floating pill below the camera.
    @Published var pillBelowCamera: Bool = UserDefaults.standard.bool(forKey: "pillBelowCamera") {
        didSet { UserDefaults.standard.set(pillBelowCamera, forKey: "pillBelowCamera") }
    }
    @Published var hideWhenIdle: Bool = UserDefaults.standard.bool(forKey: "hideWhenIdle") {
        didSet { UserDefaults.standard.set(hideWhenIdle, forKey: "hideWhenIdle") }
    }

    // Open island
    @Published var openTab: IslandTab = .music

    // Prayer times
    @Published var prayerEnabled: Bool = (UserDefaults.standard.object(forKey: "prayerEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(prayerEnabled, forKey: "prayerEnabled") }
    }
    @Published var prayerCityName: String = UserDefaults.standard.string(forKey: "prayerCity") ?? "Jakarta" {
        didSet { UserDefaults.standard.set(prayerCityName, forKey: "prayerCity") }
    }
    @Published var prayerTimes: [PrayerTime] = []
    @Published var nextPrayer: PrayerTime?
    @Published var prayerAlert: PrayerAlert?
    var dismissedPrayerKey: String?

    // Focus timer
    @Published var focus: FocusSession?
    @Published var focusMinutes: Int = {
        let saved = UserDefaults.standard.integer(forKey: "focusMinutes")
        return saved > 0 ? saved : 25
    }() {
        didSet { UserDefaults.standard.set(focusMinutes, forKey: "focusMinutes") }
    }

    // Next meeting (Calendar)
    @Published var meetingEnabled: Bool = (UserDefaults.standard.object(forKey: "meetingEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(meetingEnabled, forKey: "meetingEnabled") }
    }
    @Published var calendarAccess: CalendarAccess = .notDetermined
    /// Rest of today and tomorrow, sorted by start time.
    @Published var agenda: [MeetingInfo] = []
    @Published var meetingAlert: MeetingAlert?
    var dismissedMeetingKey: String?
    weak var calendar: CalendarMonitor?

    // Clipboard history (memory only)
    @Published var clipboardEnabled: Bool = (UserDefaults.standard.object(forKey: "clipboardEnabled") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(clipboardEnabled, forKey: "clipboardEnabled")
            if !clipboardEnabled { clips.removeAll() }
        }
    }
    @Published var clips: [ClipItem] = []
    @Published var copiedClipID: UUID?
    /// Change count of our own "copy again", so it isn't recorded twice.
    var ignoredPasteboardChange = -1
    static let clipLimit = 20

    // New downloads / screenshots go to the shelf
    @Published var autoShelfEnabled: Bool = (UserDefaults.standard.object(forKey: "autoShelfEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoShelfEnabled, forKey: "autoShelfEnabled") }
    }

    // First launch / feature switches
    @Published var onboarded: Bool = UserDefaults.standard.bool(forKey: "onboarded") {
        didSet { UserDefaults.standard.set(onboarded, forKey: "onboarded") }
    }
    /// nil until Downloads / Desktop have been read once.
    @Published var folderAccess: Bool?
    @Published var bluetoothEnabled: Bool = (UserDefaults.standard.object(forKey: "bluetoothEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(bluetoothEnabled, forKey: "bluetoothEnabled") }
    }
    @Published var gesturesEnabled: Bool = (UserDefaults.standard.object(forKey: "gesturesEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(gesturesEnabled, forKey: "gesturesEnabled") }
    }
    /// Volume level shown briefly in the open island after a scroll gesture.
    @Published var volumeFlash: Double?
    private var volumeFlashTask: Task<Void, Never>?

    // Volume pop-up: the island's, macOS's, or both
    @Published var volumeHUDMode: VolumeHUDMode = VolumeHUDMode(rawValue: UserDefaults.standard.string(forKey: "volumeHUDMode") ?? "") ?? .island {
        didSet { UserDefaults.standard.set(volumeHUDMode.rawValue, forKey: "volumeHUDMode") }
    }
    /// The volume keys are being handled by DynaIsland (Accessibility permission granted).
    var mediaKeysActive = false

    // Updating from a newer DynaIsland zip
    @Published var availableUpdate: URL?
    @Published var isUpdating = false
    /// Newest build number on GitHub, once checked.
    @Published var latestBuild: Int?
    weak var updater: Updater?

    // Shelf
    @Published var shelf: [URL] = []
    @Published var isDropTargeted = false {
        didSet { if isDropTargeted { openTab = .shelf } }
    }

    // Mascot
    @Published var mascot: MascotKind = MascotKind(rawValue: UserDefaults.standard.string(forKey: "mascot") ?? "") ?? .moci {
        didSet { UserDefaults.standard.set(mascot.rawValue, forKey: "mascot") }
    }
    /// Short-lived mood (greeting, file saved, focus done…) on top of the resting mood.
    @Published var mascotReaction: MascotReaction?
    /// No keyboard / mouse / trackpad input for a while.
    @Published var isAsleep = false

    weak var player: NowPlayingMonitor?

    private var noticeTask: Task<Void, Never>?
    private var peekTask: Task<Void, Never>?
    private var mascotDemoTask: Task<Void, Never>?
    private var copiedTask: Task<Void, Never>?

    var mode: IslandMode {
        if isHovered { return .expanded }
        if let notice = notice { return .notice(notice) }
        // A floating pill steps aside when it would cover the active window (e.g. browser tabs).
        // Wrapped around the camera, the island lives in the menu-bar strip and never needs to.
        let pillBlocked = windowUnderPill && !layout.hasNotch
        if !pillBlocked {
            if let meeting = meetingAlert { return .meeting(meeting) }
            if let alert = prayerAlert { return .prayer(alert) }
            if focus != nil { return .focus }
            if track?.isPlaying == true { return isPeeking ? .peek : .music }
        }
        // Below a camera an idle pill would sit over app windows, so it stays hidden;
        // hovering the camera still opens the island.
        let hideIdle = hideWhenIdle || layout.camera != nil || pillBlocked
        return hideIdle ? .hidden : .idle
    }

    /// Briefly show a notification (charger, battery…) in the island.
    func show(_ notice: IslandNotice, seconds: Double = 2.6) {
        self.notice = notice
        scheduleNoticeEnd(after: seconds)
    }

    /// Volume pop-up. Repeated key presses update the same pop-up instead of re-animating it.
    func showVolume(level: Double, muted: Bool) {
        switch volumeHUDMode {
        case .system:
            return
        case .both:
            break
        case .island:
            // Until DynaIsland may handle the volume keys, macOS shows its own HUD: don't add a second one.
            guard mediaKeysActive else {
                askForMediaKeysOnce()
                return
            }
        }
        let percent = Int((level * 100).rounded())
        let symbol: String
        if muted || level <= 0.001 {
            symbol = "speaker.slash.fill"
        } else if level < 0.34 {
            symbol = "speaker.wave.1.fill"
        } else if level < 0.67 {
            symbol = "speaker.wave.2.fill"
        } else {
            symbol = "speaker.wave.3.fill"
        }
        let detail = muted ? "Bisu" : "\(percent)%"

        if var current = notice, current.title == "Volume" {
            current.symbol = symbol
            current.detail = detail
            current.level = muted ? 0 : level
            notice = current          // same id → updates in place
        } else {
            notice = IslandNotice(symbol: symbol, title: "Volume", detail: detail, tint: .white,
                                  level: muted ? 0 : level)
        }
        scheduleNoticeEnd(after: 1.8)
    }

    func flashVolume(_ level: Double) {
        volumeFlash = level
        volumeFlashTask?.cancel()
        volumeFlashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.volumeFlash = nil
        }
    }

    /// Once per build: explain and show macOS's Accessibility dialog.
    private func askForMediaKeysOnce() {
        guard onboarded else { return }   // the welcome screen asks first
        let defaults = UserDefaults.standard
        let build = Updater.currentBuild
        guard defaults.integer(forKey: "askedAccessibilityBuild") != build else { return }
        defaults.set(build, forKey: "askedAccessibilityBuild")
        show(IslandNotice(symbol: "hand.raised.fill", title: "Izinkan Aksesibilitas",
                          detail: "1 pop-up", tint: .yellow), seconds: 5)
        MediaKeys.askForPermission()
    }

    private func scheduleNoticeEnd(after seconds: Double) {
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// Picks the tab to show when the island opens.
    func prepareToOpen(forDrop: Bool) {
        if forDrop {
            openTab = .shelf
        } else if meetingAlert != nil {
            openTab = .agenda
        } else if prayerAlert != nil {
            openTab = .prayer
        } else if focus?.isRunning == true {
            openTab = .focus
        } else if track?.isPlaying == true {
            openTab = .music
        }
        // Otherwise keep the tab used last time.
    }

    // MARK: Prayer

    func dismissPrayer() {
        dismissedPrayerKey = prayerAlert?.key
        prayerAlert = nil
    }

    // MARK: Focus timer

    func startFocus() {
        let total = TimeInterval(focusMinutes * 60)
        focus = FocusSession(phase: .focus, total: total, endDate: Date().addingTimeInterval(total), pausedRemaining: total)
    }

    func pauseFocus() {
        guard var session = focus, let end = session.endDate else { return }
        session.pausedRemaining = max(0, end.timeIntervalSinceNow)
        session.endDate = nil
        focus = session
    }

    func resumeFocus() {
        guard var session = focus, session.endDate == nil else { return }
        session.endDate = Date().addingTimeInterval(session.pausedRemaining)
        focus = session
    }

    func stopFocus() {
        focus = nil
    }

    /// Called once a second: ends a focus block (→ 5-minute break) or a break.
    func tickFocus(now: Date = Date()) {
        guard let session = focus, let end = session.endDate, now >= end else { return }
        NSSound(named: "Glass")?.play()
        switch session.phase {
        case .focus:
            let rest: TimeInterval = 5 * 60
            focus = FocusSession(phase: .rest, total: rest, endDate: now.addingTimeInterval(rest), pausedRemaining: rest)
            show(IslandNotice(symbol: "cup.and.saucer.fill", title: "Waktunya istirahat", detail: "5 mnt", tint: .green), seconds: 4)
        case .rest:
            focus = nil
            show(IslandNotice(symbol: "checkmark.circle.fill", title: "Istirahat selesai", detail: "", tint: .green), seconds: 4)
        }
        react(.happy, seconds: 8)   // still celebrating once the notice is gone
    }

    // MARK: Mascot

    /// The mood when nothing special just happened.
    var mascotBaseMood: MascotMood {
        if isDropTargeted { return .eating }
        if track?.isPlaying == true { return .music }
        if isAsleep { return .sleep }
        if let battery = battery {
            if !battery.isPluggedIn && battery.percent <= 20 { return .tired }
            if battery.isCharging { return .charging }
        }
        return .idle
    }

    func react(_ mood: MascotMood, seconds: Double = 1.6) {
        mascotReaction = MascotReaction(mood: mood, until: Date().addingTimeInterval(seconds))
    }

    func setAsleep(_ asleep: Bool) {
        guard asleep != isAsleep else { return }
        isAsleep = asleep
        let reacting = mascotReaction.map { $0.until > Date() } ?? false
        if !asleep && !reacting { react(.surprised, seconds: 1.4) }
    }

    /// Plays every mood once (menu → Maskot → Lihat semua gerakan).
    func demoMascot() {
        mascotDemoTask?.cancel()
        let steps: [(MascotMood, Double)] = [
            (.happy, 2.2), (.music, 3), (.eating, 2.4), (.charging, 2.2),
            (.tired, 2.4), (.sleep, 3.5), (.surprised, 1.5),
        ]
        mascotDemoTask = Task { [weak self] in
            for (mood, seconds) in steps {
                guard !Task.isCancelled else { return }
                self?.react(mood, seconds: seconds)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    // MARK: Meetings

    func dismissMeeting() {
        dismissedMeetingKey = meetingAlert?.key
        meetingAlert = nil
    }

    func join(_ url: URL) {
        NSWorkspace.shared.open(url)
        dismissMeeting()
    }

    // MARK: Clipboard

    func recordClip(_ content: ClipItem.Content) {
        if case .text(let text) = content,
           let index = clips.firstIndex(where: { item in
               if case .text(let existing) = item.content { return existing == text }
               return false
           }) {
            var item = clips.remove(at: index)   // copied again: move it to the top
            item.date = Date()
            clips.insert(item, at: 0)
            return
        }
        clips.insert(ClipItem(content: content, date: Date()), at: 0)
        if clips.count > IslandModel.clipLimit { clips.removeLast(clips.count - IslandModel.clipLimit) }
    }

    func copyClip(_ item: ClipItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.content {
        case .text(let text): pasteboard.setString(text, forType: .string)
        case .image(let image): pasteboard.writeObjects([image])
        }
        ignoredPasteboardChange = pasteboard.changeCount
        if let index = clips.firstIndex(where: { $0.id == item.id }) {
            var moved = clips.remove(at: index)
            moved.date = Date()
            clips.insert(moved, at: 0)
        }
        copiedClipID = item.id
        copiedTask?.cancel()
        copiedTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.copiedClipID = nil
        }
    }

    func removeClip(_ id: UUID) {
        clips.removeAll { $0.id == id }
    }

    func clearClips() {
        clips.removeAll()
    }

    // MARK: Update

    /// Builds and installs the given zip, or the one found on the shelf / in Downloads.
    func installUpdate(from zip: URL? = nil) {
        guard !isUpdating, let source = zip ?? availableUpdate ?? Updater.newestZip() else { return }
        updater?.install(from: source)
    }

    // MARK: Shelf

    func addToShelf(_ urls: [URL]) {
        var added = false
        for url in urls where !shelf.contains(url) {
            shelf.append(url)
            added = true
        }
        if shelf.count > 30 { shelf.removeFirst(shelf.count - 30) }   // oldest out
        if let zip = urls.last(where: { Updater.isUpdateZip($0) }) { availableUpdate = zip }
        if added { react(.happy) }   // nom
    }

    func removeFromShelf(_ url: URL) {
        shelf.removeAll { $0 == url }
    }

    func clearShelf() {
        shelf.removeAll()
    }

    func openFile(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        // The AirDrop window belongs to this app, so bring it to the front first.
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    /// Briefly show the song title (on track change / resume).
    func peek(seconds: Double = 3) {
        isPeeking = true
        peekTask?.cancel()
        peekTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.isPeeking = false
        }
    }
}
