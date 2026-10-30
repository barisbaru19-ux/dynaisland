import AppKit
import IOKit.ps

extension Notification.Name {
    static let dynaPowerSourceChanged = Notification.Name("DynaIsland.PowerSourceChanged")
}

/// IOKit calls a plain C function. It only re-posts a notification that
/// BatteryMonitor observes on the main thread.
private func powerSourceCallback(_ context: UnsafeMutableRawPointer?) {
    NotificationCenter.default.post(name: .dynaPowerSourceChanged, object: nil)
}

/// Watches the internal battery and shows charger / low-battery notices.
@MainActor
final class BatteryMonitor: NSObject {
    private let model: IslandModel
    private var runLoopSource: CFRunLoopSource?
    private var last: BatteryState?
    private var warnedLevels: Set<Int> = []

    init(model: IslandModel) {
        self.model = model
        super.init()
    }

    func start() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(powerSourceChanged),
                                               name: .dynaPowerSourceChanged,
                                               object: nil)

        if let source = IOPSNotificationCreateRunLoopSource(powerSourceCallback, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        }

        last = read()
        model.battery = last
    }

    @objc private func powerSourceChanged() {
        guard let now = read() else { return }
        let previous = last
        last = now
        if model.battery != now { model.battery = now }
        guard let prev = previous else { return }

        if now.isPluggedIn != prev.isPluggedIn {
            warnedLevels.removeAll()
            if now.isPluggedIn {
                model.show(IslandNotice(symbol: "bolt.fill",
                                        title: "Mengisi daya",
                                        detail: "\(now.percent)%",
                                        tint: .green))
            } else {
                model.show(IslandNotice(symbol: "bolt.slash.fill",
                                        title: "Pakai baterai",
                                        detail: "\(now.percent)%",
                                        tint: now.percent <= 20 ? .red : .white))
            }
            return
        }

        if now.isPluggedIn && now.percent == 100 && prev.percent < 100 {
            model.show(IslandNotice(symbol: "battery.100.bolt",
                                    title: "Terisi penuh",
                                    detail: "100%",
                                    tint: .green))
        }

        if !now.isPluggedIn {
            for level in [20, 10] where now.percent <= level && prev.percent > level && !warnedLevels.contains(level) {
                warnedLevels.insert(level)
                model.show(IslandNotice(symbol: "battery.25",
                                        title: "Baterai lemah",
                                        detail: "\(now.percent)%",
                                        tint: .red),
                           seconds: 4)
                break
            }
        }
    }

    private func read() -> BatteryState? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let cfList = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() else { return nil }
        let list = cfList as NSArray

        for powerSource in list {
            let unmanaged = IOPSGetPowerSourceDescription(blob, powerSource as CFTypeRef)
            guard let cfDescription = unmanaged?.takeUnretainedValue(),
                  let description = cfDescription as? [String: Any],
                  (description["Type"] as? String) == "InternalBattery" else { continue }

            let current = (description["Current Capacity"] as? Int) ?? 0
            let maximum = (description["Max Capacity"] as? Int) ?? 100
            let percent = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
            let charging = (description["Is Charging"] as? Bool) ?? false
            let plugged = (description["Power Source State"] as? String) == "AC Power"
            return BatteryState(percent: min(100, max(0, percent)), isCharging: charging, isPluggedIn: plugged)
        }
        return nil   // e.g. Mac mini / iMac: no battery
    }
}
