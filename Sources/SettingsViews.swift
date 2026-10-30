import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Settings window

@MainActor
struct SettingsView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        TabView {
            AppearanceSettings(model: model)
                .tabItem { Label("Tampilan", systemImage: "paintbrush") }
            FeatureSettings(model: model)
                .tabItem { Label("Fitur", systemImage: "square.grid.2x2") }
            ScrollView {
                PermissionList(model: model)
                    .padding(20)
            }
            .tabItem { Label("Izin", systemImage: "lock.shield") }
            GeneralSettings(model: model)
                .tabItem { Label("Umum", systemImage: "gearshape") }
        }
        .padding(12)
        .frame(width: 600, height: 500)
    }
}

@MainActor
struct AppearanceSettings: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(label: Text("Maskot")) {
                MascotPicker(model: model)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Text("Island")) {
                VStack(alignment: .leading, spacing: 10) {
                    if model.layout.hasNotch || model.layout.camera != nil {
                        Picker("Gaya", selection: Binding(
                            get: { model.pillBelowCamera },
                            set: { value in
                                model.pillBelowCamera = value
                                DynaIslandApp.delegate.relayout()
                            })) {
                            Text("Membungkus kamera").tag(false)
                            Text("Pil di bawah kamera").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 360)
                    }
                    Toggle("Sembunyikan saat tidak ada aktivitas", isOn: $model.hideWhenIdle)
                    Text("Island tetap terbuka saat kursor diarahkan ke tengah atas layar.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }
}

@MainActor
struct FeatureSettings: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox(label: Text("Jadwal sholat")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Hitung mundur 10 menit sebelum sholat", isOn: $model.prayerEnabled)
                        Picker("Kota", selection: Binding(
                            get: { model.prayerCityName },
                            set: { name in
                                model.prayerCityName = name
                                model.dismissedPrayerKey = nil
                            })) {
                            ForEach(PrayerCity.all, id: \.name) { city in
                                Text(city.name).tag(city.name)
                            }
                        }
                        .frame(width: 280)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(label: Text("Pop-up volume")) {
                    Picker("", selection: Binding(
                        get: { model.volumeHUDMode },
                        set: { mode in
                            model.volumeHUDMode = mode
                            if mode == .island && !MediaKeys.isTrusted { MediaKeys.askForPermission() }
                        })) {
                        ForEach(VolumeHUDMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(label: Text("Fitur lain")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Pengingat meeting dari Kalender", isOn: Binding(
                            get: { model.meetingEnabled },
                            set: { value in
                                model.meetingEnabled = value
                                model.calendar?.settingsChanged()
                            }))
                        Toggle("Pop-up saat AirPods / perangkat Bluetooth tersambung", isOn: Binding(
                            get: { model.bluetoothEnabled },
                            set: { value in
                                model.bluetoothEnabled = value
                                DynaIslandApp.delegate.bluetoothSettingChanged()
                            }))
                        Toggle("Riwayat clipboard", isOn: $model.clipboardEnabled)
                        Toggle("Download & screenshot otomatis ke Shelf", isOn: $model.autoShelfEnabled)
                        Toggle("Gestur di tab Musik: geser untuk ganti lagu, scroll untuk volume",
                               isOn: $model.gesturesEnabled)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
    }
}

@MainActor
struct GeneralSettings: View {
    @ObservedObject var model: IslandModel
    @State private var opensAtLogin = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(label: Text("Mulai")) {
                VStack(alignment: .leading, spacing: 8) {
                    if #available(macOS 13.0, *) {
                        Toggle("Buka DynaIsland otomatis saat Mac menyala", isOn: Binding(
                            get: { opensAtLogin },
                            set: { value in
                                opensAtLogin = GeneralSettings.setOpensAtLogin(value)
                            }))
                    } else {
                        Text("Buka saat login: tambahkan DynaIsland di System Preferences → Users & Groups → Login Items.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Button("Tampilkan layar sambutan lagi") { DynaIslandApp.delegate.showOnboarding() }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Text("Versi")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("DynaIsland \(version)")
                        if let latest = model.latestBuild, latest > Updater.currentBuild {
                            Text("· versi 1.\(latest) tersedia")
                                .foregroundColor(.green)
                        }
                    }
                    HStack(spacing: 10) {
                        Button("Perbarui…") { DynaIslandApp.delegate.installUpdate() }
                        Button("Coba animasi") { DynaIslandApp.delegate.runDemo() }
                        Button("Lihat semua gerakan maskot") { model.demoMascot() }
                    }
                    if let url = URL(string: "https://github.com/\(Updater.repo)") {
                        Link("github.com/\(Updater.repo)", destination: url)
                            .font(.caption)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Keluar dari DynaIsland") { NSApp.terminate(nil) }
            }
        }
        .padding(20)
        .onAppear { opensAtLogin = GeneralSettings.opensAtLogin }
    }

    static var opensAtLogin: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    static func setOpensAtLogin(_ enabled: Bool) -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        let service = SMAppService.mainApp
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            NSSound.beep()
        }
        return service.status == .enabled
    }
}

// MARK: - Shared pieces

@MainActor
struct MascotPicker: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 12) {
            ForEach(MascotKind.allCases, id: \.self) { kind in
                Button(action: {
                    model.mascot = kind
                    if kind != .off { model.react(.happy, seconds: 1.5) }
                }) {
                    VStack(spacing: 6) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.black)
                            if kind == .off {
                                Image(systemName: "nosign")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundColor(Color.white.opacity(0.55))
                            } else {
                                MascotView(model: model, size: 36, kind: kind)
                            }
                        }
                        .frame(width: 92, height: 64)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(model.mascot == kind ? Color.accentColor : Color.clear, lineWidth: 3)
                        )
                        Text(kind == .off ? "Tanpa" : kind.shortName)
                            .font(.system(size: 12, weight: model.mascot == kind ? .semibold : .regular))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

enum PermissionState {
    case granted, needed, denied, later
}

/// Every permission DynaIsland may ask for, with its status and a button.
@MainActor
struct PermissionList: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        // Re-checks once a second, so a switch flipped in System Settings shows up here.
        TimelineView(.periodic(from: Date(), by: 1)) { _ in
            VStack(spacing: 10) {
                PermissionRow(symbol: "calendar", title: "Kalender",
                              detail: "Hitung mundur meeting dan tombol Gabung",
                              state: calendarState) {
                    model.calendar?.requestAccess()
                }
                PermissionRow(symbol: "folder", title: "Folder Downloads dan Desktop",
                              detail: "Download dan screenshot baru langsung masuk Shelf",
                              state: folderState) {
                    if model.folderAccess == false {
                        PermissionList.openPrivacy("Privacy_FilesAndFolders")
                    } else {
                        DynaIslandApp.delegate.requestFolderAccess()
                    }
                }
                PermissionRow(symbol: "speaker.wave.2", title: "Aksesibilitas",
                              detail: "Supaya hanya satu pop-up volume yang muncul",
                              state: MediaKeys.isTrusted ? .granted : .needed) {
                    MediaKeys.askForPermission()
                    PermissionList.openPrivacy("Privacy_Accessibility")
                }
                PermissionRow(symbol: "airpods", title: "Bluetooth",
                              detail: "Pop-up AirPods dan perangkat Bluetooth",
                              state: bluetoothState) {
                    if BluetoothMonitor.isDenied {
                        PermissionList.openPrivacy("Privacy_Bluetooth")
                    } else {
                        DynaIslandApp.delegate.requestBluetooth()
                    }
                }
                PermissionRow(symbol: "music.note", title: "Kontrol musik",
                              detail: "Ditanyakan saat pertama memutar Spotify atau Apple Music",
                              state: .later) {
                    PermissionList.openPrivacy("Privacy_Automation")
                }
            }
        }
    }

    private var calendarState: PermissionState {
        switch model.calendarAccess {
        case .granted: return .granted
        case .notDetermined: return .needed
        case .denied: return .denied
        }
    }

    private var folderState: PermissionState {
        switch model.folderAccess {
        case .some(true): return .granted
        case .some(false): return .denied
        case .none: return .needed
        }
    }

    private var bluetoothState: PermissionState {
        if BluetoothMonitor.isAllowed { return .granted }
        return BluetoothMonitor.isDenied ? .denied : .needed
    }

    static func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let state: PermissionState
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(red: 0.36, green: 0.25, blue: 0.62)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            switch state {
            case .granted:
                Label("Diizinkan", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.green)
            case .needed:
                Button("Izinkan", action: action)
            case .denied:
                Button("Buka pengaturan", action: action)
            case .later:
                Button("Pengaturan", action: action)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - Welcome screen (first launch)

@MainActor
struct OnboardingView: View {
    @ObservedObject var model: IslandModel
    let finish: () -> Void
    @State private var step = 0
    private let lastStep = 3

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: mascot
                case 2: permissions
                default: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, 28)

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(0..<4) { index in
                        Circle()
                            .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if step > 0 && step < lastStep {
                    Button("Kembali") { step -= 1 }
                }
                Button(step == lastStep ? "Mulai pakai" : "Lanjut") {
                    if step == lastStep { finish() } else { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 600, height: 520)
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 112, height: 112)
            }
            Text("Selamat datang di DynaIsland")
                .font(.system(size: 26, weight: .bold))
            Text("Area hitam di sekitar kamera MacBook kamu sekarang hidup: musik, maskot, jadwal sholat, meeting, timer fokus, Shelf file, dan riwayat clipboard.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow.motionlines")
                Text("Arahkan kursor ke notch (tengah atas layar) untuk membuka island.")
            }
            .font(.system(size: 13, weight: .medium))
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
            Spacer(minLength: 0)
        }
    }

    private var mascot: some View {
        VStack(spacing: 16) {
            Text("Pilih maskot")
                .font(.system(size: 24, weight: .bold))
            Text("Maskot tinggal di samping kamera: berjoget saat musik, tidur saat Mac didiamkan, dan menyambut saat island dibuka.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            MascotPicker(model: model)
                .padding(.top, 8)
            Spacer(minLength: 0)
        }
    }

    private var permissions: some View {
        VStack(spacing: 12) {
            Text("Izinkan fitur yang kamu mau")
                .font(.system(size: 24, weight: .bold))
            Text("Semua opsional dan bisa diubah kapan saja di Pengaturan.")
                .foregroundColor(.secondary)
            PermissionList(model: model)
            Spacer(minLength: 0)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Siap!")
                .font(.system(size: 26, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .center)
            OnboardingTip(symbol: "cursorarrow.rays", text: "Arahkan kursor ke notch untuk membuka island: Musik, Agenda, Sholat, Fokus, Shelf, Clipboard.")
            OnboardingTip(symbol: "tray.and.arrow.down", text: "Seret file ke notch untuk menyimpannya di Shelf, lalu seret keluar atau kirim lewat AirDrop.")
            OnboardingTip(symbol: "hand.draw", text: "Di tab Musik: geser dua jari ke kiri/kanan untuk ganti lagu, ke atas/bawah untuk volume.")
            OnboardingTip(symbol: "menubar.rectangle", text: "Pengaturan dan update ada di ikon DynaIsland di menu bar.")
            Spacer(minLength: 0)
        }
    }
}

struct OnboardingTip: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 26)
                .foregroundColor(.accentColor)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
