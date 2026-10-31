import AppKit
import SwiftUI

// MARK: - What's new

struct WhatsNewItem: Identifiable {
    let id = UUID()
    /// The `WhatsNew.version` that introduced it.
    var since = 1
    let symbol: String
    let title: String
    let detail: String
}

/// Shown once after an update. Bump `version` and add items when something new ships.
enum WhatsNew {
    static let version = 3
    static let seenKey = "whatsNewSeen"

    static let items: [WhatsNewItem] = [
        WhatsNewItem(since: 3, symbol: "arrow.triangle.2.circlepath", title: "Checklist tersinkron dengan Reminders",
                     detail: "Nyalakan di Pengaturan → Fitur: checklist Hari ini ikut muncul di iPhone dan iPad, dan sebaliknya."),
        WhatsNewItem(since: 2, symbol: "checklist", title: "Checklist hari ini",
                     detail: "Tab baru \"Hari ini\": rutinitas yang muncul lagi setiap pagi, tugas yang terbawa kalau belum selesai, dan streak harian."),
        WhatsNewItem(symbol: "play.rectangle.fill", title: "Musik dari semua app",
                     detail: "YouTube di browser, Podcasts, VLC, Spotify, Music: cover, judul, dan tombol kontrolnya muncul di notch."),
        WhatsNewItem(symbol: "airpodspro", title: "Pop-up AirPods & Bluetooth",
                     detail: "Nama perangkat dan baterainya muncul saat tersambung."),
        WhatsNewItem(symbol: "hand.draw", title: "Gestur",
                     detail: "Di tab Musik: geser dua jari kiri/kanan untuk ganti lagu, atas/bawah untuk volume."),
        WhatsNewItem(symbol: "keyboard", title: "Pintasan keyboard",
                     detail: "⌃⌥ Space membuka island, ⌃⌥ V langsung ke riwayat clipboard (klik lalu tempel)."),
        WhatsNewItem(symbol: "arrow.triangle.2.circlepath", title: "Update otomatis",
                     detail: "Versi baru dipasang sendiri saat Mac tidak dipakai. Bisa dimatikan di Pengaturan."),
        WhatsNewItem(symbol: "lock.shield", title: "Izin cukup sekali",
                     detail: "Izin yang sudah diberikan tidak hilang lagi setiap update."),
        WhatsNewItem(symbol: "ladybug", title: "Laporkan masalah",
                     detail: "Pengaturan → Umum → Laporkan masalah: info teknis tersalin, tinggal kirim."),
    ]

    static var hasUnseen: Bool {
        UserDefaults.standard.integer(forKey: seenKey) < version
    }

    /// What's new since the version this Mac last saw (everything for a first look).
    static var unseenItems: [WhatsNewItem] {
        let seen = UserDefaults.standard.integer(forKey: seenKey)
        let fresh = items.filter { $0.since > seen }
        return fresh.isEmpty ? items : fresh
    }

    static func markSeen() {
        UserDefaults.standard.set(version, forKey: seenKey)
    }
}

struct WhatsNewView: View {
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 56, height: 56)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Yang baru di DynaIsland")
                        .font(.system(size: 22, weight: .bold))
                    Text("Versi \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .foregroundColor(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(WhatsNew.unseenItems) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundColor(.accentColor)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.system(size: 13, weight: .semibold))
                                Text(item.detail)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            HStack {
                Spacer()
                Button("Oke, mengerti", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480, height: 520)
    }
}

// MARK: - Report a problem

/// Technical facts that help find a problem. Nothing personal: no clipboard contents,
/// file names, song titles or calendar events.
@MainActor
enum Diagnostics {
    static func report(model: IslandModel) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        var lines: [String] = []

        lines.append("DynaIsland \(version) (build \(build))")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Mac: \(sysctlString("hw.model") ?? "?") · \(machineArchitecture())")

        if let screen = NSScreen.screens.first {
            let frame = screen.frame
            let layout = model.layout
            let style: String
            if layout.hasNotch {
                style = "membungkus kamera"
            } else if layout.camera != nil {
                style = "pil di bawah kamera"
            } else {
                style = "pil di menu bar (tanpa notch)"
            }
            let notch = layout.notch ?? layout.camera
            let notchText = notch.map { "\(Int($0.width))×\(Int($0.height))" } ?? "tidak ada"
            lines.append("Layar: \(Int(frame.width))×\(Int(frame.height)) pt, \(NSScreen.screens.count) layar, notch \(notchText), gaya \(style)")
        }

        let systemActive = model.player?.system?.isActive == true
        let music = systemActive ? "semua app (adapter aktif)"
            : (SystemNowPlaying.isBundled ? "Spotify/Music saja (adapter tidak jalan)" : "Spotify/Music saja (adapter tidak ada)")
        lines.append("Musik: \(music); pemutar sekarang: \(model.track?.appBundleID ?? model.track?.source.rawValue ?? "-")")

        let calendar: String
        switch model.calendarAccess {
        case .granted: calendar = "ya"
        case .denied: calendar = "ditolak"
        case .notDetermined: calendar = "belum"
        }
        let folders = model.folderAccess.map { $0 ? "ya" : "ditolak" } ?? "belum"
        let bluetooth = BluetoothMonitor.isAllowed ? "ya" : (BluetoothMonitor.isDenied ? "ditolak" : "belum")
        lines.append("Izin: kalender=\(calendar), folder=\(folders), aksesibilitas=\(MediaKeys.isTrusted ? "ya" : "belum"), bluetooth=\(bluetooth), automation-ditolak=\(model.automationDenied)")

        lines.append("Checklist: \(model.checklist.count) item, reminders-sync=\(model.remindersSync), akses-reminders=\(model.remindersAccess)")
        lines.append("Fitur: maskot=\(model.mascot.rawValue), sholat=\(model.prayerEnabled) (\(model.prayerCityName)), meeting=\(model.meetingEnabled), clipboard=\(model.clipboardEnabled), shelf-otomatis=\(model.autoShelfEnabled), bluetooth=\(model.bluetoothEnabled), gestur=\(model.gesturesEnabled), pintasan=\(model.hotKeysEnabled), volume=\(model.volumeHUDMode.rawValue), update-otomatis=\(model.autoUpdateEnabled), sembunyi-idle=\(model.hideWhenIdle)")

        if !HotKeys.taken.isEmpty {
            lines.append("Pintasan dipakai app lain: \(HotKeys.taken.map { $0.label }.joined(separator: ", "))")
        }
        let localKeychain = FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Keychains/dynaisland-signing.keychain-db").path)
        lines.append("Tanda tangan lokal: \(localKeychain ? "ada" : "tidak ada")")
        if let latest = model.latestBuild { lines.append("Versi terbaru di GitHub: build \(latest)") }

        if let log = try? String(contentsOf: Updater.logURL, encoding: .utf8), !log.isEmpty {
            let tail = log.split(separator: "\n", omittingEmptySubsequences: false).suffix(25).joined(separator: "\n")
            lines.append("")
            lines.append("Log update terakhir:")
            lines.append(tail)
        }
        return lines.joined(separator: "\n")
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func machineArchitecture() -> String {
        #if arch(arm64)
        return "Apple Silicon"
        #else
        return "Intel"
        #endif
    }

    /// A pre-filled "new issue" page on GitHub.
    static func issueURL(story: String, report: String) -> URL? {
        let title = story.split(separator: "\n").first.map { String($0.prefix(70)) } ?? ""
        var body = story.isEmpty ? "(ceritakan masalahnya di sini)" : story
        body += "\n\n```\n\(report.prefix(5_500))\n```"
        var components = URLComponents(string: "https://github.com/\(Updater.repo)/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: title.isEmpty ? "Laporan masalah" : title),
            URLQueryItem(name: "body", value: body),
        ]
        return components?.url
    }
}

@MainActor
struct ReportView: View {
    let report: String
    @State private var story = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Laporkan masalah")
                .font(.system(size: 22, weight: .bold))
            Text("Ceritakan apa yang terjadi dan kapan. Info teknis di bawah ikut disertakan. Isinya tidak memuat data pribadi: tidak ada isi clipboard, nama file, judul lagu, atau isi kalender.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $story)
                .font(.system(size: 13))
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            Text("Info teknis")
                .font(.system(size: 13, weight: .semibold))
            ScrollView {
                Text(report)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))

            HStack(spacing: 10) {
                Spacer()
                Button(copied ? "Tersalin, tempel di WhatsApp" : "Salin untuk WhatsApp") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    let story = self.story.trimmingCharacters(in: .whitespacesAndNewlines)
                    pasteboard.setString((story.isEmpty ? "" : story + "\n\n") + report, forType: .string)
                    copied = true
                }
                Button("Kirim lewat GitHub") {
                    if let url = Diagnostics.issueURL(story: story.trimmingCharacters(in: .whitespacesAndNewlines),
                                                      report: report) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 580, height: 560)
    }
}
