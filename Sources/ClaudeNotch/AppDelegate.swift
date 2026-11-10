import AppKit
import SwiftUI

/// Shared UI state: notch geometry + open/closed.
final class NotchModel: ObservableObject {
    @Published var isOpen = false
    @Published var notchSize = CGSize(width: 185, height: 32)
    @Published var hasPhysicalNotch = true

    static let sideWidth: CGFloat = 76
    /// Clear space between the notch's curved edge and the content (7pt flare + breathing room).
    static let edgeInset: CGFloat = 17
    static let openSize = CGSize(width: 540, height: 0) // height derived from notch

    /// Each enabled CPU/RAM/disk mini ring widens both sides equally so the notch stays centred.
    static let miniRingSlot: CGFloat = 23

    var sideWidth: CGFloat {
        let s = AppSettings.shared
        return Self.sideWidth + Self.miniRingSlot * CGFloat(s.systemMetricCount)
    }

    var closedSize: CGSize {
        CGSize(width: notchSize.width + sideWidth * 2, height: notchSize.height)
    }

    var openSize: CGSize {
        let s = AppSettings.shared
        let extra: CGFloat = s.showsSystem ? SystemCard.width(metrics: s.systemMetricCount) + 12 : 0
        return CGSize(width: Self.openSize.width + extra, height: notchSize.height + 192)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private let model = NotchModel()
    private let store = UsageStore()
    private var mouseTimer: Timer?
    private var openWorkItem: DispatchWorkItem?
    private var closeWorkItem: DispatchWorkItem?
    private var spacePin: SpacePin?

    private let windowSize = CGSize(width: 900, height: 360)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one notch at a time (e.g. login item + manual launch, or relaunch after update).
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0 != me && !$0.isTerminated }) {
            NSApp.terminate(nil)
            return
        }

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        let host = NotchHostingView(rootView: NotchRootView(model: model, store: store))
        host.sizingOptions = []
        host.menuProvider = { [weak self] in self?.makeMenu() ?? NSMenu() }
        panel.contentView = host

        positionPanel()
        panel.orderFrontRegardless()
        spacePin = SpacePin()
        spacePin?.pin(panel)

        // Fallback if the private space isn't available: re-assert after each Space switch.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        // Polling the cursor is cheap and works over the menu bar without permissions.
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.trackMouse()
        }

        store.start()
        SystemMonitor.shared.start()
        Updater.shared.start()

        // Debug: CLAUDE_NOTCH_PIN_OPEN=1 keeps the panel expanded (screenshots, tuning).
        if ProcessInfo.processInfo.environment["CLAUDE_NOTCH_PIN_OPEN"] == "1" {
            mouseTimer?.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.setOpen(true) }
        }
        if ProcessInfo.processInfo.environment["CLAUDE_NOTCH_SHOW_SETTINGS"] == "1" {
            openSettings()
        }
    }

    @objc private func screensChanged() { positionPanel() }
    @objc private func spaceChanged() { panel.orderFrontRegardless() }

    /// Prefer the built-in display with a notch; fall back to the main screen.
    private var targetScreen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func positionPanel() {
        let screen = targetScreen
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            model.notchSize = CGSize(width: frame.width - left.width - right.width,
                                     height: screen.safeAreaInsets.top)
            model.hasPhysicalNotch = true
        } else {
            let menuBar = max(frame.maxY - screen.visibleFrame.maxY, 24)
            model.notchSize = CGSize(width: 185, height: menuBar)
            model.hasPhysicalNotch = false
        }
        panel.setFrame(NSRect(x: frame.midX - windowSize.width / 2,
                              y: frame.maxY - windowSize.height,
                              width: windowSize.width, height: windowSize.height),
                       display: true)
    }

    private func hotRect(for size: CGSize, margin: CGFloat) -> NSRect {
        let frame = targetScreen.frame
        return NSRect(x: frame.midX - size.width / 2 - margin,
                      y: frame.maxY - size.height - margin,
                      width: size.width + margin * 2,
                      height: size.height + margin + 2)
    }

    private func trackMouse() {
        let p = NSEvent.mouseLocation
        if model.isOpen {
            let inside = hotRect(for: model.openSize, margin: 14).contains(p)
            if inside {
                closeWorkItem?.cancel(); closeWorkItem = nil
            } else if closeWorkItem == nil {
                let item = DispatchWorkItem { [weak self] in self?.setOpen(false) }
                closeWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: item)
            }
        } else {
            let inside = hotRect(for: model.closedSize, margin: 4).contains(p)
            // Accept clicks over the closed notch too, so right-click reaches our menu.
            panel.ignoresMouseEvents = !inside
            if inside {
                if openWorkItem == nil {
                    let item = DispatchWorkItem { [weak self] in self?.setOpen(true) }
                    openWorkItem = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: item)
                }
            } else {
                openWorkItem?.cancel(); openWorkItem = nil
            }
        }
    }

    private func setOpen(_ open: Bool) {
        openWorkItem = nil
        closeWorkItem = nil
        guard model.isOpen != open else { return }
        model.isOpen = open
        panel.ignoresMouseEvents = !open
        if open {
            store.refreshLocal()
            if AppSettings.shared.haptics {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
    }

    // MARK: Context menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Impostazioni…", #selector(openSettings), key: ","))
        let login = item("Apri all'avvio del Mac", #selector(toggleLogin))
        LoginItem.shared.refresh()
        login.state = LoginItem.shared.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Ricalcola token di oggi", #selector(refreshNow), key: "r"))
        menu.addItem(item("Controlla aggiornamenti…", #selector(checkUpdates)))
        menu.addItem(.separator())
        menu.addItem(item("Esci da Claude Notch", #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func openSettings() {
        setOpen(false)
        SettingsWindowController.shared.show()
    }
    @objc private func toggleLogin() { LoginItem.shared.set(!LoginItem.shared.isEnabled) }
    @objc private func refreshNow() { store.refreshLocal() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func checkUpdates() {
        Updater.shared.check(userInitiated: true)
        SettingsWindowController.shared.show()
    }
}
