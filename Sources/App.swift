import AppKit
import ServiceManagement

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
    private var statusItem: NSStatusItem?

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
        buildStatusItem()
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

        let hide = NSMenuItem(title: "Sembunyikan saat idle", action: #selector(toggleHideWhenIdle(_:)), keyEquivalent: "")
        hide.target = self
        hide.state = (model?.hideWhenIdle ?? false) ? .on : .off
        menu.addItem(hide)

        let pill = NSMenuItem(title: "Gaya pil (di bawah kamera)", action: #selector(togglePillBelowCamera(_:)), keyEquivalent: "")
        pill.target = self
        pill.state = (model?.pillBelowCamera ?? false) ? .on : .off
        menu.addItem(pill)

        let mascotItem = NSMenuItem(title: "Maskot", action: nil, keyEquivalent: "")
        let mascotMenu = NSMenu()
        for kind in MascotKind.allCases {
            if kind == .off { mascotMenu.addItem(.separator()) }
            let item = NSMenuItem(title: kind.title, action: #selector(selectMascot(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.state = kind == model?.mascot ? .on : .off
            mascotMenu.addItem(item)
        }
        mascotMenu.addItem(.separator())
        let mascotDemo = NSMenuItem(title: "Lihat semua gerakan", action: #selector(runMascotDemo(_:)), keyEquivalent: "")
        mascotDemo.target = self
        mascotMenu.addItem(mascotDemo)
        mascotItem.submenu = mascotMenu
        menu.addItem(mascotItem)

        let prayerItem = NSMenuItem(title: "Jadwal sholat", action: nil, keyEquivalent: "")
        let prayerMenu = NSMenu()
        let prayerToggle = NSMenuItem(title: "Hitung mundur sebelum sholat", action: #selector(togglePrayer(_:)), keyEquivalent: "")
        prayerToggle.target = self
        prayerToggle.state = (model?.prayerEnabled ?? true) ? .on : .off
        prayerMenu.addItem(prayerToggle)
        prayerMenu.addItem(.separator())
        let cityHeader = NSMenuItem(title: "Kota", action: nil, keyEquivalent: "")
        cityHeader.isEnabled = false
        prayerMenu.addItem(cityHeader)
        for city in PrayerCity.all {
            let item = NSMenuItem(title: city.name, action: #selector(selectPrayerCity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = city.name
            item.state = city.name == model?.prayerCityName ? .on : .off
            prayerMenu.addItem(item)
        }
        prayerItem.submenu = prayerMenu
        menu.addItem(prayerItem)

        let volumeItem = NSMenuItem(title: "Pop-up volume", action: nil, keyEquivalent: "")
        let volumeMenu = NSMenu()
        for mode in VolumeHUDMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectVolumeMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == model?.volumeHUDMode ? .on : .off
            volumeMenu.addItem(item)
        }
        volumeItem.submenu = volumeMenu
        menu.addItem(volumeItem)

        let meeting = NSMenuItem(title: "Pengingat meeting (Kalender)", action: #selector(toggleMeeting(_:)), keyEquivalent: "")
        meeting.target = self
        meeting.state = (model?.meetingEnabled ?? true) ? .on : .off
        menu.addItem(meeting)

        let clips = NSMenuItem(title: "Riwayat clipboard", action: #selector(toggleClipboard(_:)), keyEquivalent: "")
        clips.target = self
        clips.state = (model?.clipboardEnabled ?? true) ? .on : .off
        menu.addItem(clips)

        let autoShelf = NSMenuItem(title: "Download & screenshot ke Shelf", action: #selector(toggleAutoShelf(_:)), keyEquivalent: "")
        autoShelf.target = self
        autoShelf.state = (model?.autoShelfEnabled ?? true) ? .on : .off
        menu.addItem(autoShelf)

        if #available(macOS 13.0, *) {
            let login = NSMenuItem(title: "Buka saat login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }

        menu.addItem(.separator())

        let update = NSMenuItem(title: "Perbarui DynaIsland…", action: #selector(installUpdate), keyEquivalent: "")
        update.target = self
        menu.addItem(update)

        let demo = NSMenuItem(title: "Coba animasi", action: #selector(runDemo), keyEquivalent: "")
        demo.target = self
        menu.addItem(demo)

        let automation = NSMenuItem(title: "Izin Automation (kontrol musik)…", action: #selector(openAutomationSettings), keyEquivalent: "")
        automation.target = self
        menu.addItem(automation)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Keluar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
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

    @objc private func toggleHideWhenIdle(_ sender: NSMenuItem) {
        guard let model = model else { return }
        model.hideWhenIdle.toggle()
        sender.state = model.hideWhenIdle ? .on : .off
    }

    @objc private func togglePillBelowCamera(_ sender: NSMenuItem) {
        guard let model = model else { return }
        model.pillBelowCamera.toggle()
        sender.state = model.pillBelowCamera ? .on : .off
        controller?.relayout()
    }

    @objc private func selectMascot(_ sender: NSMenuItem) {
        guard let model = model,
              let raw = sender.representedObject as? String,
              let kind = MascotKind(rawValue: raw) else { return }
        model.mascot = kind
        updateMascotChecks(in: sender.menu, selected: kind)
        if kind != .off { model.react(.happy, seconds: 2) }
    }

    @objc private func runMascotDemo(_ sender: NSMenuItem) {
        guard let model = model else { return }
        if model.mascot == .off {
            model.mascot = .moci
            updateMascotChecks(in: sender.menu, selected: .moci)
        }
        model.demoMascot()
    }

    private func updateMascotChecks(in menu: NSMenu?, selected: MascotKind) {
        for item in menu?.items ?? [] {
            if let raw = item.representedObject as? String, let kind = MascotKind(rawValue: raw) {
                item.state = kind == selected ? .on : .off
            }
        }
    }

    @objc private func selectVolumeMode(_ sender: NSMenuItem) {
        guard let model = model,
              let raw = sender.representedObject as? String,
              let mode = VolumeHUDMode(rawValue: raw) else { return }
        model.volumeHUDMode = mode
        for item in sender.menu?.items ?? [] {
            if let itemRaw = item.representedObject as? String {
                item.state = itemRaw == raw ? .on : .off
            }
        }
        if mode == .island && !MediaKeys.isTrusted {
            MediaKeys.askForPermission()
        }
        controller?.secondTick()
    }

    @objc private func toggleMeeting(_ sender: NSMenuItem) {
        guard let model = model else { return }
        model.meetingEnabled.toggle()
        sender.state = model.meetingEnabled ? .on : .off
        model.calendar?.settingsChanged()
    }

    @objc private func toggleClipboard(_ sender: NSMenuItem) {
        guard let model = model else { return }
        model.clipboardEnabled.toggle()
        sender.state = model.clipboardEnabled ? .on : .off
    }

    @objc private func toggleAutoShelf(_ sender: NSMenuItem) {
        guard let model = model else { return }
        model.autoShelfEnabled.toggle()
        sender.state = model.autoShelfEnabled ? .on : .off
    }

    @objc private func togglePrayer(_ sender: NSMenuItem) {
        guard let model = model else { return }
        model.prayerEnabled.toggle()
        sender.state = model.prayerEnabled ? .on : .off
        controller?.secondTick()
    }

    @objc private func selectPrayerCity(_ sender: NSMenuItem) {
        guard let model = model, let name = sender.representedObject as? String else { return }
        model.prayerCityName = name
        model.dismissedPrayerKey = nil
        for item in sender.menu?.items ?? [] {
            if let cityName = item.representedObject as? String {
                item.state = cityName == name ? .on : .off
            }
        }
        controller?.secondTick()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSSound.beep()
        }
        sender.state = service.status == .enabled ? .on : .off
    }

    /// Menu → "Perbarui DynaIsland…": downloads the newest build from GitHub
    /// (or, offline, installs a DynaIsland zip from Downloads).
    @objc private func installUpdate() {
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

    @objc private func runDemo() {
        guard let model = model else { return }
        let percent = model.battery?.percent ?? 80
        model.show(IslandNotice(symbol: "bolt.fill", title: "Mengisi daya", detail: "\(percent)%", tint: .green))
    }

    @objc private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}
