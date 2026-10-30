import AppKit
import Darwin

/// Keeps the island on screen while swiping between desktops (Spaces).
///
/// macOS moves windows that appear on every desktop only after the swipe animation, so they
/// vanish for a moment. The menu bar doesn't, because it lives in a special space that sits
/// above all desktops. This creates such a space and puts the island in it: the same
/// technique notch apps like Boring Notch use. It relies on private SkyLight functions, looked
/// up at runtime; if a future macOS removes them, this does nothing and the old behaviour returns.
@MainActor
final class SpaceFix {
    static let shared = SpaceFix()

    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias SpaceCreateFn = @convention(c) (Int32, Int, CFDictionary?) -> UInt64
    private typealias SpaceSetAbsoluteLevelFn = @convention(c) (Int32, UInt64, Int) -> Void
    private typealias ShowSpacesFn = @convention(c) (Int32, CFArray) -> Void
    private typealias AddWindowsToSpacesFn = @convention(c) (Int32, CFArray, CFArray) -> Void

    private var spaceID: UInt64 = 0

    private init() {}

    func keepVisibleWhileSwitchingDesktops(_ window: NSWindow) {
        guard window.windowNumber > 0,
              let mainConnection = Self.lookup(["CGSMainConnectionID", "SLSMainConnectionID"], as: MainConnectionFn.self),
              let createSpace = Self.lookup(["CGSSpaceCreate", "SLSSpaceCreate"], as: SpaceCreateFn.self),
              let setLevel = Self.lookup(["CGSSpaceSetAbsoluteLevel", "SLSSpaceSetAbsoluteLevel"], as: SpaceSetAbsoluteLevelFn.self),
              let showSpaces = Self.lookup(["CGSShowSpaces", "SLSShowSpaces"], as: ShowSpacesFn.self),
              let addWindows = Self.lookup(["CGSAddWindowsToSpaces", "SLSAddWindowsToSpaces"], as: AddWindowsToSpacesFn.self)
        else { return }

        let connection = mainConnection()
        if spaceID == 0 {
            // The flag must be 1, otherwise Finder draws desktop icons into the new space.
            spaceID = createSpace(connection, 1, nil)
            guard spaceID != 0 else { return }
            setLevel(connection, spaceID, Int(Int32.max))
            showSpaces(connection, [NSNumber(value: spaceID)] as CFArray)
        }
        addWindows(connection,
                   [NSNumber(value: window.windowNumber)] as CFArray,
                   [NSNumber(value: spaceID)] as CFArray)
    }

    private static func lookup<T>(_ names: [String], as type: T.Type) -> T? {
        let everywhere = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        for name in names {
            if let pointer = dlsym(everywhere, name) {
                return unsafeBitCast(pointer, to: type)
            }
        }
        return nil
    }
}
