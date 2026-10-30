import AppKit
import ServiceManagement
import SwiftUI

@main
@MainActor
enum DynaIslandApp {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // no Dock icon, never steals focus
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: IslandModel?
    private var controller: IslandController?
    private var volume: VolumeMonitor?
    private var updater: Updater?
    private var bluetooth: BluetoothMonitor?
    private var systemNowPlaying: SystemNowPlaying?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = IslandModel()
        let controller = IslandController(model: model)
        controller.start()
        self.model = model
        self.controller = controller
        let volume = VolumeMonitor(model: model)
        volume.start()
        self.volume = volume
        let updater = Updater(model: model)
        model.updater = updater
        self.updater = updater
        updater.launched()
        updater.startChecking()
        bluetooth = BluetoothMonitor(model: model)
        // Music from every app (YouTube in a browser, Podcasts…), when the bundled adapter works here.
        let system = SystemNowPlaying(model: model)
        model.player?.system = system
        system.start()
        systemNowPlaying = system
        buildStatusItem()

        if model.onboarded {
            startPermissionedFeatures()
        } else {
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        systemNowPlaying?.stop()
    }

    /// Reopening the app from Finder / Spotlight shows Settings (there's no Dock icon to click).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    // MARK: - Features that ask for permission (only after the welcome screen)

    private func startPermissionedFeatures() {
        model?.calendar?.settingsChanged()
        bluetoothSettingChanged()
    }

    func bluetoothSettingChanged() {
        guard let model = model, let bluetooth = bluetooth else { return }
        if model.bluetoothEnabled && model.onboarded {
            bluetooth.start()
        } else {
            bluetooth.stop()
        }
    }

    func requestBluetooth() {
        model?.bluetoothEnabled = true
        bluetooth?.start()   // the first start shows macOS's Bluetooth prompt
    }

    func requestFolderAccess() {
        guard let model = model else { return }
        Task.detached(priority: .userInitiated) {
            let readable = FolderWatcher.probeAccess()   // shows macOS's Downloads / Desktop prompts
            await MainActor.run { model.folderAccess = readable }
        }
    }

    func relayout() {
        controller?.relayout()
    }

    // MARK: - Windows

    func showSettings() {
        guard let model = model else { return }
        if settingsWindow == nil {
            settingsWindow = AppDelegate.makeWindow(title: "Pengaturan DynaIsland",
                                                    content: SettingsView(model: model),
                                                    size: NSSize(width: 600, height: 500))
        }
        bringToFront(settingsWindow)
    }

    func showOnboarding() {
        guard let model = model else { return }
        if onboardingWindow == nil {
            let view = OnboardingView(model: model) { [weak self] in self?.finishOnboarding() }
            onboardingWindow = AppDelegate.makeWindow(title: "Selamat datang di DynaIsland", content: view,
                                                      size: NSSize(width: 600, height: 520))
        }
        bringToFront(onboardingWindow)
    }

    private func finishOnboarding() {
        guard let model = model else { return }
        let firstTime = !model.onboarded
        model.onboarded = true
        onboardingWindow?.close()
        onboardingWindow = nil
        if firstTime { startPermissionedFeatures() }
        model.react(.happy, seconds: 3)
    }

    private func bringToFront(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private static func makeWindow<Content: View>(title: String, content: Content, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.center()
        return window
    }

    // MARK: - Menu bar icon

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = AppDelegate.menuBarIcon()
            button.toolTip = "DynaIsland"
        }

        let menu = NSMenu()
        let header = NSMenuItem(title: "DynaIsland", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Pengaturan…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let update = NSMenuItem(title: "Perbarui DynaIsland…", action: #selector(installUpdate), keyEquivalent: "")
        update.target = self
        menu.addItem(update)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Keluar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    @objc private func openSettings() {
        showSettings()
    }

    /// The logo as a menu bar icon: an island with Moci on the left and an equalizer on the right,
    /// cut out of the shape. A template image, so it follows light / dark menu bars.
    private static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 14), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 3.25, width: 18, height: 7.5), xRadius: 3.75, yRadius: 3.75).fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: NSRect(x: 3.2, y: 4.9, width: 4.2, height: 4.2)).fill()
            let heights: [CGFloat] = [2.4, 4.0, 3.0]
            for (index, height) in heights.enumerated() {
                let x = 11.6 + CGFloat(index) * 1.9
                NSBezierPath(roundedRect: NSRect(x: x, y: 7 - height / 2, width: 1.1, height: height),
                             xRadius: 0.55, yRadius: 0.55).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "DynaIsland"
        return image
    }

    // MARK: - Actions (menu and Settings)

    /// Downloads the newest build from GitHub (or, offline, installs a DynaIsland zip from Downloads).
    @objc func installUpdate() {
        guard let model = model, !model.isUpdating else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        if let latest = model.latestBuild {
            alert.messageText = latest > Updater.currentBuild
                ? "Versi baru tersedia: 1.\(latest)"
                : "Kamu sudah memakai versi terbaru"
        } else {
            alert.messageText = "Perbarui DynaIsland?"
        }
        alert.informativeText = "Versi kamu: \(current). DynaIsland akan mengunduh versi terbaru dari GitHub, menutup diri, lalu terbuka lagi. Tidak perlu Terminal."
        alert.addButton(withTitle: "Perbarui")
        let zip = model.availableUpdate ?? Updater.newestZip()
        if zip != nil { alert.addButton(withTitle: "Pakai zip di Downloads") }
        alert.addButton(withTitle: "Batal")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.updater?.installOnline()
        case .alertSecondButtonReturn:
            if let zip = zip { model.installUpdate(from: zip) }
        default:
            break
        }
    }

    func runDemo() {
        guard let model = model else { return }
        let percent = model.battery?.percent ?? 80
        model.show(IslandNotice(symbol: "bolt.fill", title: "Mengisi daya", detail: "\(percent)%", tint: .green))
    }
}
