import Foundation

/// Keeps the app's event log of the current playback in memory for "Copy playback diagnostics". Nothing is written to disk or sent.
/// - Default: errors and warnings. "Detailed" adds debug lines, but only those about decoders, subtitles and video output
///   (module choice, libass/freetype/subsdec, vout), so the useful lines are not pushed out by noise.
/// - Repeated messages are folded into one line with a count.
/// - Cleared when a new item starts, so the report belongs to what is on screen.
final class DiagLog: NSObject {
    static let shared = DiagLog()
    /// Kept for the diagnostics toggle (detailed logging); mpv's own log level is set by the engine.
    enum Level { case warning, debug }
    var level: Level = .warning
    private let lock = NSLock()
    /// First lines of the playback (module choices, decoders, output) — never pushed out.
    private var head: [String] = []
    /// Latest lines.
    private var tail: [String] = []
    /// Very frequent messages are counted instead of stored after their first few occurrences.
    private var counts: [String: Int] = [:]
    private let headMax = 220, tailMax = 160, keepFirst = 3
    private static let noisy: [(key: String, match: String)] = [
        ("clock gap / new clock context", "clock gap"), ("clock gap / new clock context", "feeding synchro"),
        ("clock gap / new clock context", "clock context"), ("picture too late", "picture is too late"),
        ("picture displayed late", "picture displayed late"), ("deferring start", "deferring start"), ("buffering %", "Buffering ")]
    private static let interesting = try! NSRegularExpression(
        pattern: "(sub|spu|libass|freetype|font|decoder|codec|vout|display|module|ssa|render|osd|blend|filter|placebo|pl_scale|dovi|dolby|opengl|gles|hdr|videotoolbox|avcodec|demux|mkv|matroska|clock|pcr|es_out|track)",
        options: [.caseInsensitive])

    func beginSession(_ title: String) {
        lock.lock(); head.removeAll(); tail.removeAll(); counts.removeAll(); lock.unlock()
    }

    /// App-side event (track request, open position, lab switch, engine track change) — always kept, time-stamped.
    func note(_ text: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; f.locale = Locale(identifier: "en_US_POSIX")
        let line = "[\(f.string(from: Date()))] \(text)"
        lock.lock(); defer { lock.unlock() }
        if head.count < headMax { head.append(line) } else { tail.append(line); if tail.count > tailMax { tail.removeFirst(tail.count - tailMax) } }
    }

    /// Start of the playback, a count of the frequent messages, then the latest lines.
    func report() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var out = ["[بداية التشغيل]"] + head
        if !counts.isEmpty {
            out.append("[رسائل متكررة — العدد الكلي منذ بداية التشغيل]")
            for (k, v) in counts.sorted(by: { $0.key < $1.key }) { out.append("  \(k): \(v)") }
        }
        if !tail.isEmpty { out.append("[آخر الأسطر]"); out += tail }
        return out
    }
}
