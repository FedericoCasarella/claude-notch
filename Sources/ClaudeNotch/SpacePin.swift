import AppKit

/// Puts windows into a private WindowServer space that sits above every user Space.
/// Windows there don't take part in the Space-switch animation, so the notch never
/// blanks or redraws while swiping between desktops / full-screen apps.
/// Uses SkyLight (private) via dlsym; if anything is missing it silently does nothing.
final class SpacePin {
    private typealias ConnFn = @convention(c) () -> Int32
    private typealias CreateFn = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias LevelFn = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias SpacesFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddFn = @convention(c) (Int32, CFArray, CFArray) -> Void

    private let conn: Int32
    private let space: UInt64
    private let add: AddFn

    init?() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let c = dlsym(h, "_CGSDefaultConnection"),
              let cr = dlsym(h, "CGSSpaceCreate"),
              let lv = dlsym(h, "CGSSpaceSetAbsoluteLevel"),
              let sh = dlsym(h, "CGSShowSpaces"),
              let ad = dlsym(h, "CGSAddWindowsToSpaces") else { return nil }

        conn = unsafeBitCast(c, to: ConnFn.self)()
        space = unsafeBitCast(cr, to: CreateFn.self)(conn, 1, nil)
        guard space != 0 else { return nil }
        _ = unsafeBitCast(lv, to: LevelFn.self)(conn, space, Int32.max)
        _ = unsafeBitCast(sh, to: SpacesFn.self)(conn, [NSNumber(value: space)] as CFArray)
        add = unsafeBitCast(ad, to: AddFn.self)
    }

    func pin(_ window: NSWindow) {
        add(conn, [NSNumber(value: window.windowNumber)] as CFArray, [NSNumber(value: space)] as CFArray)
    }
}
