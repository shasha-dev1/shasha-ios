import SwiftUI

/// Match-guide report (test): football matches found in the provider's programme guide (XMLTV), matched to this
/// phone's channels. Everything is read and computed on the phone; the report holds channel names and guide
/// titles only (no links, no account data). Same rules as the TV (MatchGuideRule / MatchGuideCore).
struct MatchReportView: View {
    @EnvironmentObject var library: Library
    @State private var text = ""
    @State private var status = ""
    @State private var job: Task<Void, Never>?
    @State private var cancel = MatchGuideReport.CancelFlag()

    var body: some View {
        List {
            Section {
                if job == nil {
                    Button("إنشاء التقرير") { start() }
                } else {
                    Button("إلغاء", role: .destructive) { cancel.set(); job?.cancel() }
                }
                if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("ينزّل دليل البرامج الكامل من المزوّد مرة واحدة (حد أقصى \(MatchGuideReport.maxBytes / 1_048_576) MB — يفضّل Wi‑Fi) ويقرأه على الجهاز خارج خيط الواجهة. المصدر: دليل برامج المزوّد. التطابق ترجيح، ليس ضمانًا أن البث مباشر.")
            }
            if !text.isEmpty {
                Section {
                    Button { UIPasteboard.general.string = text } label: { Label("نسخ التقرير", systemImage: "doc.on.doc") }
                    Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("دليل المباريات")
        .onDisappear { cancel.set(); job?.cancel() }
    }

    private func start() {
        guard let x = library.xtream, let url = x.xmltvURL else { status = "يحتاج مصدر Xtream"; return }
        let flag = MatchGuideReport.CancelFlag(); cancel = flag
        // What the report needs from the library, copied on the main thread; the rest runs off it.
        let chans = MatchStore.channels(library)
        let source = library.active?.name ?? "?"
        text = ""; status = "تنزيل الدليل…"
        job = Task {
            Perf.shared.memory("دليل المباريات: قبل التنزيل")
            let t0 = Perf.now()
            let r = await MatchGuideReport.download(url, cancel: flag) { mb in Task { @MainActor in status = "تنزيل الدليل… \(mb) MB" } }
            switch r {
            case .failure(let why):
                status = why.text; job = nil; return
            case .success(let (file, size)):
                defer { try? FileManager.default.removeItem(at: file) }
                Perf.shared.record("دليل المباريات: تنزيل الدليل", since: t0, "\(size / 1_048_576) MB")
                Perf.shared.memory("دليل المباريات: بعد التنزيل")
                status = "قراءة الدليل…"
                let t1 = Perf.now()
                let now = Date()
                let res = await Task.detached(priority: .utility) {
                    MatchIndexBuilder.build(file: file, size: size, channels: chans, source: source, now: now, cancel: flag, withStats: true)
                }.value
                Perf.shared.record("دليل المباريات: القراءة والمطابقة", since: t1, "")
                Perf.shared.memory("دليل المباريات: بعد القراءة")
                if flag.isSet { status = "أُلغي"; job = nil; return }
                MatchStore.shared.adopt(res, source: source)        // the screen uses the same build
                let full = MatchIndexBuilder.report(res, now: now) + (await MatchStore.shared.compareText(library))   // 1.8.6: in full
                text = RedactRule.text(full)          // 1.10.3 (owner 19:37): no playback link, account or server anywhere
                status = "تم — الدليل \(size / 1_048_576) MB"
            }
            job = nil
        }
    }
}

/// Guide download (to a file, with a size limit and cancel) and XMLTV times, for the report and the matches screen.
enum MatchGuideReport {
    static func nameKey(_ s: String) -> String {
        let quality: Set<String> = ["hd", "fhd", "uhd", "sd", "4k", "hevc", "h265", "1080p", "720p", "raw"]
        return s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init).filter { !quality.contains($0) }.joined(separator: " ")
    }

    /// XMLTV times ("20261123194500 +0300"); a missing offset is UTC.
    enum Parser {
        // One parse runs on one thread: the formatters are made once per thread.
        private static let withZone: DateFormatter = {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMddHHmmss Z"; return f
        }()
        private static let utc: DateFormatter = {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMddHHmmss"
            f.timeZone = TimeZone(identifier: "UTC"); return f
        }()
        static func time(_ s: String?) -> Int64? {
            guard let s, s.count >= 14 else { return nil }
            let d = s.count >= 20 ? withZone.date(from: String(s.prefix(20))) : utc.date(from: String(s.prefix(14)))
            return d.map { Int64($0.timeIntervalSince1970 * 1000) }
        }
    }

    /// Safe size for the whole guide (bigger files are refused, before or while downloading).
    static let maxBytes: Int64 = 400 * 1_048_576

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock(); private var on = false
        func set() { lock.lock(); on = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return on }
    }

    /// Downloads to a file (never into memory), stopping at `maxBytes` or on cancel. No link in any message.
    static func download(_ url: URL, cancel: CancelFlag, progress: @escaping @Sendable (Int64) -> Void) async -> Result<(URL, Int64), Failure> {
        let d = GuideDownload(cancel, progress)
        let s = URLSession(configuration: .ephemeral, delegate: d, delegateQueue: nil)
        defer { s.finishTasksAndInvalidate() }
        return await withCheckedContinuation { c in
            d.done = { c.resume(returning: $0) }
            var r = URLRequest(url: url, timeoutInterval: 120)
            r.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
            s.downloadTask(with: r).resume()
        }
    }
    struct Failure: Error { let text: String; init(_ t: String) { text = t } }

}

/// Guide download for the report: to a file, stopped at the size limit or on cancel.
final class GuideDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var done: ((Result<(URL, Int64), MatchGuideReport.Failure>) -> Void)?
    let cancel: MatchGuideReport.CancelFlag; let progress: @Sendable (Int64) -> Void
    var lastMB: Int64 = -1
    init(_ c: MatchGuideReport.CancelFlag, _ p: @escaping @Sendable (Int64) -> Void) { cancel = c; progress = p }
    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didWriteData w: Int64, totalBytesWritten n: Int64, totalBytesExpectedToWrite e: Int64) {
        if cancel.isSet || n > MatchGuideReport.maxBytes || e > MatchGuideReport.maxBytes { t.cancel(); return }
        if n / 1_048_576 != lastMB { lastMB = n / 1_048_576; progress(lastMB) }
    }
    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo loc: URL) {
        let code = (t.response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { finish(.failure(MatchGuideReport.Failure("المزوّد ردّ \(code)"))); return }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("guide-\(UUID().uuidString).xml")
        do { try FileManager.default.moveItem(at: loc, to: dest) } catch { finish(.failure(MatchGuideReport.Failure("تعذّر حفظ الدليل"))); return }
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
        finish(.success((dest, size)))
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let big = task.countOfBytesReceived > MatchGuideReport.maxBytes || task.countOfBytesExpectedToReceive > MatchGuideReport.maxBytes
        finish(.failure(MatchGuideReport.Failure(cancel.isSet ? "أُلغي" : big ? "الدليل أكبر من \(MatchGuideReport.maxBytes / 1_048_576) MB — أوقف للحماية"
                                : "تعذّر تنزيل الدليل (\((error as NSError).code))")))
    }
    func finish(_ r: Result<(URL, Int64), MatchGuideReport.Failure>) { if let d = done { done = nil; d(r) } }
}
