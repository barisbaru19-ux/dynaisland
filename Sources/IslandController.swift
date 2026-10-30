import AppKit
import SwiftUI

/// Borderless, transparent, non-activating panel that floats above the menu bar.
final class IslandPanel: NSPanel {
    convenience init(size: CGSize) {
        self.init(contentRect: NSRect(origin: .zero, size: size),
                  styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered,
                  defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class IslandController: NSObject {
    let model: IslandModel
    private let panel: IslandPanel
    private let nowPlaying: NowPlayingMonitor
    private let battery: BatteryMonitor
    private let prayer: PrayerMonitor
    private let clipboard: ClipboardMonitor
    private let calendar: CalendarMonitor
    private let folders: FolderWatcher
    private var hoverTimer: Timer?
    private var windowTimer: Timer?
    private var secondTimer: Timer?
    private var enterSince: Date?
    private var exitSince: Date?
    /// Drag pasteboard change count while no mouse button is down. A new value while the
    /// button is held means a file (or other) drag session is in progress.
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var idleDragCount = 0

    init(model: IslandModel) {
        self.model = model
        self.panel = IslandPanel(size: IslandLayout.plain.panelSize)
        self.nowPlaying = NowPlayingMonitor(model: model)
        self.battery = BatteryMonitor(model: model)
        self.prayer = PrayerMonitor(model: model)
        self.clipboard = ClipboardMonitor(model: model)
        self.calendar = CalendarMonitor(model: model)
        self.folders = FolderWatcher(model: model)
        super.init()
    }

    func start() {
        let host = FirstMouseHostingView(rootView: IslandRootView(model: model))
        host.frame = NSRect(origin: .zero, size: IslandLayout.plain.panelSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        relayout()
        panel.orderFrontRegardless()
        SpaceFix.shared.keepVisibleWhileSwitchingDesktops(panel)

        nowPlaying.start()
        battery.start()
        model.calendar = calendar
        calendar.start()
        idleDragCount = dragPasteboard.changeCount

        // Once a second: prayer countdown and the focus timer.
        let secondTimer = Timer(timeInterval: 1.0, target: self, selector: #selector(secondTick), userInfo: nil, repeats: true)
        secondTimer.tolerance = 0.1
        RunLoop.main.add(secondTimer, forMode: .common)
        self.secondTimer = secondTimer
        secondTick()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)

        // Mouse polling instead of tracking areas: the panel stays click-through
        // until the pointer is actually over the island.
        let timer = Timer(timeInterval: 1.0 / 20.0, target: self, selector: #selector(hoverTick), userInfo: nil, repeats: true)
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer

        // Is the active app's window under the pill? Checked on app/space switches and twice a second.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(checkWindowUnderPill),
                              name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(checkWindowUnderPill),
                              name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        let windowTimer = Timer(timeInterval: 0.5, target: self, selector: #selector(checkWindowUnderPill), userInfo: nil, repeats: true)
        windowTimer.tolerance = 0.1
        RunLoop.main.add(windowTimer, forMode: .common)
        self.windowTimer = windowTimer
        checkWindowUnderPill()
    }

    /// Also called from the menu after changing the prayer city.
    @objc func secondTick() {
        prayer.tick()
        model.tickFocus()
        clipboard.tick()
        calendar.tick()
        folders.tick()
        model.setAsleep(Self.secondsSinceLastInput() > 120)   // mascot naps after 2 minutes
    }

    /// Seconds since the last key press, click, scroll or mouse move anywhere on the Mac.
    private static func secondsSinceLastInput() -> Double {
        guard let anyInput = CGEventType(rawValue: UInt32.max) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    // MARK: - Getting out of the way

    @objc private func checkWindowUnderPill() {
        let blocked = frontWindowUnderPill()
        if model.windowUnderPill != blocked { model.windowUnderPill = blocked }
    }

    /// True when a normal window of the frontmost app overlaps the spot where the floating
    /// pill would be, e.g. Chrome in full screen or maximized: the pill would cover its tabs.
    private func frontWindowUnderPill() -> Bool {
        guard !model.layout.hasNotch,
              let screen = NSScreen.screens.first,
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }

        // A few points of tolerance so a window that merely touches the pill's edge doesn't count.
        let pill = islandRect(size: model.layout.size(for: .music), in: panel.frame).insetBy(dx: 0, dy: 4)
        // Window list bounds use a top-left origin.
        let target = CGRect(x: pill.minX, y: screen.frame.maxY - pill.maxY, width: pill.width, height: pill.height)

        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        let pid = front.processIdentifier
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            if bounds.intersects(target) { return true }
        }
        return false
    }

    // MARK: - Placement

    /// Recomputes the layout (notch, style) and moves the panel. Also called from the menu.
    func relayout() {
        // The first screen is the one that has the menu bar.
        guard let screen = NSScreen.screens.first else { return }
        let layout = self.layout(for: screen)
        if model.layout != layout { model.layout = layout }
        let size = layout.panelSize
        let frame = screen.frame
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func layout(for screen: NSScreen) -> IslandLayout {
        guard let notch = Self.notchSize(of: screen) else {
            // MacBooks from 2020 and earlier, external displays: a pill inside the menu bar.
            var plain = IslandLayout.plain
            let bar = screen.frame.maxY - screen.visibleFrame.maxY
            plain.menuBarHeight = bar > 10 ? bar : 24   // 0 when the menu bar auto-hides
            return plain
        }
        if model.pillBelowCamera {
            return IslandLayout(notch: nil, pillTop: notch.height + 5, camera: notch)  // pill below the camera
        }
        return IslandLayout(notch: notch)                                              // wrap the camera
    }

    /// Size of the camera notch, or nil for screens without one
    /// (MacBook Air M1, 13" Pro M1, external displays).
    private static func notchSize(of screen: NSScreen) -> CGSize? {
        let top = screen.safeAreaInsets.top
        guard top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        let width = screen.frame.width - left.width - right.width
        guard width > 0 else { return nil }
        return CGSize(width: width, height: top)
    }

    @objc private func screensChanged() {
        relayout()
        panel.orderFrontRegardless()
        SpaceFix.shared.keepVisibleWhileSwitchingDesktops(panel)
    }

    // MARK: - Hover

    @objc private func hoverTick() {
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        let now = Date()

        if model.isHovered {
            let zone = islandRect(size: model.layout.size(for: model.mode), in: frame).insetBy(dx: -14, dy: -14)
            if zone.contains(mouse) || cameraRect(in: frame)?.contains(mouse) == true {
                exitSince = nil
            } else if let since = exitSince {
                if now.timeIntervalSince(since) > 0.2 { setHovered(false) }
            } else {
                exitSince = now
            }
        } else {
            var zone = islandRect(size: model.layout.hoverSize(for: model.mode), in: frame).insetBy(dx: -6, dy: -4)
            zone.size.height += 8   // reach all the way to the top edge of the screen
            let pressed = NSEvent.pressedMouseButtons != 0
            if !pressed { idleDragCount = dragPasteboard.changeCount }
            let dragSession = pressed && dragPasteboard.changeCount != idleDragCount
            let overCamera = cameraRect(in: frame)?.contains(mouse) == true
            // A hidden pill below the camera must not react: that spot is over app windows.
            let pillInvisible = model.mode == .hidden && model.layout.camera != nil
            let overPill = !pillInvisible && zone.contains(mouse)

            if (overPill || overCamera) && dragSession {
                // Dragging a file onto the notch: open straight away on the shelf.
                setHovered(true, forDrop: true)
                return
            }
            if (overPill || overCamera) && !pressed {
                if let since = enterSince {
                    if now.timeIntervalSince(since) > 0.12 { setHovered(true) }
                } else {
                    enterSince = now
                }
            } else {
                enterSince = nil
            }
        }
    }

    private func islandRect(size: CGSize, in frame: NSRect) -> NSRect {
        NSRect(x: frame.midX - size.width / 2,
               y: frame.maxY - model.layout.topInset - size.height,
               width: size.width,
               height: size.height)
    }

    /// The camera notch (plus a little margin) when the pill floats below it.
    private func cameraRect(in frame: NSRect) -> NSRect? {
        guard let camera = model.layout.camera else { return nil }
        return NSRect(x: frame.midX - camera.width / 2 - 6,
                      y: frame.maxY - camera.height - 6,
                      width: camera.width + 12,
                      height: camera.height + 14)
    }

    private func setHovered(_ hovered: Bool, forDrop: Bool = false) {
        enterSince = nil
        exitSince = nil
        if hovered { model.prepareToOpen(forDrop: forDrop) }
        model.isHovered = hovered
        panel.ignoresMouseEvents = !hovered
        if hovered {
            // A light tap on the trackpad as the island opens.
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            if !forDrop { model.react(.happy, seconds: 1.3) }   // the mascot says hi
        }
    }
}
