import Foundation
import UIKit
import QuartzCore

/// 1.0.2: performance measurements on the owner's iPhone (no behaviour change). Records how long the measured steps take,
/// main-thread stalls (frames longer than 50 ms, with the step that was running), the device and the library size.
/// Only step names and counts are recorded — never links, user names, passwords or server addresses.
/// The log survives restarts (Caches/perf.log), so a "before" and an "after" version can be compared.
final class Perf: NSObject {
    static let shared = Perf()

    private let lock = NSLock()
    private var lines: [String] = []
    private var stalls: [String: (count: Int, maxMs: Double, totalMs: Double)] = [:]
    private var context = "تصفح"
    private var contextAt = CACurrentMediaTime()
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var nextFrame: [(name: String, t0: Double, detail: String)] = []
    private var launchRecorded = false, libraryRecorded = false, cacheRecorded = false
    private let file: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("perf.log")

    private override init() {
        super.init()
        if let f = file, let s = try? String(contentsOf: f, encoding: .utf8) {
            lines = s.split(separator: "\n").map(String.init).suffix(400)
        }
    }

    static func now() -> Double { CACurrentMediaTime() }

    /// One measured step, in milliseconds since `t0` (from `Perf.now()`).
    func record(_ name: String, since t0: Double, _ detail: String = "") {
        add(name, ms: (CACurrentMediaTime() - t0) * 1000, detail)
    }

    func add(_ name: String, ms: Double, _ detail: String = "") {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX")
        let main = Thread.isMainThread ? " [واجهة]" : ""
        let line = "\(f.string(from: Date())) \(name): \(String(format: "%.0f", ms)) ms\(main)\(detail.isEmpty ? "" : " | " + detail)"
        lock.lock()
        lines.append(line); if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        let all = lines.joined(separator: "\n")
        lock.unlock()
        if let file { try? all.write(to: file, atomically: true, encoding: .utf8) }
    }

    /// Measures a block that runs where it is called (on the main thread for screen computations).
    @discardableResult
    func measure<T>(_ name: String, _ detail: @autoclosure () -> String = "", minMs: Double = 4, _ f: () throws -> T) rethrows -> T {
        let t0 = CACurrentMediaTime()
        let r = try f()
        let ms = (CACurrentMediaTime() - t0) * 1000
        if ms >= minMs { add(name, ms: ms, detail()) }      // tiny ones would only flood the log
        return r
    }

    /// Names the step now running, so a stalled frame in the next seconds is attributed to it.
    func mark(_ step: String) {
        lock.lock(); context = step; contextAt = CACurrentMediaTime(); lock.unlock()
    }

    /// Time from now until the next frame is drawn (= how long the main thread was busy with this change).
    /// With `since`: from that moment until the next frame (e.g. screen opened → its data on screen).
    func untilNextFrame(_ name: String, since t0: Double? = nil, _ detail: String = "") {
        mark(name)
        lock.lock(); nextFrame.append((name, t0 ?? CACurrentMediaTime(), detail)); lock.unlock()
    }

    // MARK: Launch

    /// Process start time (kernel), so the launch time includes what happens before any app code runs.
    private static let processStart: Double? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let t = info.kp_proc.p_starttime
        return Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000
    }()

    private func sinceLaunchMs() -> Double? {
        guard let s = Self.processStart else { return nil }
        return (Date().timeIntervalSince1970 - s) * 1000
    }

    /// First screen with content on screen (called once).
    func firstScreen(_ what: String) {
        lock.lock(); let done = launchRecorded; launchRecorded = true; lock.unlock()
        guard !done, let ms = sinceLaunchMs() else { return }
        add("فتح التطبيق ← أول شاشة", ms: ms, what)
    }

    /// Library ready after launch (once from the saved copy, once from the provider).
    func libraryReadyAfterLaunch(_ detail: String, fromCache: Bool = false) {
        lock.lock()
        let done = fromCache ? cacheRecorded : libraryRecorded
        if fromCache { cacheRecorded = true } else { libraryRecorded = true }
        lock.unlock()
        guard !done, let ms = sinceLaunchMs() else { return }
        add(fromCache ? "فتح التطبيق ← المكتبة المحفوظة معروضة" : "فتح التطبيق ← المكتبة محدّثة من المزوّد", ms: ms, detail)
    }

    // MARK: Stalled frames

    func startMonitor() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(frame(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func frame(_ l: CADisplayLink) {
        let t = l.timestamp
        defer { lastFrame = t }
        lock.lock()
        let pending = nextFrame; nextFrame = []
        lock.unlock()
        let now = CACurrentMediaTime()
        for p in pending { add(p.name, ms: (now - p.t0) * 1000, p.detail) }
        guard lastFrame > 0 else { return }
        let gapMs = (t - lastFrame) * 1000
        guard gapMs > 50, gapMs < 10_000 else { return }   // >10 s = app was in the background
        lock.lock()
        let step = CACurrentMediaTime() - contextAt < 3 ? context : "تصفح"
        var s = stalls[step] ?? (0, 0, 0)
        s.count += 1; s.maxMs = max(s.maxMs, gapMs); s.totalMs += gapMs
        stalls[step] = s
        lock.unlock()
        if gapMs > 250 { add("توقف الواجهة", ms: gapMs, step) }
    }

    // MARK: Report

    static var device: String {
        var u = utsname(); uname(&u)
        let model = withUnsafeBytes(of: &u.machine) { b in String(decoding: b.prefix(while: { $0 != 0 }), as: UTF8.self) }
        return "\(model) · iOS \(UIDevice.current.systemVersion)"
    }

    /// App memory footprint in MB (what iOS counts against the app).
    static var memoryMB: Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : nil
    }

    func report(library: String) -> String {
        let info = Bundle.main.infoDictionary
        var out: [String] = []
        out.append("شاشة \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?")) — قياسات الأداء")
        out.append("الجهاز: \(Self.device)")
        if let m = Self.memoryMB { out.append(String(format: "الذاكرة الآن: %.0f MB", m)) }
        out.append("المكتبة: \(library)")
        lock.lock()
        let st = stalls.sorted { $0.value.totalMs > $1.value.totalMs }
        let ls = lines
        lock.unlock()
        out.append("")
        out.append(contentsOf: summary(ls))
        out.append("")
        out.append("— إطارات متأخرة (> 50 ms) منذ فتح التطبيق، حسب الخطوة")
        if st.isEmpty { out.append("لا يوجد") }
        for (k, v) in st { out.append(String(format: "%@: %d مرة | أطول %.0f ms | المجموع %.0f ms", k, v.count, v.maxMs, v.totalMs)) }
        out.append("")
        out.append("— الخطوات المقاسة (الأحدث في الأسفل، تبقى بعد إعادة فتح التطبيق)")
        out.append(contentsOf: ls.suffix(150))
        return out.joined(separator: "\n")
    }

    /// 1.0.4: the last launch split into network, background processing, main-thread work and stalls.
    /// Network requests run in parallel, so their sum is more than the waiting time: the longest is shown too.
    private func summary(_ all: [String]) -> [String] {
        let start = all.lastIndex { $0.contains("فتح التطبيق ← أول شاشة") } ?? 0
        var net = (n: 0, sum: 0.0, max: 0.0), bg = (n: 0, sum: 0.0), ui = (n: 0, sum: 0.0), stall = (n: 0, sum: 0.0, max: 0.0)
        for l in all[start...] {
            guard let r = l.range(of: #": (\d+) ms"#, options: .regularExpression),
                  let ms = Double(l[r].dropFirst(2).dropLast(3)) else { continue }
            let name = l.dropFirst(9)
            if name.hasPrefix("فتح التطبيق") { continue }
            if name.hasPrefix("شبكة") { net.n += 1; net.sum += ms; net.max = max(net.max, ms) }
            else if name.hasPrefix("توقف الواجهة") { stall.n += 1; stall.sum += ms; stall.max = max(stall.max, ms) }
            else if l.contains("[واجهة]") { ui.n += 1; ui.sum += ms }
            else { bg.n += 1; bg.sum += ms }
        }
        return ["— ملخص آخر فتح للتطبيق",
                String(format: "الشبكة: %d طلب | أطول طلب %.0f ms | المجموع %.0f ms (الطلبات متوازية)", net.n, net.max, net.sum),
                String(format: "معالجة في الخلفية (تحليل، تحويل، فهرسة، حفظ): %d | المجموع %.0f ms", bg.n, bg.sum),
                String(format: "عمل على خيط الواجهة (مقاس): %d | المجموع %.0f ms", ui.n, ui.sum),
                String(format: "تعليق الواجهة (> 250 ms): %d مرة | أطول %.0f ms | المجموع %.0f ms", stall.n, stall.max, stall.sum)]
    }

    func clear() {
        lock.lock(); lines = []; stalls = [:]; lock.unlock()
        if let file { try? FileManager.default.removeItem(at: file) }
    }
}
