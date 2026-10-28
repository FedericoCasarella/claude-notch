import AppKit
import SwiftUI
import ServiceManagement

// MARK: - Preferences

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var refreshInterval: Double {
        didSet { d.set(refreshInterval, forKey: "refreshInterval") }
    }
    @Published var haptics: Bool {
        didSet { d.set(haptics, forKey: "haptics") }
    }
    @Published var showCPU: Bool {
        didSet { d.set(showCPU, forKey: "showCPU") }
    }
    @Published var showRAM: Bool {
        didSet { d.set(showRAM, forKey: "showRAM") }
    }
    @Published var autoUpdate: Bool {
        didSet { d.set(autoUpdate, forKey: "autoUpdate") }
    }

    var showsSystem: Bool { showCPU || showRAM }

    private init() {
        d.register(defaults: ["refreshInterval": 120.0, "haptics": true,
                              "showCPU": false, "showRAM": false, "autoUpdate": true])
        showCPU = d.bool(forKey: "showCPU")
        showRAM = d.bool(forKey: "showRAM")
        autoUpdate = d.bool(forKey: "autoUpdate")
        // Under a minute the endpoint starts answering 429.
        refreshInterval = max(d.double(forKey: "refreshInterval"), 60)
        haptics = d.bool(forKey: "haptics")
    }
}

// MARK: - Launch at login

/// Wraps SMAppService.mainApp (macOS 13+): registers the app bundle itself as a login item.
final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    @Published private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    @Published var lastError: String?

    var isEnabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var login = LoginItem.shared
    @ObservedObject var updater = Updater.shared

    private let intervals: [(String, Double)] = [("1 minuto", 60), ("2 minuti", 120), ("5 minuti", 300), ("10 minuti", 600)]

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { login.isEnabled || login.needsApproval },
                                     set: { login.set($0) })) {
                    Text("Apri all'avvio del Mac")
                    Text("Claude Notch parte da solo quando accedi.")
                }
                if login.needsApproval {
                    HStack {
                        Label("Serve l'approvazione in Impostazioni di Sistema", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                        Spacer()
                        Button("Apri…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let err = login.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            } header: { Text("Generale") }

            Section {
                Picker("Aggiorna ogni", selection: $settings.refreshInterval) {
                    ForEach(intervals, id: \.1) { Text($0.0).tag($0.1) }
                }
                Toggle("Feedback aptico all'apertura", isOn: $settings.haptics)
            } header: { Text("Notch") }

            Section {
                Toggle(isOn: $settings.showCPU) {
                    Text("Utilizzo CPU")
                    Text("Anello nel notch, aggiornato ogni secondo.")
                }
                Toggle(isOn: $settings.showRAM) {
                    Text("Utilizzo RAM")
                    Text("Memoria usata come in Monitoraggio Attività.")
                }
            } header: { Text("Monitor di sistema") }

            Section {
                Toggle(isOn: $settings.autoUpdate) {
                    Text("Aggiorna automaticamente")
                    Text("Controlla nuove versioni ogni 30 minuti e le installa da sola.")
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Versione \(Updater.currentVersion)")
                        Text(updater.status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if updater.busy { ProgressView().controlSize(.small) }
                    Button("Controlla ora") { updater.check(userInitiated: true) }
                        .disabled(updater.busy)
                }
            } header: { Text("Aggiornamenti") }

            Section {
                LabeledContent("Fonte dati", value: "Login di Claude Code")
            } header: { Text("Info") } footer: {
                Text("Passa il mouse sul notch per i dettagli · clic destro per questo menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { login.refresh() }
    }
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Impostazioni Claude Notch"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        LoginItem.shared.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Right-click menu on the notch

final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var menuProvider: (() -> NSMenu)?

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
