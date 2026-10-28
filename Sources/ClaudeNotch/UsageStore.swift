import Foundation
import Combine

struct LimitWindow: Equatable, Codable {
    var usedPercent: Double      // 0...100
    var resetsAt: Date?
    var remaining: Double { max(0, min(1, 1 - usedPercent / 100)) }
    var used: Double { max(0, min(1, usedPercent / 100)) }
}

struct LocalUsage: Equatable {
    var tokens: Int = 0
    var outputTokens: Int = 0
    var messages: Int = 0
    var hourly: [Int] = Array(repeating: 0, count: 24)
}

/// Pulls plan limits from Anthropic's OAuth usage endpoint (same data as `/usage` in Claude Code)
/// and today's token counts from local Claude Code transcripts.
@MainActor
final class UsageStore: ObservableObject {
    @Published var session: LimitWindow?
    @Published var weekly: LimitWindow?
    @Published var plan: String?
    @Published var today = LocalUsage()
    @Published var error: String?
    @Published var isLoading = false
    @Published var lastUpdate: Date?
    /// When the next (and only) scheduled call to Anthropic will happen.
    @Published private(set) var nextAPIFetch = Date()
    /// Set after a 429: no calls before this date.
    private var backoffUntil: Date?

    private var ticker: Timer?
    private let scanner = TranscriptScanner()
    private let defaults = UserDefaults.standard

    private struct Snapshot: Codable { var session: LimitWindow?; var weekly: LimitWindow?; var plan: String? }
    private static let cacheKey = "lastUsageSnapshot"
    private static let lastFetchKey = "lastAPIFetch"

    /// Persisted so restarts don't cause extra calls.
    private var lastAPIFetch: Date? {
        get { defaults.object(forKey: Self.lastFetchKey) as? Date }
        set { defaults.set(newValue, forKey: Self.lastFetchKey) }
    }

    init() {
        // Show the last known values immediately (restart, rate limit, offline).
        if let data = defaults.data(forKey: Self.cacheKey),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
            session = snap.session
            weekly = snap.weekly
            plan = snap.plan
            lastUpdate = lastAPIFetch
        }
    }

    /// API calls happen only here, on the schedule set in Settings.
    /// A cheap local tick checks whether the next slot has arrived.
    func start() {
        updateSchedule()
        refresh(callAPI: Date() >= nextAPIFetch)
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateSchedule()   // also picks up interval changes from Settings
                if Date() >= self.nextAPIFetch { self.refresh(callAPI: true) }
            }
        }
    }

    private func updateSchedule() {
        let byInterval = (lastAPIFetch ?? .distantPast).addingTimeInterval(AppSettings.shared.refreshInterval)
        nextAPIFetch = max(byInterval, backoffUntil ?? .distantPast)
    }

    /// Re-reads local transcripts only; never calls the API.
    func refreshLocal() { refresh(callAPI: false) }

    private func refresh(callAPI: Bool) {
        guard !isLoading else { return }
        isLoading = true
        if callAPI {
            // Book the slot before the request so nothing can fire twice.
            lastAPIFetch = Date()
            backoffUntil = nil
            updateSchedule()
        }
        Task {
            let scanner = self.scanner
            async let local = Task.detached(priority: .utility) { scanner.scanToday() }.value
            let api = callAPI ? await UsageAPI.fetch() : nil
            let localUsage = await local

            switch api {
            case .success(let r)?:
                session = r.session
                weekly = r.weekly
                plan = r.plan
                error = nil
                lastUpdate = Date()
                if let data = try? JSONEncoder().encode(Snapshot(session: r.session, weekly: r.weekly, plan: r.plan)) {
                    defaults.set(data, forKey: Self.cacheKey)
                }
            case .failure(let e)?:
                if let wait = e.retryAfter {
                    backoffUntil = Date().addingTimeInterval(wait)
                    updateSchedule()
                }
                error = e.message
            case nil:
                break
            }
            today = localUsage
            try? await Task.sleep(nanoseconds: 350_000_000)
            isLoading = false
        }
    }
}

// MARK: - API

struct UsageError: Error {
    let message: String
    var retryAfter: TimeInterval? = nil
}

enum UsageAPI {
    struct Result { var session: LimitWindow?; var weekly: LimitWindow?; var plan: String? }

    static func fetch() async -> Swift.Result<Result, UsageError> {
        guard let creds = readCredentials() else {
            return .failure(UsageError(message: "Login Claude Code non trovato"))
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.timeoutInterval = 15
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-notch/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { return .failure(UsageError(message: "Token scaduto · apri Claude Code")) }
            if status == 429 {
                let header = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                let wait = header.flatMap(Double.init) ?? 120
                return .failure(UsageError(message: "Limite richieste raggiunto", retryAfter: max(wait, 300)))
            }
            guard status == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(UsageError(message: "Errore API (\(status))"))
            }
            return .success(Result(session: window(json["five_hour"]),
                                   weekly: window(json["seven_day"]),
                                   plan: creds.plan))
        } catch {
            return .failure(UsageError(message: "Offline"))
        }
    }

    private static func window(_ any: Any?) -> LimitWindow? {
        guard let d = any as? [String: Any], let u = d["utilization"] as? Double else { return nil }
        return LimitWindow(usedPercent: u, resetsAt: (d["resets_at"] as? String).flatMap(parseDate))
    }

    /// Reads the OAuth token Claude Code stores in the login keychain.
    /// Goes through /usr/bin/security, which is already on the item's ACL, so no prompt appears.
    private static func readCredentials() -> (token: String, plan: String?)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        return (token, oauth["subscriptionType"] as? String)
    }
}

/// ISO-8601 with arbitrary fractional seconds (the API returns microseconds).
func parseDate(_ s: String) -> Date? {
    let stripped = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    return ISO8601DateFormatter().date(from: stripped)
}

// MARK: - Local transcripts

/// Sums today's tokens from ~/.claude/projects/**/*.jsonl, caching per-file results by mtime.
final class TranscriptScanner: @unchecked Sendable {
    private struct Entry { var mtime: Date; var usage: LocalUsage }
    private var cache: [String: Entry] = [:]
    private var cacheDay: Date?
    private let lock = NSLock()

    func scanToday() -> LocalUsage {
        lock.lock(); defer { lock.unlock() }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: Date())
        if cacheDay != dayStart { cache = [:]; cacheDay = dayStart }

        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return LocalUsage() }

        var total = LocalUsage()
        var seen = Set<String>()
        for case let url as URL in en where url.pathExtension == "jsonl" {
            guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  mtime >= dayStart else { continue }
            seen.insert(url.path)
            let usage: LocalUsage
            if let c = cache[url.path], c.mtime == mtime {
                usage = c.usage
            } else {
                usage = scanFile(url, dayStart: dayStart)
                cache[url.path] = Entry(mtime: mtime, usage: usage)
            }
            total.tokens += usage.tokens
            total.outputTokens += usage.outputTokens
            total.messages += usage.messages
            for h in 0..<24 { total.hourly[h] += usage.hourly[h] }
        }
        cache = cache.filter { seen.contains($0.key) }
        return total
    }

    private func scanFile(_ url: URL, dayStart: Date) -> LocalUsage {
        var u = LocalUsage()
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return u }
        let cal = Calendar.current
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var ids = Set<String>()
        let marker = Data("\"usage\"".utf8)

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.range(of: marker) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let ts = obj["timestamp"] as? String,
                  let date = iso.date(from: ts) ?? parseDate(ts), date >= dayStart,
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] else { continue }
            // Streaming writes the same message several times; count it once.
            let key = "\(msg["id"] as? String ?? ""):\(obj["requestId"] as? String ?? "")"
            if key != ":" { guard ids.insert(key).inserted else { continue } }

            func n(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
            let out = n("output_tokens")
            let sum = n("input_tokens") + out + n("cache_creation_input_tokens") + n("cache_read_input_tokens")
            u.tokens += sum
            u.outputTokens += out
            u.messages += 1
            u.hourly[cal.component(.hour, from: date)] += sum
        }
        return u
    }
}
