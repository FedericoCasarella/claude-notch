import AppKit

/// Self-updater backed by GitHub Releases.
/// Every 30 minutes it reads the latest release of `repo`; if its tag (e.g. "v1.3") is newer than
/// the running version and the release has a .dmg asset, it downloads it, swaps the app bundle
/// in place and relaunches.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "FedericoCasarella/claude-notch"
    static let checkInterval: TimeInterval = 30 * 60

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    @Published private(set) var status = "Mai controllato"
    @Published private(set) var busy = false

    private var timer: Timer?

    func start() {
        // Debug: CLAUDE_NOTCH_UPDATE_FROM=/path/to.dmg exercises install + relaunch with a local DMG.
        if let local = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_UPDATE_FROM"] {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeNotch-test.dmg")
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: local), to: copy)
            Task {
                do { try await Task.detached { try Self.install(dmg: copy) }.value; Self.relaunch() }
                catch { NSLog("ClaudeNotch update test failed: \(error)") }
            }
            return
        }
        // First check shortly after launch, then on a fixed schedule.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check(userInitiated: false) }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(userInitiated: false) }
        }
    }

    /// Automatic checks install only when "Aggiorna automaticamente" is on; manual checks always do.
    func check(userInitiated: Bool) {
        guard !busy else { return }
        guard userInitiated || AppSettings.shared.autoUpdate else { return }
        busy = true
        status = "Controllo in corso…"
        Task {
            defer { busy = false }
            do {
                guard let release = try await Self.latestRelease() else {
                    status = "Nessuna release pubblicata"
                    return
                }
                guard Self.isNewer(release.version, than: Self.currentVersion) else {
                    status = "Aggiornato · ultimo controllo \(Self.time())"
                    return
                }
                status = "Scarico la versione \(release.version)…"
                let dmg = try await Self.download(release.dmgURL)
                status = "Installo la versione \(release.version)…"
                try await Task.detached { try Self.install(dmg: dmg) }.value
                status = "Riavvio…"
                Self.relaunch()
            } catch {
                status = "Errore: \(error.localizedDescription)"
            }
        }
    }

    // MARK: GitHub

    private struct Release { let version: String; let dmgURL: URL }

    private static func latestRelease() async throws -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ClaudeNotch/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard code == 200 else { throw UpdateError("GitHub ha risposto \(code)") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let urlString = dmg["browser_download_url"] as? String,
              let url = URL(string: urlString) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, dmgURL: url)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Install

    private static func download(_ url: URL) async throws -> URL {
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Download fallito") }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeNotch-update.dmg")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Mounts the DMG, copies the new app next to the running one, then atomically swaps them.
    nonisolated private static func install(dmg: URL) throws {
        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appendingPathComponent("ClaudeNotch-mount-\(UUID().uuidString)")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? fm.removeItem(at: mount)
            try? fm.removeItem(at: dmg)
        }

        guard let newApp = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw UpdateError("Nessuna app nel DMG") }
        guard Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("Il DMG contiene un'app diversa")
        }

        let current = Bundle.main.bundleURL
        let staged = current.deletingLastPathComponent().appendingPathComponent(".ClaudeNotch-update.app")
        try? fm.removeItem(at: staged)
        try run("/usr/bin/ditto", [newApp.path, staged.path])
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        _ = try fm.replaceItemAt(current, withItemAt: staged)
    }

    private static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else { throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent): \(text)") }
        return text
    }

    private static func time() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
