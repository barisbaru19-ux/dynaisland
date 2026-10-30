import AppKit
import AudioToolbox
import CoreAudio

extension Notification.Name {
    static let dynaVolumeChanged = Notification.Name("DynaIsland.VolumeChanged")
    static let dynaOutputDeviceChanged = Notification.Name("DynaIsland.OutputDeviceChanged")
}

// Core Audio calls these on its own thread; they only hop to the main thread and re-post.
private func volumeListener(_ objectID: AudioObjectID,
                            _ count: UInt32,
                            _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
                            _ context: UnsafeMutableRawPointer?) -> OSStatus {
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .dynaVolumeChanged, object: nil)
    }
    return noErr
}

private func outputDeviceListener(_ objectID: AudioObjectID,
                                  _ count: UInt32,
                                  _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
                                  _ context: UnsafeMutableRawPointer?) -> OSStatus {
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .dynaOutputDeviceChanged, object: nil)
    }
    return noErr
}

/// Shows a volume pop-up in the island when the system volume or mute changes.
/// Reads Core Audio directly, so it needs no extra permission.
@MainActor
final class VolumeMonitor: NSObject {
    private let model: IslandModel
    private var device = AudioObjectID(0)
    private var lastLevel: Double?
    private var lastMuted: Bool?

    init(model: IslandModel) {
        self.model = model
        super.init()
    }

    func start() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(volumeChanged), name: .dynaVolumeChanged, object: nil)
        center.addObserver(self, selector: #selector(outputDeviceChanged), name: .dynaOutputDeviceChanged, object: nil)

        var defaultDevice = Self.makeAddress(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        _ = AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &defaultDevice, outputDeviceListener, nil)

        attach(to: Self.defaultOutputDevice())
    }

    // MARK: - Listening

    @objc private func outputDeviceChanged() {
        // Headphones plugged in, AirPods connected… follow the new output silently.
        attach(to: Self.defaultOutputDevice())
    }

    @objc private func volumeChanged() {
        guard let level = readLevel() else { return }
        let muted = readMuted() ?? false
        defer {
            lastLevel = level
            lastMuted = muted
        }
        if let previous = lastLevel, abs(previous - level) < 0.001, lastMuted == muted { return }
        model.showVolume(level: level, muted: muted)
    }

    private func attach(to newDevice: AudioObjectID?) {
        if device != 0 {
            var volume = Self.volumeAddress()
            _ = AudioObjectRemovePropertyListener(device, &volume, volumeListener, nil)
            var mute = Self.muteAddress()
            _ = AudioObjectRemovePropertyListener(device, &mute, volumeListener, nil)
        }

        device = newDevice ?? 0
        guard device != 0 else { return }

        var volume = Self.volumeAddress()
        if AudioObjectHasProperty(device, &volume) == true {
            _ = AudioObjectAddPropertyListener(device, &volume, volumeListener, nil)
        }
        var mute = Self.muteAddress()
        if AudioObjectHasProperty(device, &mute) == true {
            _ = AudioObjectAddPropertyListener(device, &mute, volumeListener, nil)
        }

        // Baseline, so switching devices doesn't pop anything up.
        lastLevel = readLevel()
        lastMuted = readMuted()
    }

    // MARK: - Reading

    private func readLevel() -> Double? {
        guard device != 0 else { return nil }
        var address = Self.volumeAddress()
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? Double(value) : nil
    }

    private func readMuted() -> Bool? {
        guard device != 0 else { return nil }
        var address = Self.muteAddress()
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value != 0 : nil
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = makeAddress(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        makeAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        makeAddress(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
    }

    private static func makeAddress(_ selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
