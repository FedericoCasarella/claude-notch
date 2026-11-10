import Foundation
import Combine
import Darwin

/// Samples CPU load and memory pressure once per second (disk space every 10 s) while any metric is enabled in Settings.
@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published private(set) var cpu: Double = 0        // 0...1
    @Published private(set) var ram: Double = 0        // 0...1
    @Published private(set) var ramUsedGB: Double = 0
    let ramTotalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    @Published private(set) var disk: Double = 0       // 0...1 used
    @Published private(set) var diskFreeGB: Double = 0

    private var timer: Timer?
    private var prevTicks: [UInt32]?
    private var lastDiskSample = Date.distantPast
    private var settingsObserver: AnyCancellable?

    func start() {
        let s = AppSettings.shared
        settingsObserver = s.$showCPU.combineLatest(s.$showRAM, s.$showDisk)
            .map { $0 || $1 || $2 }
            .removeDuplicates()
            .sink { [weak self] active in self?.setActive(active) }
    }

    private func setActive(_ active: Bool) {
        timer?.invalidate()
        timer = nil
        prevTicks = nil
        lastDiskSample = .distantPast
        guard active else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    private func sample() {
        if let c = cpuLoad() { cpu = c }
        if let (used, frac) = memoryUsage() { ramUsedGB = used; ram = frac }
        // Free space barely moves; no need to hit the filesystem every second.
        if Date().timeIntervalSince(lastDiskSample) >= 10, let (free, frac) = diskUsage() {
            lastDiskSample = Date()
            diskFreeGB = free
            disk = frac
        }
    }

    /// Startup volume space as Finder reports it (purgeable space counts as available).
    private func diskUsage() -> (Double, Double)? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity, total > 0,
              let free = v.volumeAvailableCapacityForImportantUsage else { return nil }
        let t = Double(total), f = Double(free)
        return (f / 1e9, min(1, max(0, (t - f) / t)))
    }

    /// Fraction of non-idle ticks across all cores since the previous sample.
    private func cpuLoad() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        let ticks = [t.0, t.1, t.2, t.3]   // user, system, idle, nice
        defer { prevTicks = ticks }
        guard let prev = prevTicks else { return nil }
        let d = zip(ticks, prev).map { Double($0 &- $1) }
        let total = d.reduce(0, +)
        guard total > 0 else { return nil }
        return min(1, max(0, (total - d[Int(CPU_STATE_IDLE)]) / total))
    }

    /// "Memory used" as Activity Monitor computes it: app memory + wired + compressed.
    private func memoryUsage() -> (Double, Double)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = Double(vm_kernel_page_size)
        let appPages = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        let used = (appPages + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return (used / 1_073_741_824, min(1, max(0, used / total)))
    }
}
