import AppKit
import CoreBluetooth
import IOBluetooth

/// "AirPods Pro · L 80% R 75%" in the island when a Bluetooth device connects, like on iPhone.
/// Asks for Bluetooth permission the first time it starts.
@MainActor
final class BluetoothMonitor: NSObject {
    private let model: IslandModel
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var startedAt = Date.distantFuture
    private(set) var isRunning = false

    init(model: IslandModel) {
        self.model = model
        super.init()
    }

    static var isAllowed: Bool { CBManager.authorization == .allowedAlways }
    static var isDenied: Bool {
        let status = CBManager.authorization
        return status == .denied || status == .restricted
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startedAt = Date()
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                         selector: #selector(deviceConnected(_:device:)))
    }

    func stop() {
        connectNotification?.unregister()
        connectNotification = nil
        for notification in disconnectNotifications.values { notification.unregister() }
        disconnectNotifications.removeAll()
        isRunning = false
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address: String? = device.addressString
        let key = address ?? String(describing: ObjectIdentifier(device))
        if disconnectNotifications[key] == nil {
            disconnectNotifications[key] = device.register(forDisconnectNotification: self,
                                                           selector: #selector(deviceDisconnected(_:device:)))
        }
        // Devices that were already connected are reported right after start: stay quiet for those.
        guard Date().timeIntervalSince(startedAt) > 3, model.bluetoothEnabled else { return }
        announce(device, connected: true)

        // AirPods report their battery a moment after connecting: update the pop-up then.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self = self, self.model.notice != nil else { return }
            self.announce(device, connected: true, quietlyUpdate: true)
        }
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address: String? = device.addressString
        if let address = address {
            disconnectNotifications[address]?.unregister()
            disconnectNotifications[address] = nil
        }
        guard model.bluetoothEnabled else { return }
        announce(device, connected: false)
    }

    private func announce(_ device: IOBluetoothDevice, connected: Bool, quietlyUpdate: Bool = false) {
        let rawName: String? = device.name
        let name = (rawName?.isEmpty == false ? rawName : nil) ?? "Perangkat Bluetooth"
        let symbol = BluetoothMonitor.symbol(for: device, name: name)

        guard connected else {
            model.show(IslandNotice(symbol: symbol, title: name, detail: "Terputus", tint: .white), seconds: 2.4)
            return
        }

        let left = BluetoothMonitor.battery(device, "batteryPercentLeft")
        let right = BluetoothMonitor.battery(device, "batteryPercentRight")
        let single = BluetoothMonitor.battery(device, "batteryPercentSingle")
            ?? BluetoothMonitor.battery(device, "batteryPercentCombined")

        var detail = "Tersambung"
        var level: Double?
        var lowest: Int?
        if let left = left, let right = right {
            detail = "L \(left)  R \(right)"
            lowest = min(left, right)
        } else if let percent = single ?? left ?? right {
            detail = "\(percent)%"
            level = Double(percent) / 100
            lowest = percent
        }
        if quietlyUpdate && lowest == nil { return }   // nothing new to show
        let tint: NoticeTint = (lowest ?? 100) <= 20 ? .red : .green
        model.show(IslandNotice(symbol: symbol, title: name, detail: detail, tint: tint, level: level),
                   seconds: quietlyUpdate ? 2.2 : 3.2)
    }

    /// Battery levels that macOS keeps for AirPods, Beats, Magic devices… (not public API, so
    /// every key is checked first and simply skipped when missing).
    private static func battery(_ device: IOBluetoothDevice, _ key: String) -> Int? {
        guard device.responds(to: NSSelectorFromString(key)),
              let number = device.value(forKey: key) as? NSNumber else { return nil }
        let percent = number.intValue
        return (1...100).contains(percent) ? percent : nil
    }

    private static func symbol(for device: IOBluetoothDevice, name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") { return "beats.headphones" }
        switch device.deviceClassMajor {
        case 0x04:   // audio / video
            return "headphones"
        case 0x05:   // peripheral
            let minor = device.deviceClassMinor
            if minor & 0x10 != 0 { return "keyboard" }
            if minor & 0x20 != 0 { return "magicmouse" }
            return "gamecontroller"
        default:
            return "dot.radiowaves.left.and.right"
        }
    }
}
