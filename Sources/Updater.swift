import AppKit

/// Updates DynaIsland without Terminal, from GitHub or from a DynaIsland zip on the shelf.
///
/// The app runs the installer itself (instead of you double-clicking a downloaded file),
/// so macOS's "damaged / can't be opened" check never comes up.
@MainActor
final class Updater {
    static let repo = "barisbaru19-ux/dynaisland"
    static let installScriptURL = "https://raw.githubusercontent.com/\(repo)/main/install.sh"
    static let installCommand = "curl -fsSL \(installScriptURL) | bash"
    private static let versionURL = URL(string: "https://github.com/\(repo)/releases/latest/download/version.txt")

    private let model: IslandModel
    private var process: Process?
    private var checkTask: Task<Void, Never>?

    /// Build number of this copy (1 when built by hand, the GitHub build number otherwise).
    static var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DynaIsland-update.log")
    private static let startedKey = "updateStartedAt"
    private static let workPrefix = "DynaIslandUpdate-"

    init(model: IslandModel) {
        self.model = model
    }

    static func isUpdateZip(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "zip" && url.lastPathComponent.lowercased().hasPrefix("dynaisland")
    }

    /// The newest DynaIsland*.zip in Downloads or on the Desktop.
    static func newestZip() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var best: (url: URL, date: Date)?
        for folder in ["Downloads", "Desktop"] {
            let dir = home.appendingPathComponent(folder, isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for item in items where isUpdateZip(item) {
                let values = try? item.resourceValues(forKeys: [.contentModificationDateKey])
                let date = values?.contentModificationDate ?? .distantPast
                if best.map({ date > $0.date }) ?? true {
                    best = (item, date)
                }
            }
        }
        return best?.url
    }

    /// Once at launch: says so after an update, and removes leftover unzip folders.
    func launched() {
        let defaults = UserDefaults.standard
        if let started = defaults.object(forKey: Updater.startedKey) as? Date {
            defaults.removeObject(forKey: Updater.startedKey)
            if Date().timeIntervalSince(started) < 15 * 60 {
                model.show(IslandNotice(symbol: "checkmark.seal.fill", title: "DynaIsland diperbarui",
                                        detail: "Siap", tint: .green), seconds: 4)
                model.react(.happy, seconds: 5)
            }
        }

        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil) {
            for item in items where item.lastPathComponent.hasPrefix(Updater.workPrefix) {
                try? fm.removeItem(at: item)
            }
        }
    }

    // MARK: Checking GitHub

    /// Looks for a newer build 10 seconds after launch, then every 2 hours.
    func startChecking() {
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            while !Task.isCancelled {
                guard let updater = self else { return }
                await updater.checkForUpdate()
                try? await Task.sleep(nanoseconds: 2 * 3_600 * 1_000_000_000)
            }
        }
    }

    func checkForUpdate() async {
        guard let url = Updater.versionURL,
              let result = try? await URLSession.shared.data(from: url),
              let text = String(data: result.0, encoding: .utf8),
              let latest = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        model.latestBuild = latest
        guard latest > Updater.currentBuild else { return }
        // Tell once per new version.
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: "announcedBuild") < latest {
            defaults.set(latest, forKey: "announcedBuild")
            model.show(IslandNotice(symbol: "arrow.down.app.fill", title: "Versi baru tersedia",
                                    detail: "1.\(latest)", tint: .green), seconds: 5)
        }
    }

    // MARK: Automatic updates

    private var lastAutoAttempt = Date.distantPast

    /// Called once a second. Installs a newer build by itself only when nobody would notice:
    /// no input for 10 minutes, no music, no focus timer, no meeting, island closed.
    func considerAutoUpdate(idleSeconds: Double) {
        guard model.autoUpdateEnabled, !model.isUpdating, process == nil,
              let latest = model.latestBuild, latest > Updater.currentBuild,
              idleSeconds > 600,
              model.track?.isPlaying != true, model.focus == nil,
              model.meetingAlert == nil, !model.isHovered,
              Date().timeIntervalSince(lastAutoAttempt) > 6 * 3600 else { return }
        lastAutoAttempt = Date()
        installOnline()
    }

    // MARK: Installing

    /// Downloads and installs the newest build from GitHub (same as the one-line Terminal command).
    func installOnline() {
        let script = """
        set -e
        echo "Update dari: $1"
        /usr/bin/curl -fsSL "$1" | /bin/bash
        """
        run(script: script, arguments: [Updater.installScriptURL])
    }

    func install(from zip: URL) {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent(Updater.workPrefix + UUID().uuidString, isDirectory: true)
        // $1 = zip, $2 = working folder.
        let script = """
        set -e
        echo "Update dari: $1"
        mkdir -p "$2"
        /usr/bin/ditto -x -k "$1" "$2"
        /usr/bin/xattr -cr "$2" 2>/dev/null || true
        build="$(/usr/bin/find "$2" -maxdepth 3 -name build.sh -type f | head -n 1)"
        if [ -z "$build" ]; then echo "build.sh tidak ada di zip ini"; exit 3; fi
        cd "$(dirname "$build")"
        /bin/bash ./build.sh --install
        """
        run(script: script, arguments: [zip.path, work.path])
    }

    /// Runs an install script. Output goes to a log file (not a pipe), so it keeps going when
    /// the installer closes this copy of the app and opens the new one.
    private func run(script: String, arguments: [String]) {
        guard process == nil else { return }
        let fm = FileManager.default
        let log = Updater.logURL
        try? fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: log.path, contents: nil)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", script, "dynaisland-update"] + arguments
        if let handle = try? FileHandle(forWritingTo: log) {
            task.standardOutput = handle
            task.standardError = handle
        }
        task.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let updater = self
            Task { @MainActor in
                updater?.finished(status: status)
            }
        }

        UserDefaults.standard.set(Date(), forKey: Updater.startedKey)
        do {
            try task.run()
        } catch {
            UserDefaults.standard.removeObject(forKey: Updater.startedKey)
            showFailure()
            return
        }
        process = task
        model.isUpdating = true
        model.availableUpdate = nil
        model.show(IslandNotice(symbol: "arrow.triangle.2.circlepath", title: "Memasang update",
                                detail: "±1 mnt", tint: .white), seconds: 90)
    }

    /// Only reached when the build failed: on success build.sh closes this copy and opens the new one.
    private func finished(status: Int32) {
        process = nil
        model.isUpdating = false
        guard status != 0 else { return }
        UserDefaults.standard.removeObject(forKey: Updater.startedKey)
        showFailure()
    }

    private func showFailure() {
        model.show(IslandNotice(symbol: "exclamationmark.triangle.fill", title: "Update gagal",
                                detail: "Lihat log", tint: .red), seconds: 5)
        NSWorkspace.shared.open(Updater.logURL)
    }
}
