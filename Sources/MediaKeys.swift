import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio

/// Which volume pop-up shows when you press the volume keys.
enum VolumeHUDMode: String, CaseIterable {
    case island    // only the island's (DynaIsland handles the keys, macOS HUD stays hidden)
    case system    // only macOS's own HUD
    case both

    var title: String {
        switch self {
        case .island: return "Hanya di island (sembunyikan HUD macOS)"
        case .system: return "Hanya HUD macOS"
        case .both: return "Keduanya"
        }
    }
}

// MARK: - Volume keys

/// Catches the volume keys (F10–F12, Touch Bar, external keyboards) and changes the volume
/// itself, so macOS doesn't show its own HUD next to the island's.
/// Needs Accessibility permission: System Settings → Privacy & Security → Accessibility.
enum MediaKeys {
    /// Read by the event-tap callback, which runs on the main run loop outside Swift concurrency.
    static var isActive = false
    static var tap: CFMachPort?
    private static var source: CFRunLoopSource?

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's "allow accessibility" dialog.
    static func askForPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Starts catching the keys if permitted. Returns whether it's running.
    @discardableResult
    static func start() -> Bool {
        if tap != nil {
            isActive = true
            return true
        }
        guard AXIsProcessTrusted() else { return false }
        let systemDefined: CGEventMask = 1 << 14   // NX_SYSDEFINED: media / volume keys
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: systemDefined,
                                           callback: mediaKeyCallback,
                                           userInfo: nil) else { return false }
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = runLoopSource
        isActive = true
        return true
    }

    static func stop() {
        isActive = false
        if let port = tap {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoopSource = source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        source = nil
    }
}

/// NX_KEYTYPE_SOUND_UP / SOUND_DOWN / MUTE inside an NX_SYSDEFINED event.
private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let pass = Unmanaged.passUnretained(event)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let port = MediaKeys.tap { CGEvent.tapEnable(tap: port, enable: true) }
        return pass
    }
    guard MediaKeys.isActive, type.rawValue == 14,
          let keyEvent = NSEvent(cgEvent: event), keyEvent.subtype.rawValue == 8 else { return pass }

    let data = keyEvent.data1
    let keyCode = (data & 0xFFFF_0000) >> 16
    let keyFlags = data & 0x0000_FFFF
    let isDown = ((keyFlags & 0xFF00) >> 8) == 0xA
    guard keyCode == 0 || keyCode == 1 || keyCode == 7 else { return pass }   // up, down, mute

    let flags = event.flags
    // ⌥ + volume key opens Sound settings: leave that to macOS.
    if flags.contains(.maskAlternate) && !flags.contains(.maskShift) { return pass }
    // HDMI / DisplayPort outputs without volume control: let macOS show its "not adjustable" HUD.
    guard SystemVolume.isAdjustable() else { return pass }

    if isDown {
        // ⌥⇧ + volume key: quarter steps, like macOS.
        let fine = flags.contains(.maskAlternate) && flags.contains(.maskShift)
        let step: Float32 = fine ? 1.0 / 64.0 : 1.0 / 16.0
        switch keyCode {
        case 0: SystemVolume.change(by: step)
        case 1: SystemVolume.change(by: -step)
        default: SystemVolume.toggleMute()
        }
    }
    return nil   // swallowed: macOS shows no HUD; the island's pop-up follows the volume change
}

// MARK: - Setting the volume

enum SystemVolume {
    static func isAdjustable() -> Bool {
        guard let device = defaultOutput() else { return false }
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(device, &address, &settable)
        return status == noErr && settable.boolValue
    }

    static func change(by step: Float32) {
        guard let device = defaultOutput() else { return }
        let current = volume(of: device) ?? 0
        let muted = isMuted(device)
        // Snap to the same grid as macOS (16 or 64 steps).
        let size = abs(step)
        let next = ((current / size).rounded() + (step > 0 ? 1 : -1)) * size
        let level = min(1, max(0, next))
        setVolume(level, of: device)
        if step > 0 && muted { setMuted(false, of: device) }
        if level <= 0.0001 { setMuted(true, of: device) }
    }

    static func toggleMute() {
        guard let device = defaultOutput() else { return }
        setMuted(!isMuted(device), of: device)
    }

    // MARK: Core Audio

    private static func defaultOutput() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func volume(of device: AudioObjectID) -> Float32? {
        var address = volumeAddress()
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func setVolume(_ level: Float32, of device: AudioObjectID) {
        var address = volumeAddress()
        var value = level
        _ = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    private static func isMuted(_ device: AudioObjectID) -> Bool {
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private static func setMuted(_ muted: Bool, of device: AudioObjectID) {
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return }
        var value: UInt32 = muted ? 1 : 0
        _ = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}
